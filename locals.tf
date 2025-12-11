locals {
  sku_lookup = {
    small  = "Standard_D2s_v5"
    medium = "Standard_D4s_v5"
    large  = "Standard_D8s_v5"
  }

  disk_type_defaults = {
    standard = {
      storage_account_type = "StandardSSD_LRS"
      default_size_gb      = 128
    }
    premium = {
      storage_account_type = "Premium_LRS"
      default_size_gb      = 256
    }
    ultra = {
      storage_account_type = "UltraSSD_LRS"
      default_size_gb      = 512
    }
  }

  raw_base_names = {
    for node_name in keys(var.nodes) :
    node_name => lower("${var.application_short_name}-${node_name}")
  }

  base_names_sanitized = {
    for node_name, raw in local.raw_base_names :
    node_name => regexreplace(raw, "[^0-9a-z-]", "-")
  }

  base_names_canonical = {
    for node_name, raw in local.base_names_sanitized :
    node_name => regexreplace(raw, "-+", "-")
  }

  base_names_trimmed = {
    for node_name, raw in local.base_names_canonical :
    node_name => regexreplace(regexreplace(raw, "^-", ""), "-$", "")
  }

  base_resource_names = {
    for node_name, raw in local.base_names_trimmed :
    node_name => raw != "" ? raw : lower(var.application_short_name)
  }

  linux_vm_names = {
    for node_name, base in local.base_resource_names :
    node_name => substr(base, 0, 64)
  }

  windows_vm_name_candidates = {
    for node_name, base in local.base_resource_names :
    node_name => regexreplace(regexreplace(substr(base, 0, 15), "^-", ""), "-$", "")
  }

  windows_vm_names = {
    for node_name, candidate in local.windows_vm_name_candidates :
    node_name => candidate != "" ? candidate : substr(lower(var.application_short_name), 0, 15)
  }

  jupyter_cloud_init = <<-EOT
    #cloud-config
    package_update: true
    packages:
      - python3
      - python3-pip
      - git

    write_files:
      - path: /usr/local/bin/start-jupyter.sh
        permissions: '0755'
        content: |
          #!/bin/bash
          exec /opt/venvs/jupyter/bin/jupyter lab \
            --ip=0.0.0.0 \
            --port=8888 \
            --NotebookApp.token='' \
            --NotebookApp.password='' \
            --no-browser \
            --notebook-dir=/var/lib/jupyter

      - path: /etc/systemd/system/jupyterlab.service
        permissions: '0644'
        content: |
          [Unit]
          Description=Jupyter Lab (venv)
          After=network-online.target

          [Service]
          Type=simple
          User=jupyter
          Group=jupyter
          Environment=HOME=/home/jupyter
          Environment=PATH=/opt/venvs/jupyter/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin
          Environment=JUPYTER_RUNTIME_DIR=/var/lib/jupyter/runtime
          WorkingDirectory=/var/lib/jupyter
          ExecStart=/usr/local/bin/start-jupyter.sh
          Restart=on-failure
          RestartSec=3
          NoNewPrivileges=true
          PrivateTmp=true
          ProtectSystem=full
          ProtectHome=true

          [Install]
          WantedBy=multi-user.target

    runcmd:
      # Create jupyter user and home
      - useradd --system --create-home --shell /sbin/nologin jupyter || true
      - mkdir -p /home/jupyter
      - chown -R jupyter:jupyter /home/jupyter
      - chmod 0750 /home/jupyter

      # Create venv and install Jupyter
      - python3 -m venv /opt/venvs/jupyter
      - /opt/venvs/jupyter/bin/pip install --upgrade pip setuptools wheel
      - /opt/venvs/jupyter/bin/pip install jupyterlab notebook

      # Prepare notebook and runtime dirs
      - mkdir -p /var/lib/jupyter/runtime
      - chown -R jupyter:jupyter /var/lib/jupyter

      # Ensure start script is executable
      - chmod +x /usr/local/bin/start-jupyter.sh

      # Reload systemd and start service
      - systemctl daemon-reload
      - systemctl enable --now jupyterlab.service

      # (Optional) open firewall for remote access
      - firewall-cmd --add-port=8888/tcp --permanent || true
      - firewall-cmd --reload || true

  EOT

  os_matrix = {
    windows_server_2022 = {
      os_type = "Windows"
      source_image_reference = {
        publisher = "MicrosoftWindowsServer"
        offer     = "WindowsServer"
        sku       = "2022-datacenter-g2"
        version   = "latest"
      }
      custom_data_base64 = null
    }
    rhel = {
      os_type = "Linux"
      source_image_reference = {
        publisher = "RedHat"
        offer     = "RHEL"
        sku       = "94-gen2"
        version   = "latest"
      }
      custom_data_base64 = null
    }
    rhel_jupyter = {
      os_type = "Linux"
      source_image_reference = {
        publisher = "RedHat"
        offer     = "RHEL"
        sku       = "94-gen2"
        version   = "latest"
      }
      custom_data_base64 = base64encode(trim(local.jupyter_cloud_init))
    }
  }

  default_os_disk = {
    caching      = "ReadWrite"
    disk_type    = "standard"
    disk_size_gb = null
  }

  normalized_os_disk = {
    for node_name, node in var.nodes :
    node_name => merge(local.default_os_disk, coalesce(node.os_disk, {}))
  }

  node_configs = {
    for node_name, node in var.nodes :
    node_name => {
      vm_name  = local.os_matrix[lower(node.os.type)].os_type == "Windows" ? local.windows_vm_names[node_name] : local.linux_vm_names[node_name]
      zone     = var.availability_zone
      sku_size = local.sku_lookup[lower(node.size)]

      os_profile = local.os_matrix[lower(node.os.type)]
      tags       = var.tags

      admin_username = var.default_admin_username

      custom_data_base64 = (
        try(node.os.custom_data, null) != null
        ? base64encode(node.os.custom_data)
        : local.os_matrix[lower(node.os.type)].custom_data_base64
      )

      password_authentication_disabled = coalesce(
        try(node.os.password_authentication_disabled, null),
        local.os_matrix[lower(node.os.type)].os_type == "Windows" ? true : false
      )

      network_interfaces = {
        for nic_key, nic in node.network_interfaces :
        nic_key => {
          name = "${local.base_resource_names[node_name]}-${nic_key}-nic"
          ip_configurations = {
            primary = {
              name                          = "ipconfig-${nic_key}"
              private_ip_subnet_resource_id = nic.subnet_resource_id
              private_ip_address_allocation = upper(nic.private_ip_address_allocation)
              private_ip_address            = try(nic.private_ip_address, null)
            }
          }
          accelerated_networking_enabled = nic.accelerated_networking_enabled
        }
      }

      data_disk_managed_disks = {
        for disk_key, disk in coalesce(try(node.data_disks, {}), {}) :
        disk_key => {
          name                 = "${local.base_resource_names[node_name]}-${disk_key}-disk"
          storage_account_type = local.disk_type_defaults[lower(coalesce(disk.disk_type, "standard"))].storage_account_type
          disk_size_gb = coalesce(
            try(disk.disk_size_gb, null),
            local.disk_type_defaults[lower(coalesce(disk.disk_type, "standard"))].default_size_gb
          )
          lun = coalesce(
            try(disk.lun, null),
            index(sort(keys(coalesce(try(node.data_disks, {}), {}))), disk_key)
          )
          caching       = coalesce(try(disk.caching, null), "ReadOnly")
          create_option = "Empty"
        }
      }

      os_disk = {
        caching              = local.normalized_os_disk[node_name].caching
        storage_account_type = local.disk_type_defaults[lower(local.normalized_os_disk[node_name].disk_type)].storage_account_type
        disk_size_gb = coalesce(
          local.normalized_os_disk[node_name].disk_size_gb,
          local.disk_type_defaults[lower(local.normalized_os_disk[node_name].disk_type)].default_size_gb
        )
      }
    }
  }

  hybrid_domain_join_domain_name = try(var.hybrid_domain_join_settings.domain_name, null)
  hybrid_domain_join_ou_path     = try(var.hybrid_domain_join_settings.ou_path, null)
  hybrid_domain_join_restart     = try(var.hybrid_domain_join_settings.restart, null)
  hybrid_domain_join_options     = try(var.hybrid_domain_join_settings.options, null)
  hybrid_domain_join_username    = var.hybrid_domain_join_username
  hybrid_domain_join_password    = var.hybrid_domain_join_password

  domain_join_settings_object = var.enable_hybrid_domain_join ? merge({
    Name    = local.hybrid_domain_join_domain_name
    User    = local.hybrid_domain_join_username
    Restart = "true"
    Options = "3"
    }, local.hybrid_domain_join_ou_path != null ? {
    OUPath = local.hybrid_domain_join_ou_path
  } : {}) : null

  domain_join_settings_json = var.enable_hybrid_domain_join ? jsonencode(local.domain_join_settings_object) : null

  domain_join_protected_settings_json = var.enable_hybrid_domain_join ? jsonencode({
    Password = local.hybrid_domain_join_password
  }) : null

  # Build per-node extension payloads for optional Active Directory integrations.
  node_extensions = {
    for node_name, cfg in local.node_configs :
    node_name => merge(
      var.enable_hybrid_domain_join && cfg.os_profile.os_type == "Windows" ? {
        domain_join = {
          name                              = "${cfg.vm_name}-domainjoin"
          publisher                         = "Microsoft.Compute"
          type                              = "JsonADDomainExtension"
          type_handler_version              = "1.3"
          auto_upgrade_minor_version        = true
          automatic_upgrade_enabled         = true
          failure_suppression_enabled       = false
          settings                          = local.domain_join_settings_json
          protected_settings                = local.domain_join_protected_settings_json
          protected_settings_from_key_vault = null
          provision_after_extensions        = []
          tags                              = cfg.tags
          timeouts                          = {}
          deploy_sequence                   = 1
        }
      } : {},
      var.aad_login_enabled && contains(["Windows", "Linux"], cfg.os_profile.os_type) ? {
        AADLogin = {
          name                              = "AADLogin"
          publisher                         = "Microsoft.Azure.ActiveDirectory"
          type                              = cfg.os_profile.os_type == "Windows" ? "AADLoginForWindows" : "AADSSHLoginForLinux"
          type_handler_version              = "1.0"
          auto_upgrade_minor_version        = true
          automatic_upgrade_enabled         = true
          failure_suppression_enabled       = false
          settings                          = null
          protected_settings                = null
          protected_settings_from_key_vault = null
          provision_after_extensions        = []
          deploy_sequence                   = 2
          timeouts                          = {}
        }

      } : {}
    )
  }
}
