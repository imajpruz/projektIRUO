# OpenStack networking explained

**Worth 1 point (I2)** — *"Adekvatno objašnjenje specifičnih mrežnih postavki"* —
and it underpins the 2 points for isolation and 1 for security groups.

Diagram: [diagrams/openstack-architecture.md](diagrams/openstack-architecture.md).

---

## Identity isolation and packet isolation are different controls

Keystone projects are the **control-plane** boundary: a user without a role in
another project cannot obtain a token scoped to it or operate its servers.
Neutron networks, routes and security groups are the **data-plane** boundary:
they determine whether one packet can reach another VM. Keystone denial alone
does not stop a VM from sending traffic to an address for which a route exists.

The implementation uses both. Every developer receives a separate project and
a disjoint private network. A project-specific Neutron RBAC policy shares that
network only with the management project. The management project then owns a
fixed `.253` port on it, attached to the central jump VM. The control-plane probe
proved this cross-project port model before it was encoded in Terraform.

```hcl
resource "openstack_networking_network_v2" "env" {
  name      = "net-${local.env_name}"
  tenant_id = var.project_id      # <- the isolation
}
```

The CIDRs must remain disjoint because one multihomed jump VM is attached to
every network. Repeated ranges would create ambiguous routes on that VM.

## Layer by layer

| Layer | Resource | Purpose |
|---|---|---|
| L2 | `openstack_networking_network_v2` | The tenant network |
| L3 | `openstack_networking_subnet_v2` | CIDR, DHCP, DNS resolvers |
| Routing | `openstack_networking_router_v2` | External gateway; SNAT for egress |
| Attachment | `openstack_networking_router_interface_v2` | Gives the router an address in the subnet (`.1`) |
| Port | `openstack_networking_port_v2` | The instance's NIC; carries the security groups |
| Management grant | `openstack_networking_rbac_policy_v2` | Lets only the management project own a jump port on this network |
| Firewall | `openstack_networking_secgroup_v2` | Allow-only ingress rules |
| Ingress | `openstack_networking_floatingip_v2` | One, on the bastion only |

Order matters when building by hand: the external gateway must be set **before**
the internal interface, or Neutron has nowhere to SNAT tenant traffic to.
Terraform derives that order from the dependency graph, which is exactly the
argument for declarative provisioning.

## Egress: router SNAT

*"Virtualne mašine moraju moći pristupiti Internetu radi preuzimanja paketa."*

```hcl
resource "openstack_networking_router_v2" "env" {
  external_network_id = var.external_network_id
}
```

Attaching an external gateway enables SNAT by default, so every instance in the
subnet reaches the internet through the router's external address, and nothing
outside can initiate a connection inward. No floating IP on any Moodle instance
means no inbound path exists at all.

```bash
openstack router show router-techsprint-test-marion -f value -c external_gateway_info
# {"network_id": "...", "enable_snat": true, "external_fixed_ips": [...]}
```

`enable_snat: true` plus a non-empty `external_fixed_ips` is the healthy state.
An empty `external_gateway_info` means the gateway did not attach — usually your
role lacks permission, or the provider network name is wrong.

## The floating IP is DNAT, not an interface

Every student trips over this once, so explaining it correctly is worth the
point. The floating IP is **not** configured on the instance; the router performs
DNAT. Inside the bastion, `ip addr` shows only the fixed address, forever.

```bash
openstack floating ip list -f table
# | Floating IP Address | Fixed IP Address |
# | 172.25.250.108      | 10.100.0.12      |

ssh cloud-user@172.25.250.108 'ip -4 addr show | grep inet'
#     inet 10.100.0.12/24        <- the floating IP appears nowhere
```

Compare with Azure, where a public IP is a resource *associated with a NIC* and
the model is more literal. Same outcome, different mental model — a good line for
the comparison section.

## Security groups: allow-only

Neutron security groups have no priorities and no deny rules. The implicit
default is deny-inbound, allow-outbound — the same posture as an Azure NSG,
reached by a different mechanism.

| Rule | Source | Port | Reason |
|---|---|---|---|
| SSH from jump | that environment's `.253/32` | 22 | Only the management-owned port in this network |
| HTTP from subnet | `subnet_cidr` | 80 | Load balancer probes and balanced traffic |
| MariaDB intra-group | `remote_group_id` = itself | 3306 | Node 2 reaches node 1's database |

`remote_group_id` is Neutron's equivalent of an Azure ASG: the rule names a
*group* rather than a CIDR, so members can reach each other and a non-member in
the same subnet cannot.

```hcl
resource "openstack_networking_secgroup_rule_v2" "db_intra_group" {
  protocol        = "tcp"
  port_range_min  = 3306
  remote_group_id = openstack_networking_secgroup_v2.moodle.id   # itself
}
```

### Differences from an NSG, for the comparison

| | Azure NSG | Neutron security group |
|---|---|---|
| Deny rules | Yes, with priorities | **No** — allow-only |
| Attached to | Subnet or NIC | Port |
| Group-based rules | ASG | `remote_group_id` |
| Explicit default rules | Visible at 65000+ | Implicit |
| Stateful | Yes | Yes |

The absence of deny rules matters in practice: Azure exposes its inherited
`DenyAllInBound` decision through Network Watcher. On OpenStack, isolation is
proven by what is *absent* — which is harder to evidence. The report therefore
combines the RBAC/route inventory with
ICMP, SSH and HTTP negative tests for every ordered developer pair.

### Leave the `default` group alone

Every project has a `default` security group that instances receive when none is
specified. On many labs it permits nothing inbound, which is why an instance
booted "with no security group" is unreachable. Modifying it affects every
instance in the project, so the stack always passes `security_group_ids`
explicitly.

```bash
openstack security group rule list default -f table
```

## MTU, if things hang

Lab tenant networks usually run over VXLAN or GENEVE, so the MTU is 1442 or 1450
rather than 1500. Symptom: `ping` works, SSH connects then freezes, `curl`
returns headers then stalls — small packets fit, large ones do not.

```bash
openstack network show net-techsprint-test-marion -f value -c mtu
# 1442

# Largest payload that passes unfragmented (add 28 for IP+ICMP headers)
for size in 1500 1450 1400; do
  printf '%s: ' "$size"
  ping -c1 -W2 -M do -s $((size-28)) 10.10.1.4 >/dev/null 2>&1 && echo ok || echo "too big"
done
```

If it bites, set the MTU on the instances and say so in the report — diagnosing a
stacked-encapsulation MTU problem correctly reads far better than never hitting
one.

## Verifying it

```bash
# 1. Topology
openstack network list --tags project=techsprint -f table
openstack subnet list -f table
openstack router list -f table
openstack port list --network net-techsprint-test-marion -f table

# 2. Exactly one floating IP in the whole deployment
openstack floating ip list -f table
# one row: the bastion

# 3. Rules on a developer's group
openstack security group rule list sg-techsprint-test-marion-moodle -f table

# 4. Isolation, the negative test that carries the 2 points
OS_USERNAME=mario.nikolis OS_PROJECT_NAME=proj-techsprint-test-andrijam \
  openstack server list
# authentication/authorization failure - screenshot this
```

Horizon → *Project → Network → Network Topology* draws the diagram for you and
is authoritative. Screenshot it alongside the hand-drawn one.

---

Previous: [Azure and OpenStack compared](06-cloud-comparison.md) ·
Next: [Load balancer comparison](08-azure-loadbalancer.md)
