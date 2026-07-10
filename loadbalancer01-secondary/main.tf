# Self-service variable files land in subnets/<name>.yaml
#
# In production, replace null_resource with:
#   - resource "bigip_net_vlan"
#   - resource "bigip_net_selfip" (device + floating)
#   - resource "bigip_as3" (forwarding VS + LB VSes)

locals {
  subnets = {
    for f in fileset("${path.module}/subnets", "*.yaml") :
    trimsuffix(f, ".yaml") => yamldecode(file("${path.module}/subnets/${f}"))
  }

  # Flatten virtual_servers list across all subnets for individual LB VS resources.
  lb_entries = merge([
    for sname, s in local.subnets : {
      for idx, vs in try(s.virtual_servers, []) :
      "${sname}-vs${idx}" => merge(vs, { subnet_name = sname, vlan_id = s.vlan_id })
    }
  ]...)
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

# Subnet forwarding (AS3 route advertisement) is always enabled for loadbalancer devices.
resource "null_resource" "as3_forwarding" {
  for_each = local.subnets

  triggers = {
    vs_name         = "vs_${replace(each.key, "-", "_")}_fwd"
    virtual_address = split("/", each.value.cidr)[0]
    vlan            = "VLAN_${upper(each.key)}_${each.value.vlan_id}"
    layer4          = "any"
  }

  depends_on = [null_resource.selfip_device]
}

# One resource per virtual server entry (supports multiple VSes per subnet).
resource "null_resource" "as3_lb" {
  for_each = local.lb_entries

  triggers = {
    vs_name  = "vs_${replace(each.value.subnet_name, "-", "_")}_${replace(each.key, "-", "_")}"
    vs_ip    = each.value.virtual_server_ip
    vs_port  = tostring(each.value.virtual_server_port)
    protocol = try(each.value.protocol, "tcp")
    vlan     = "VLAN_${upper(each.value.subnet_name)}_${each.value.vlan_id}"
  }

  depends_on = [null_resource.selfip_device]
}

output "provisioned_subnets" {
  value = {
    for k, v in local.subnets : k => {
      vlan_name     = "VLAN_${upper(k)}_${v.vlan_id}"
      selfip        = "${v.device_selfip}/${v.prefix_length}"
      is_primary    = v.is_primary
      forwarding_vs = "vs_${replace(k, "-", "_")}_fwd"
      lb_vs_count   = length(try(v.virtual_servers, []))
    }
  }
}
