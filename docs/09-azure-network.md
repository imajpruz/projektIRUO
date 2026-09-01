# Azure networking explained

**Worth 1 point (I4)** — *"Adekvatno objašnjenje Azure mrežnih postavki"* — but
it also underpins the 2 points for isolation and the 1 point for NSGs/ASGs.

Diagram: [diagrams/azure-architecture.md](diagrams/azure-architecture.md).

---

## Address plan

| Range | Purpose | Reserved |
|---|---|---|
| `10.0.0.0/16` | hub VNet | — |
| `10.0.1.0/24` | `snet-jump`, the bastion | Azure takes 5 addresses |
| `10.10.0.0/16` | developer 0 VNet | — |
| `10.10.1.0/24` | `snet-app`, Moodle + LB frontend at `.250` | Azure takes 5 |
| `10.11.0.0/16` | developer 1 VNet | — |
| `10.11.1.0/24` | developer 1 app subnet | Azure takes 5 |

A `/16` per developer, indexed by CSV position in `lib/parse_users.py`, so
overlap is impossible by construction. Terraform re-checks it anyway:

```hcl
validation {
  condition     = length(distinct([for dev in var.developers : dev.vnet_cidr])) == length(var.developers)
  error_message = "Every developer needs a distinct vnet_cidr."
}
```

Azure reserves 5 addresses per subnet: `.0` network, `.1` gateway, `.2` and `.3`
for DNS mapping, `.255` broadcast. A `/24` therefore yields 251 usable, which is
why subnets are not sized to the bone.

## Isolation: why hub-and-spoke works

Two requirements conflict. The lead must reach every VM; developers must reach
only their own. Hub-and-spoke resolves it because **VNet peering is not
transitive**.

Each spoke has exactly one peering, to the hub. The hub does run a forwarding
appliance, but spoke route tables send only `0.0.0.0/0` to it for Internet
egress. The NVA subnet NSG permits forwarded packets only when their destination
is the `Internet` service tag; Azure's default inbound deny rejects every other
forwarded flow. The jump host's nftables policy independently drops traffic
whose source and destination are both private.

```hcl
resource "azurerm_virtual_network_peering" "spoke_to_hub" {
  allow_virtual_network_access = true
  allow_forwarded_traffic      = true    # required for controlled NVA egress
  allow_gateway_transit        = false
  use_remote_gateways          = false
}
```

Forwarding is therefore explicit rather than broadly trusted: the route, NVA
firewall and hub NSG all have to agree. Direct spoke-to-spoke traffic has no
peering route at all.

```bash
# Each spoke has one peering, pointing at the hub, with controlled forwarding
az network vnet peering list -g rg-techsprint-test-marion \
  --vnet-name vnet-techsprint-test-marion \
  --query "[].{name:name, state:peeringState, forwarded:allowForwardedTraffic}" -o table
```

## NSG rules and why each exists

Attached to the **subnet**, not the NIC, so every VM added later inherits them
and there is one place to audit.

| Priority | Rule | Source | Port | Reason |
|---|---|---|---|---|
| 100 | `allow-ssh-http-from-hub` | hub CIDR | 22, 80 | The bastion is the only management/application path in |
| 110 | `allow-http-from-loadbalancer` | `AzureLoadBalancer` | 80 | Health probes |
| 120 | `allow-moodle-peer-db-and-http` | the Moodle ASG | 80, 3306 | Node 2 reaches node 1's MariaDB; scoped to group members |
| 65000 | `AllowVnetInBound` | platform | * | Cannot be removed |
| 65500 | `DenyAllInBound` | platform | * | Cannot be removed — the default posture |

Two points to make in the report:

**NSGs are default-deny inbound, default-allow outbound.** The 65000-series rules
are platform defaults you inherit and cannot delete. Your rules only ever *open*
things. Knowing this shows you understand the model rather than having pasted
rules until something worked.

## Application security groups

An ASG lets a rule name a *role* instead of an address range.

