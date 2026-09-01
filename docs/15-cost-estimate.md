# Azure monthly cost estimate

**Worth 3 points (I1)** — *"Procjena troškova u Azure-u na mjesečnoj bazi"*.

## Status

The topology below matches the current Terraform. Prices must be filled from
the Azure Retail Prices API after the fresh plan confirms the exact SKUs.
Do not reuse the older West Europe/NAT Gateway figures.

Assumptions:

- 730 hours per month;
- pay-as-you-go Linux pricing in EUR;
- Denmark East for Mario and the jump host;
- Austria East for Andrija;
- two developers, two Moodle nodes each;
- low test traffic and LRS storage;
- no NAT Gateway: the jump VM provides outbound NAT.

## Current billable topology

| Resource | Region | Quantity | Pricing unit |
|---|---|---:|---|
| `Standard_B2s` Moodle VM | Denmark East | 2 | hour |
| `Standard_D2ls_v6` Moodle VM | Austria East | 2 | hour |
| `Standard_A1_v2` jump VM | Denmark East | 1 | hour |
| Standard SSD E6 OS disk (64 GiB) | regional | 4 | month |
| Standard SSD E4 data/jump disk (32 GiB) | regional | 5 | month |
| Standard internal Load Balancer | both developer regions | 2 | hour + processed data |
| Standard static public IP | Denmark East | 1 | hour |
| Blob StorageV2 account | each developer region | 2 | stored GiB + operations |
| Files StorageV2 account | each developer region | 2 | stored GiB + operations |
| Blob capacity | LRS, approximately 2 GiB/developer | 4 GiB | GiB-month |
| Azure Files capacity | LRS, approximately 5 GiB/developer | 10 GiB | GiB-month |
| Global VNet peering | hub ↔ two spokes | measured traffic | GiB each direction |

There are no charges for resource groups, VNets, subnets, NSGs, ASGs, route
tables, managed identities, service principals or role assignments.

## Calculation worksheet

Fill the unit prices from the API results:

| Component | Formula | Monthly EUR |
|---|---|---:|
| Mario compute | `2 × B2s_hourly × 730` | TBD |
| Andrija compute | `2 × D2ls_v6_hourly × 730` | TBD |
| Jump compute | `A1_v2_hourly × 730` | TBD |
| Managed disks | `4 × E6_monthly + 5 × E4_monthly` | TBD |
| Load balancers | `2 × LB_hourly × 730 + data` | TBD |
| Public IP | `PIP_hourly × 730` | TBD |
| Blob + Files | capacity + operations | TBD |
| VNet peering | ingress GiB + egress GiB | TBD |
| **Total** | sum of the rows above | **TBD** |

The report-ready table must include the query date, currency, returned meter
name and whether tax/student credits are excluded.

## Retrieve current prices

The retail endpoint needs no Azure authentication:

```bash
python3 - <<'PY'
import json
import urllib.parse
import urllib.request

queries = [
    ("B2s", "Virtual Machines", "denmarkeast", "Standard_B2s"),
    ("D2ls_v6", "Virtual Machines", "austriaeast", "Standard_D2ls_v6"),
    ("A1_v2", "Virtual Machines", "denmarkeast", "Standard_A1_v2"),
]

for label, service, region, sku in queries:
    expression = (
        f"serviceName eq '{service}' and armRegionName eq '{region}' "
        f"and armSkuName eq '{sku}' and priceType eq 'Consumption'"
    )
    url = (
        "https://prices.azure.com/api/retail/prices?currencyCode=EUR&$filter="
        + urllib.parse.quote(expression, safe="'()")
    )
    items = json.load(urllib.request.urlopen(url))["Items"]
    linux = [
        item for item in items
        if "Windows" not in item.get("productName", "")
        and "Spot" not in item.get("skuName", "")
        and "Low Priority" not in item.get("skuName", "")
    ]
    print(label, linux)
PY
```

If a configured SKU returns no public retail item, verify it with
`az vm list-skus` and use the Azure Pricing Calculator for that exact region.
Do not silently substitute another region.

After the live demonstration, compare the estimate with actual tagged usage:

```bash
az consumption usage list \
  --start-date "$(date -u -d '2 days ago' +%Y-%m-%d)" \
  --end-date "$(date -u +%Y-%m-%d)" \
  --query "[?tags.project=='techsprint'].{resource:instanceName,cost:pretaxCost,currency:currency}" \
  -o table
```

## Cost control

Build, capture evidence and destroy on the same day:

```bash
./deploy.sh --csv examples/users.csv --cloud azure --yes
./lib/verify.sh --cloud azure | tee evidence/verification.txt
./deploy.sh --csv examples/users.csv --cloud azure --destroy --yes
```

Deallocating VMs stops compute charges but leaves disks, load balancers, storage
and the public IP billable. `az vm stop` is not sufficient; use deallocate.

## OpenStack comparison

The Academy lab exposes quota rather than prices. Per developer the current
design consumes two 2-vCPU/4-GB instances, two boot volumes, two data volumes,
one Swift container, one Manila share and one single Amphora load balancer.
The shared management project adds one jump instance, one boot volume and one
floating IP. This is not free: hardware, power and operator time are simply
outside the tenant billing API.

---

Previous: [Testing and evidence](14-testing-and-evidence.md) ·
Next: [Troubleshooting](16-troubleshooting.md)
