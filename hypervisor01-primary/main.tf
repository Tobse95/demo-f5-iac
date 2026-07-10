# Self-service variable files land in subnets/<name>.yaml
#
# In production, replace null_resource with:
#   - resource "bigip_net_vlan"
#   - resource "bigip_net_selfip" (device + floating)

locals {
  subnets = {
    for f in fileset("${path.module}/subnets", "*.yaml") :
    trimsuffix(f, ".yaml") => yamldecode(file("${path.module}/subnets/${f}"))
  }
}

# Represents bigip_net_vlan
resource "null_resource" "vlan" {
  for_each = local.subnets

  triggers = {
    name    = "VLAN_${upper(each.key)}_${each.value.vlan_id}"
    tag     = tostring(each.value.vlan_id)
    cidr    = each.value.cidr
  }
}

# Represents bigip_net_selfip (device-local)
resource "null_resource" "selfip_device" {
  for_each = local.subnets

  triggers = {
    name      = "SELFIP_${upper(each.key)}_DEVICE"
    ip        = "${each.value.device_selfip}/${each.value.prefix_length}"
    vlan      = "VLAN_${upper(each.key)}_${each.value.vlan_id}"
    tg        = "traffic-group-local-only"
  }

  depends_on = [null_resource.vlan]
}

# Represents bigip_net_selfip (floating, primary only)
resource "null_resource" "selfip_floating" {
  for_each = { for k, v in local.subnets : k => v if v.is_primary }

  triggers = {
    name = "SELFIP_${upper(each.key)}_FLOAT"
    ip   = "${each.value.floating_selfip}/${each.value.prefix_length}"
    vlan = "VLAN_${upper(each.key)}_${each.value.vlan_id}"
    tg   = "traffic-group-1"
  }

  depends_on = [null_resource.vlan]
}

output "provisioned_subnets" {
  value = {
    for k, v in local.subnets : k => {
      vlan_name  = "VLAN_${upper(k)}_${v.vlan_id}"
      selfip     = "${v.device_selfip}/${v.prefix_length}"
      is_primary = v.is_primary
    }
  }
}