```hcl
source_application_security_group_ids      = [azurerm_application_security_group.moodle.id]
destination_application_security_group_ids = [azurerm_application_security_group.moodle.id]
```

The MariaDB rule reads "from Moodle nodes to Moodle nodes on 3306" rather than
"from 10.10.1.0/24 to 10.10.1.0/24". Two consequences: adding a third Moodle node
needs no rule edit, and the rule cannot accidentally admit a non-Moodle VM that
happens to sit in the same subnet.

Only Moodle NICs join the ASG. The jump host is already isolated in its own
subnet and resource group, so a second single-member ASG would add no control.

## Egress without ingress

*"Virtualne mašine moraju moći pristupiti Internetu radi preuzimanja paketa"* —
but the rubric also permits a public IP only on the jump host. A user-defined
route sends default traffic to that jump VM:

```hcl
resource "azurerm_route" "default_via_jump" {
  address_prefix         = "0.0.0.0/0"
  next_hop_type          = "VirtualAppliance"
  next_hop_in_ip_address = var.hub_private_ip
}
```

Why not the alternatives:

| Option | Problem |
|---|---|
| Public IP per VM | Directly violates "javni IP isključivo na Jump hostu" |
| Default outbound access | Being retired (September 2025); also prone to SNAT port exhaustion |
| Load balancer outbound rules | Works, but couples egress to the LB's lifecycle |
| NAT gateway per spoke | Requires two additional public IP resources |
| **Jump VM as NVA/NAT** | Reuses the sole permitted public IP; sufficient for a small test environment |

The jump NIC enables IP forwarding, Ubuntu enables `net.ipv4.ip_forward`, and
`nftables` applies both source NAT and a default-drop forward policy that rejects
private cross-spoke destinations. This is intentionally a student-scale choice:
it is cheaper and rubric-compatible, but it makes package downloads depend on
the jump VM.

For traffic originating on the jump host, its NSG allows only SSH and HTTP to
each developer CIDR, then denies other `10.0.0.0/8` destinations. This prevents
the bastion from pivoting directly to MariaDB or unrelated private services.

## Storage access

Each developer has separate Blob and Files accounts. BlobFuse authenticates
with a managed identity scoped to one private container; the Files key therefore
cannot bypass that boundary. Both accounts deny network access by default. A
`Microsoft.Storage` service endpoint admits the developer subnet, while one
workstation-IP exception lets Terraform create the container and share.

## Verifying the whole story

```bash
# 1. No Moodle VM has a public IP
az network nic list --query \
  "[?contains(resourceGroup,'techsprint')].{nic:name, publicIp:ipConfigurations[0].publicIpAddress.id}" -o table
# publicIp must be null for every NIC except the bastion's

# 2. Ask Azure to trace a packet - it names the exact rule that decided
az network watcher test-ip-flow \
  -g rg-techsprint-test-marion --vm vm-techsprint-test-marion-moodle-1 \
  --direction Inbound --protocol TCP --local 10.10.1.4:22 --remote 10.0.1.4:33000
# Access: Allow, Rule: allow-ssh-http-from-hub

az network watcher test-ip-flow \
  -g rg-techsprint-test-marion --vm vm-techsprint-test-marion-moodle-1 \
  --direction Inbound --protocol TCP --local 10.10.1.4:22 --remote 10.11.1.4:33000
# Access: Deny, Rule: DenyAllInBound
```

`test-ip-flow` is the best NSG evidence available and almost nobody uses it: it
returns the rule name that allowed or denied a specific packet. Two invocations
— one allowed from the hub, one denied from a peer developer — prove the
isolation design in a way a rule listing cannot.

```bash
# 3. Effective rules on the NIC, which catches a second NSG overriding the subnet one
az network nic list-effective-nsg -g rg-techsprint-test-marion \
  -n nic-techsprint-test-marion-moodle-1 -o table
```

---

Previous: [Load balancer comparison](08-azure-loadbalancer.md) ·
Next: [OpenStack lab discovery](10-openstack-discovery.md)
