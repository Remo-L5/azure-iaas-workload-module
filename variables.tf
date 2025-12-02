variable "location" {
  description = "Azure region for all VM resources."
  type        = string
}

variable "resource_group_name" {
  description = "Resource group that will contain the VMs."
  type        = string
}

variable "application_short_name" {
  description = "Short application identifier used as the base for all generated resource names."
  type        = string
}

variable "default_admin_username" {
  description = "Fallback administrator username when a node does not override it."
  type        = string
  default     = "azureuser"
}

variable "nodes" {
  description = <<EOT
Map of VM node definitions. Each entry allows custom OS, size, disks, and NIC configuration, e.g.

nodes = {
  app01 = {
    size = "small"
    os = {
      type = "windows_server_2022"
    }
    network_interfaces = {
      primary = {
        subnet_resource_id = "/subscriptions/.../subnets/app"
      }
    }
    data_disks = {
      logs = {
        disk_size_gb = 128
        disk_type    = "premium"
      }
    }
  }
}
EOT

  type = map(object({
    size = string
    os = object({
      type                             = string
      custom_data                      = optional(string)
      password_authentication_disabled = optional(bool)
    })
    network_interfaces = map(object({
      subnet_resource_id             = string
      private_ip_address             = optional(string)
      private_ip_address_allocation  = optional(string, "Dynamic")
      accelerated_networking_enabled = optional(bool, false)
    }))
    data_disks = optional(map(object({
      disk_size_gb = optional(number)
      disk_type    = optional(string, "standard")
      caching      = optional(string)
      lun          = optional(number)
    })), {})
    os_disk = optional(object({
      caching      = optional(string)
      disk_type    = optional(string, "standard")
      disk_size_gb = optional(number)
    }), null)
  }))

  validation {
    condition     = length(var.nodes) > 0
    error_message = "Provide at least one node definition."
  }

  validation {
    condition = alltrue([
      for node in var.nodes : contains(["small", "medium", "large"], lower(node.size))
    ])
    error_message = "node.size must be one of small, medium, or large."
  }

  validation {
    condition = alltrue([
      for node in var.nodes : contains(["windows_server_2022", "rhel", "rhel_jupyter"], lower(node.os.type))
    ])
    error_message = "node.os.type must be windows_server_2022, rhel, or rhel_jupyter."
  }

  validation {
    condition = alltrue([
      for node in var.nodes : length(node.network_interfaces) > 0
    ])
    error_message = "Each node must declare at least one network interface."
  }

  validation {
    condition = alltrue([
      for node in var.nodes :
      alltrue([
        for disk in values(try(node.data_disks, {})) :
        contains(["standard", "premium", "ultra"], lower(coalesce(disk.disk_type, "standard")))
      ])
    ])
    error_message = "Each data disk must use a disk_type of standard, premium, or ultra."
  }

  validation {
    condition = alltrue([
      for node in var.nodes :
      node.os_disk == null || try(node.os_disk.disk_type, null) == null || contains(["standard", "premium", "ultra"], lower(node.os_disk.disk_type))
    ])
    error_message = "os_disk.disk_type must be standard, premium, or ultra."
  }
}

variable "key_vault_config" {
  description = "Optional key vault configuration for storing generated admin credentials."
  type = object({
    resource_id   = string
    secret_prefix = string
  })
}

variable "tags" {
  description = "Common tags merged into every VM resource."
  type        = map(string)
  default     = {}
}

variable "availability_zone" {
  description = "Optional Azure availability zone applied to every VM in this module."
  type        = string
  default     = null
}

variable "enable_telemetry" {
  description = "Controls telemetry collection within the downstream AVM module."
  type        = bool
  default     = true
}

variable "enable_hybrid_domain_join" {
  description = "Installs the JsonADDomainExtension on Windows nodes so they can hybrid-join an Active Directory domain."
  type        = bool
  default     = false

  validation {
    condition = !var.enable_hybrid_domain_join || (
      var.hybrid_domain_join_settings != null &&
      var.hybrid_domain_join_username != null &&
      var.hybrid_domain_join_password != null
    )
    error_message = "enable_hybrid_domain_join requires hybrid_domain_join_settings, hybrid_domain_join_username, and hybrid_domain_join_password."
  }
}

variable "hybrid_domain_join_settings" {
  description = "Non-sensitive settings for the JsonADDomainExtension, such as domain name and OU path. Only used when enable_hybrid_domain_join is true."
  type = object({
    domain_name = string
    ou_path     = optional(string)
  })
  default = null
}

variable "hybrid_domain_join_username" {
  description = "User principal name or SAM account name used for hybrid domain join operations."
  type        = string
}

variable "hybrid_domain_join_password" {
  description = "Password associated with hybrid_domain_join_username."
  type        = string
  sensitive   = true
}

variable "aad_login_enabled" {
  description = "Installs the AADLoginForWindows or AADSSHLoginForLinux extension so Azure AD users can sign in to Windows or Linux nodes."
  type        = bool
  default     = false
}
