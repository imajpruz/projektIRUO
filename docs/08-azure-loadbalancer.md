# Azure Load Balancer vs Application Gateway

**Worth 2 points (I4)** — the rubric asks for a load balancer *implemented and
compared*: "Implementirano i uspoređeno rješenje za Load Balancer (npr. Azure LB
vs App Gateway)". The comparison is half the marks, so do not just state which
one you used.

---

## The two products

| | Standard Load Balancer | Application Gateway v2 |
|---|---|---|
| OSI layer | 4 — TCP/UDP | 7 — HTTP/HTTPS |
| Routing decision | five-tuple hash, or source IP | URL path, hostname, headers, cookies |
| Understands HTTP | No | Yes |
| TLS termination | No (passes TCP through) | Yes, with certificate management |
| Web Application Firewall | No | Yes, optional (OWASP rule sets) |
| Cookie-based session affinity | No (source IP only) | Yes, injects its own cookie |
| Health probe | TCP, HTTP, HTTPS | HTTP/HTTPS, with body matching |
| URL rewriting / redirects | No | Yes |
| Autoscaling | n/a (it is a distributed platform service) | Yes, 0–125 capacity units |
| Latency added | ~microseconds | ~milliseconds |
| Base cost/month | ~18 EUR | ~125 EUR + capacity units |
| Free tier | No | No |

## What was chosen, and why

**Standard Load Balancer, internal.** Two reasons, one about the brief and one
about money.

**The brief forbids a public frontend.** *"Ne smije postojati izravan javni
pristup ostalim instancama"* and *"javni IP isključivo na Jump hostu"*.
Application Gateway can also use a private frontend, but its layer-7 features
and much higher base cost are unnecessary here. The internal load balancer has
a private frontend at `10.x.1.250`, reachable only from inside the developer's
VNet, and Moodle is accessed through an SSH tunnel via the bastion:

```bash
ssh -D 1080 -i build/ssh/id_ed25519 techsprint@<bastion-ip>
# use SOCKS5 localhost:1080, then open http://10.10.1.250/
```

**The cost is not close.** Per developer, per month:

| | Standard LB | Application Gateway v2 |
|---|---|---|
| Base | 16.79 | 22.63 (fixed gateway hour) |
| Capacity units (minimum 1) | — | ~102 |
| Data processed (~5 GB) | 0.02 | included in CU |
| **Total** | **≈ 16.81** | **≈ 125** |

Against a 100 EUR student grant, one Application Gateway per developer exceeds
the entire grant every month. For two developers it is 250 EUR/month for L7
features this deployment does not use.

## The features Application Gateway would have added

Be specific about what was given up, rather than implying the cheaper option was
strictly better:

| Feature | Would it help Moodle? |
|---|---|
| TLS termination | **Yes, genuinely.** Moodle over plain HTTP is the design's weakest point. App Gateway would terminate HTTPS centrally instead of managing certificates on each node |
| Web Application Firewall | **Yes.** Moodle is a large PHP application with a real CVE history; an OWASP rule set in front of it is meaningful defence |
| Cookie-based affinity | **Yes, and better than what we have.** Source-IP affinity breaks when many users share a NAT address — an entire university network would pin to one backend |
| Path-based routing | No. One application, no microservices to split |
| URL rewriting | No |
| Autoscaling | No. Two fixed backends by requirement |

Two of those are real losses. The honest conclusion is that Standard LB is right
for *this* project's constraints, and Application Gateway would be right for a
production Moodle — and the reason is the student grant, not the architecture.

## What was implemented

```hcl
resource "azurerm_lb" "moodle" {
  name                = "lb-${local.env_name}-moodle"
  sku                 = "Standard"

  frontend_ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.app.id
    private_ip_address_allocation = "Static"
    private_ip_address            = cidrhost(var.subnet_app_cidr, 250)
  }
}
```

Three configuration choices worth defending:

**Static private frontend at `.250`.** High in the subnet so Azure's dynamic
allocation for NICs (which starts at `.4`) cannot collide with it. Static so
Moodle's `$CFG->wwwroot` stays valid across a load balancer restart.

**HTTP probe on `/healthz.php`, not a TCP probe.**

