# Self-service variable files land in subnets/<name>.yaml
#
# In production, replace null_resource with:
#   - resource "bigip_net_vlan"
#   - resource "bigip_net_selfip" (device + floating)
#   - resource "bigip_as3" (forwarding VS + optional LB VS)

locals {
  subnets = {
    for f in fileset("${path.module}/subnets", "*.yaml") :
    trimsuffix(f, ".yaml") => yamldecode(file("${path.module}/subnets/${f}"))
  }
}

resource "null_resource" "vlan" {
  for_each = local.subnets

  triggers = {
    name = "VLAN_${upper(each.key)}_${each.value.vlan_id}"
    tag  = tostring(each.value.vlan_id)
    cidr = each.value.cidr
  }
}

resource "null_resource" "selfip_device" {
  for_each = local.subnets

  triggers = {
    name = "SELFIP_${upper(each.key)}_DEVICE"
    ip   = "${each.value.device_selfip}/${each.value.prefix_length}"
    vlan = "VLAN_${upper(each.key)}_${each.value.vlan_id}"
    tg   = "traffic-group-local-only"
  }

  depends_on = [null_resource.vlan]
}

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

# Represents bigip_as3 forwarding virtual server
resource "null_resource" "as3_forwarding" {
  for_each = { for k, v in local.subnets : k => v if v.subnet_forwarding_enabled }

  triggers = {
    vs_name         = "vs_${replace(each.key, "-", "_")}_fwd"
    virtual_address = split("/", each.value.cidr)[0]
    vlan            = "VLAN_${upper(each.key)}_${each.value.vlan_id}"
    layer4          = "any"
  }

  depends_on = [null_resource.selfip_device]
}

# Represents bigip_as3 load balancing virtual server (optional)
resource "null_resource" "as3_lb" {
  for_each = { for k, v in local.subnets : k => v if v.lb_enabled }

  triggers = {
    vs_name    = "vs_${replace(each.key, "-", "_")}_lb"
    vs_ip      = each.value.lb_virtual_server_ip
    vs_port    = tostring(each.value.lb_virtual_server_port)
    protocol   = each.value.lb_protocol
  }

  depends_on = [null_resource.selfip_device]
}

output "provisioned_subnets" {
  value = {
    for k, v in local.subnets : k => {
      vlan_name       = "VLAN_${upper(k)}_${v.vlan_id}"
      selfip          = "${v.device_selfip}/${v.prefix_length}"
      is_primary      = v.is_primary
      forwarding_vs   = v.subnet_forwarding_enabled ? "vs_${replace(k, "-", "_")}_fwd" : "disabled"
      lb_vs           = v.lb_enabled ? "vs_${replace(k, "-", "_")}_lb" : "disabled"
    }
  }
}
