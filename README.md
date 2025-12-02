# azure-iaas-workload-module

This module wraps the Azure Verified Module (AVM) `avm-res-compute-virtualmachine` to offer a higher level interface for provisioning heterogeneous virtual machines for an IaaS workload. It focuses on:

- Accepting a map of nodes with per-node size, OS flavor, NIC definitions, and managed disk layouts.
- Enforcing approved SKU sizes (`small`, `medium`, `large`).
- Providing opinionated OS images (Windows Server 2022, RHEL 9, or RHEL 9 with a preinstalled Jupyter Lab cloud-init script).
- Integrating with Azure Key Vault to store generated local administrator credentials using a consistent secret prefix.
- Optionally adding VM extensions for JsonADDomainExtension-based hybrid domain join plus Azure AD login (Windows) or Azure AD SSH login (Linux).

## Usage

```hcl
module "workload_vms" {
  source = "./modules/vm-wrapper"

  location            = var.location
  resource_group_name = azurerm_resource_group.workload.name
  application_short_name = "nva"
  availability_zone   = "1"

  key_vault_config = {
    resource_id   = azurerm_key_vault.credentials.id
    secret_prefix = "nva-admin"
  }

  nodes = {
    control = {
      size = "small"
      os = {
          type = "windows_server_2022"
      }
      network_interfaces = {
        primary = {
          subnet_resource_id = azurerm_subnet.management.id
        }
      }
      data_disks = {
        logs = {
          disk_size_gb = 128
          disk_type    = "premium"
        }
      }
    }

    analytics = {
      size = "large"
      os = {
        type = "rhel_jupyter"
      }
      network_interfaces = {
        primary = {
          subnet_resource_id             = azurerm_subnet.data.id
          private_ip_address_allocation  = "Static"
          private_ip_address             = "10.0.20.10"
          accelerated_networking_enabled = true
        }
      }
      data_disks = {
        telemetry = {
          disk_size_gb = 256
          disk_type    = "premium"
          caching      = "ReadOnly"
        }
        archive = {
          disk_size_gb = 512
          disk_type    = "standard"
          caching      = "ReadOnly"
        }
      }
    }
  }

  tags = {
    environment = "prod"
    workload    = "nva"
  }
}
```

## Inputs

| Name | Type | Description |
|------|------|-------------|
| `location` | `string` | Azure region for all VM resources. |
| `resource_group_name` | `string` | Resource group that will contain the VM assets. |
| `application_short_name` | `string` | Short identifier used to build standardized VM, NIC, and disk names. |
| `default_admin_username` | `string` | Optional default administrator username (defaults to `azureuser`). |
| `nodes` | `map(object)` | Map of node definitions. Each node requires `size`, an `os` block, at least one `network_interfaces` entry, and optional data disk map or OS disk overrides. See inline type in `variables.tf` for the precise schema. |
| `key_vault_config` | `object({resource_id, secret_prefix})` | Optional Key Vault reference for storing generated credentials. Provide a value or pass `null` when password escrow is not required. Secret names follow `<secret_prefix>-<node_key>`. |
| `availability_zone` | `string` | Optional Azure availability zone applied uniformly to every VM. Use `null` to deploy without zone pinning. |
| `tags` | `map(string)` | Global tags applied to every resource created by the module. |
| `enable_telemetry` | `bool` | Pass-through toggle for AVM telemetry (defaults to `true`). |
| `enable_hybrid_domain_join` | `bool` | Enables the JsonADDomainExtension on Windows nodes using the settings below. |
| `hybrid_domain_join_settings` | `object` | Domain-specific values (name, optional OU path, restart/options flags) consumed by the JsonADDomainExtension when `enable_hybrid_domain_join` is true. |
| `hybrid_domain_join_username` | `string` | User principal name or SAM account name used during domain join when `enable_hybrid_domain_join` is true. |
| `hybrid_domain_join_password` | `string` | Sensitive password paired with `hybrid_domain_join_username`. |
| `aad_login_enabled` | `bool` | Installs `AADLoginForWindows` on Windows guests and `AADSSHLoginForLinux` on Linux guests. |

### Node Object Highlights

- `size`: One of `small`, `medium`, or `large`, which map to `Standard_D2s_v5`, `Standard_D4s_v5`, and `Standard_D8s_v5`.
- `os.type`: `windows_server_2022`, `rhel`, or `rhel_jupyter`.
- `network_interfaces`: Map of NIC definitions. Each NIC requires a `subnet_resource_id`; static IPs are optional.
- `data_disks`: Optional map describing managed disks, each referencing a friendly `disk_type` of `standard`, `premium`, or `ultra`. `disk_size_gb` defaults to `128`, `256`, or `512` respectively when omitted, and `lun` is auto-assigned.
- Resource names (VMs, NICs, disks) are auto-generated from `application_short_name` plus the node keys, with OS-aware truncation to satisfy Azure/guest restrictions.
- Availability zone is controlled at the module level; per-node zone overrides are not supported.

## Outputs

| Name | Description |
|------|-------------|
| `virtual_machine_ids` | Map of VM resource IDs keyed by node. |
| `admin_usernames` | Map of resolved administrator usernames per node. |
| `network_interfaces` | Map of full NIC objects returned by the AVM module (sensitive). |
| `key_vault_secret_names` | Map of expected secret names when `key_vault_config` is provided; `null` otherwise. |

## Notes

- The `rhel_jupyter` flavor injects a cloud-init script that installs Jupyter Lab as a systemd service listening on port `8888` with no authentication. Adjust the script or secure the endpoint before exposing it.
- Linux nodes default to SSH key authentication (password login disabled) while Windows nodes use auto-generated passwords. Toggle `os.password_authentication_disabled` per node as needed.
- Disk type to SKU mapping (plus default sizes) lives in `locals.tf`. Customize the `local.disk_type_defaults` map if you need different storage SKUs or disk sizes.
- The module derives VM/NIC/disk names from `application_short_name`. Windows VM names are truncated to 15 characters to meet NetBIOS limits; Linux VM names use up to 64 characters.
- Because this module delegates to AVM, ensure required providers (`azurerm`, `azapi`, `modtm`, etc.) are declared in the root module that consumes this wrapper.
- The embedded AVM dependency is pinned to `0.20.0`. Update `module "vm_nodes"` if you need a different release.
- Provide `key_vault_config = null` when you do not want to persist passwords in Key Vault.

### Hybrid Domain Join and Azure AD Login

Set `enable_hybrid_domain_join = true` to install the `JsonADDomainExtension` on every Windows node. Provide the declarative inputs plus sensitive credentials, for example:

```hcl
enable_hybrid_domain_join = true

hybrid_domain_join_settings = {
  domain_name = "contoso.com"
  ou_path     = "OU=Servers,DC=contoso,DC=com"
  restart     = true
  options     = 3
}

hybrid_domain_join_username = "contoso\\joiner"
hybrid_domain_join_password = var.domain_join_password

aad_login_enabled = true
```

The settings map renders directly into the extension JSON payload (matching the `Name`, `OUPath`, `Restart`, and `Options` keys from the Azure sample), while the username/password inputs feed the protected settings. When `aad_login_enabled` is true the module installs `AADLoginForWindows` on Windows nodes and `AADSSHLoginForLinux` on Linux nodes; other OS types skip the extension.
```