```hcl
resource "azurerm_lb_probe" "moodle" {
  protocol            = "Http"
  port                = 80
  request_path        = "/healthz.php"
  interval_in_seconds = 15
  number_of_probes    = 2
}
```

A TCP probe proves only that Apache accepted a connection. The HTTP endpoint
returns 503 unless Moodle's config, database, data disk, object mount and file
mount are available. Its response also identifies the selected node. Storage
and database configuration complete before the Moodle installer, so a backend
joins the pool only after all required dependencies are healthy.

**`load_distribution = "SourceIP"`.**

```hcl
resource "azurerm_lb_rule" "moodle_http" {
  load_distribution = "SourceIP"
  tcp_reset_enabled = true
}
```

Moodle stores session state on the node that created it unless sessions are
externalised to Redis or the database. With Azure's default five-tuple
distribution a user's requests alternate between backends and they are logged out
on roughly every second click. Source-IP affinity pins each client to one node.

The limitation, which belongs in the report: this breaks down when many clients
share one NAT address, and it means a node failure logs out everyone pinned to
it. The correct production fix is a shared session store — see
[13-known-limitations.md](13-known-limitations.md).

## Proving it balances

The single most convincing piece of evidence, because it needs no explanation.
The Apache vhost sets a per-node header:

```apache
Header always set X-TechSprint-Node "{{ inventory_hostname }}"
```

Because the rule uses `SourceIP`, repeated requests from one jump host are
supposed to stay on one backend. Prove both backends independently first:

```bash
ssh marion-moodle-1 'curl -sI http://127.0.0.1/healthz.php | grep -i x-techsprint-node'
ssh marion-moodle-2 'curl -sI http://127.0.0.1/healthz.php | grep -i x-techsprint-node'
```

```
X-TechSprint-Node: marion-moodle-1
X-TechSprint-Node: marion-moodle-2
```

Then prove both NICs are members of Azure's backend pool:

```
az network lb address-pool show \
  -g rg-techsprint-test-marion \
  --lb-name lb-techsprint-test-marion-moodle \
  -n bepool-moodle \
  --query "length(backendIPConfigurations)" -o tsv
# 2
```

`lib/verify.sh` checks each node and the balancer path. Capture the backend-pool
command separately, then use the failover demonstration below to prove traffic
moves when the affinity-selected backend becomes unhealthy.

### Failover demonstration

Better evidence than balancing, and it takes 60 seconds on camera:

```bash
# Watch which node answers
while true; do curl -sI http://10.10.1.250/ | grep -i x-techsprint-node; sleep 2; done

# In another terminal, break node 1's health check
ssh marion-moodle-1 'sudo systemctl stop httpd'
```

Within two probe intervals (30 s) every response comes from node 2. Restart
Apache and node 1 rejoins after two successful probes. That is the *"simulirati
visoku dostupnost"* requirement demonstrated rather than asserted.

```bash
# Health state as Azure sees it
az network lb probe show -g rg-techsprint-test-marion \
  --lb-name lb-techsprint-test-marion-moodle -n probe-moodle-http -o table

# Backend pool membership
az network lb address-pool show -g rg-techsprint-test-marion \
  --lb-name lb-techsprint-test-marion-moodle -n bepool-moodle \
  --query "backendIPConfigurations[].id" -o tsv | wc -l
# 2
```

## OpenStack's equivalent

For the cross-cloud comparison table:

| | Azure Standard LB | Octavia | HAProxy on an instance |
|---|---|---|---|
| Managed | Yes | Yes | No — you patch it |
| Layer | 4 | 4 and 7 | 7 |
| Affinity method | `SourceIP` | `SOURCE_IP` | `balance source` |
| Health check | HTTP probe | HTTP monitor | `option httpchk` |
| Present in target environment | always | confirmed in CL110 RHOSP 16.1 | not used |
| Cost | ~17 EUR/month | quota only | quota only |

Discovery confirmed Octavia Amphora and OVN. RHOSP 16.1 OVN has no health
monitors, so the OpenStack stack creates an Amphora `SINGLE` flavor profile in
`iac/openstack/main.tf`.

---

Previous: [OpenStack networking explained](07-openstack-network.md) ·
Next: [Azure networking explained](09-azure-network.md)
