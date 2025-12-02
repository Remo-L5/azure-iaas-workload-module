module "vm_nodes" {
  for_each = local.node_configs

  source  = "Azure/avm-res-compute-virtualmachine/azurerm"
  version = "0.20.0"

  name                = each.value.vm_name
  location            = var.location
  resource_group_name = var.resource_group_name
  zone                = each.value.zone

  sku_size               = each.value.sku_size
  os_type                = each.value.os_profile.os_type
  source_image_reference = each.value.os_profile.source_image_reference
  custom_data            = each.value.custom_data_base64

  os_disk                 = each.value.os_disk
  data_disk_managed_disks = each.value.data_disk_managed_disks
  network_interfaces      = each.value.network_interfaces
  extensions              = local.node_extensions[each.key]

  account_credentials = {
    admin_credentials = {
      username = each.value.admin_username
    }
    password_authentication_disabled = each.value.password_authentication_disabled
    key_vault_configuration = {
      resource_id = var.key_vault_config.resource_id
      secret_configuration = {
        name = "${var.key_vault_config.secret_prefix}-${each.key}"
      }
    }
  }

  tags             = each.value.tags
  enable_telemetry = var.enable_telemetry
}
