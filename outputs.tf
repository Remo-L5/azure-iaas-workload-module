output "virtual_machine_ids" {
  description = "Map of VM resource IDs keyed by node."
  value       = { for node, module_ref in module.vm_nodes : node => module_ref.resource_id }
}

output "admin_usernames" {
  description = "Admin username resolved for each node."
  value       = { for node, cfg in local.node_configs : node => cfg.admin_username }
}

output "network_interfaces" {
  description = "Full network interface objects from the AVM child modules."
  value       = { for node, module_ref in module.vm_nodes : node => module_ref.network_interfaces }
  sensitive   = true
}

output "key_vault_secret_names" {
  description = "Secret names created per node when key vault integration is enabled."
  value = var.key_vault_config == null ? null : {
    for node in keys(local.node_configs) :
    node => format("%s-%s", var.key_vault_config.secret_prefix, node)
  }
}
