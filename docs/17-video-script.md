# Demo video script

> *"Uz klasičnu dokumentaciju u obliku dokumenta, kako bi ostvarili bodove morate
> snimiti izvršavanje skripte za deployment i objasniti što ona radi. Video
> prenesite na YouTube kao privatni video."*

Two requirements: **record the script running**, and **explain what it does**.
A silent screen recording of a terminal does not meet the second.

Target 12–15 minutes. Upload as **Private** (not Unlisted) and put the link in
the document.

---

## Before you record

```bash
# 1. Everything is clean
make lint

# 2. Start from nothing, so the run is genuine
./deploy.sh --csv examples/users.csv --cloud both --destroy --yes

# 3. Rehearse once, timed. Apply takes 8-15 minutes; you will cut that.
```

Practical setup:

- Terminal font at 16pt or larger. Anything smaller is unreadable after YouTube
  compression.
- Light-on-dark, high contrast.
- **Close anything showing a real password, subscription id or your home IP.**
- `--yes` so you are not waiting on prompts on camera.
- Have `docs/diagrams/` open in a browser tab for the architecture segment.
- Record the long apply, then cut it in editing with a caption saying how long it
  actually took. Do not fake the run.

## Structure

### 0:00–1:30 — What and why

Screen: the architecture diagram.

> "This is the TechSprint project. The task is an automated way to give each
> developer an isolated environment for testing Moodle, on Azure and on
> OpenStack, so the company can compare the two providers.
>
> The requirements that shaped the design: every developer gets their own
> network and cannot reach anyone else's; the only public entry point is a jump
> host; each application VM has two vCPU, four gigabytes and two disks; two
> Moodle instances behind a load balancer for high availability; object storage
> and file storage per developer, both mounted automatically; and the whole
> thing driven from a CSV by a single script.
>
> I'll show the code first, then run it end to end."

### 1:30–3:30 — The CSV and the parser

Screen: `examples/users.csv`, then run the parser.

> "The input is the CSV format the brief specifies: first name, surname, role."

```bash
cat examples/users.csv
python3 lib/parse_users.py examples/users.csv --summary
```

> "The parser does four jobs. It validates — unknown roles, a missing lead, no
> developers are all rejected before anything is created. It slugifies names,
> folding Croatian diacritics to ASCII, because Azure resource names reject them:
> watch what happens with Đurđa Šarić."

```bash
printf 'ime;prezime;rola\nĐurđa;Šarić;developer\nIvan;Ivić;developer\nAna;Anić;devops_lead\n' > /tmp/dia.csv
python3 lib/parse_users.py /tmp/dia.csv --summary
```

> "It detects collisions — two people who would produce the same resource name
> are rejected rather than failing halfway through a deployment. And it assigns
> each developer a disjoint slash-sixteen, so overlapping address space is
> impossible by construction, not by review. Overlap is the cheapest way to
> break the isolation requirement.
>
> The output is a map keyed by slug, not a list, and that matters: Terraform's
> for_each over a map keys state by the slug. For the scaling demo I append the
> new CSV row, preserving both those addresses and the existing placement slots."

### 3:30–6:00 — The infrastructure code

Screen: `iac/azure/main.tf`, then the developer module, then the custom role.

> "Azure is hub and spoke. The hub holds the jump host and the only public IP.
> Each developer gets a resource group, a VNet peered to the hub — and to
> nothing else."

Show the peering block, and point at `allow_forwarded_traffic = true`.

> "Forwarding is enabled only because the jump VM also provides controlled
> outbound NAT. Cross-spoke traffic is still denied by the route design, both
> spoke NSGs, the hub NSG and the jump host's nftables forward policy."

Show the custom role definition.

> "This is the permission model. The brief says developers may start, stop and
> restart only their own VMs. The built-in Virtual Machine Contributor role is
> far too wide — it can delete VMs and resize them. So this is a custom role with
> the required power actions plus read-only portal visibility and no data
> actions, assigned at the developer's own resource group. The lead gets the
> same role on each TechSprint group, without access to unrelated subscription
> resources."

Then briefly: `iac/openstack/main.tf`.

> "OpenStack does the same thing with a different primitive: a Keystone project
> per developer. That is actually a stronger boundary — a user with no role in a
> project cannot even get a token for it. The trade-off is that OpenStack has no
> equivalent of that narrow custom role without changing Nova's policy on the
> controllers, which a tenant on the academy lab cannot do. I cover that
> asymmetry in the document."

### 6:00–7:00 — The one script

Screen: `deploy.sh --help`, then the pipeline diagram.

> "The brief requires one script, run once. This is it. It parses the CSV,
> applies Terraform, generates the Ansible inventory from the Terraform outputs,
> runs Ansible, and verifies. Nothing between those stages is typed by hand —
> which is the point, because the Moodle nodes have no public address, so the
> inventory has to carry the ProxyCommand through the bastion."

### 7:00–11:00 — Run it

```bash
./deploy.sh --csv examples/users.csv --cloud both --yes
```

Narrate over each step, cutting the long apply:

> "Preflight first — tooling and credentials checked before anything is created.
> Then the CSV.
>
> Azure prints its exact resource count and applies the reviewed plan. OpenStack
> then applies a system-scoped identity bootstrap, one project-scoped workspace
> per developer, and finally the management project. State the actual final
> counts shown on screen; the historical 118-resource Azure plan predates the
> split Blob/Files accounts.
>
> [cut] That took eleven minutes.
>
> Now the inventory is generated from the outputs — this is where the bastion
> ProxyCommand comes from — and Ansible takes over: Azure uses LUN 10 while
> OpenStack requires one non-root data disk; it is mounted by UUID with nofail,
> both storage services are mounted,
> and Moodle is installed. Node one runs the installer because it writes the
> database schema; node two pulls the resulting config.php, so both nodes serve
> the same site rather than two unrelated ones.
>
> Then verification."

### 11:00–13:00 — Prove it works

**Moodle in a browser:**

```bash
ssh -D 1080 -i build/ssh/id_ed25519 techsprint@<bastion>
```

> "No Moodle VM has a public address, so I reach it through a tunnel via the
> bastion. My browser uses the local SOCKS5 proxy and opens the private load
> balancer address, which is also Moodle's canonical URL. There is Moodle, and
> the site name shows which developer's environment it is."

**Load balancer failover** — the strongest 60 seconds in the video:

```bash
while true; do curl -sI http://10.10.1.250/ | grep -i x-techsprint-node; sleep 2; done
# other terminal:
ssh marion-moodle-1 'sudo systemctl stop httpd'
```

> "Every response is now coming from node two. The health endpoint returns 503
> when Moodle config, its database or any required mount is unavailable, so a
> listening but unusable node is removed from the pool."

**Isolation:**

```bash
ssh marion-moodle-1 'ping -c 3 -W 3 10.11.1.4'
```

> "Mario's node cannot reach Andrija's. And Azure will tell us which rule decided."

```bash
az network watcher test-ip-flow -g rg-techsprint-test-marion \
  --vm vm-techsprint-test-marion-moodle-1 --direction Inbound --protocol TCP \
  --local 10.10.1.4:22 --remote 10.11.1.4:33000
```

**RBAC:**

```bash
read -s AZURE_CLIENT_SECRET
az login --service-principal --username <marion-client-id> \
  --password "$AZURE_CLIENT_SECRET" --tenant <tenant-id>
unset AZURE_CLIENT_SECRET
az vm restart -g rg-techsprint-test-marion -n vm-techsprint-test-marion-moodle-1   # works
az vm delete  -g rg-techsprint-test-marion -n vm-techsprint-test-marion-moodle-1 --yes  # AuthorizationFailed
az vm restart -g rg-techsprint-test-andrijam -n vm-techsprint-test-andrijam-moodle-1      # AuthorizationFailed
```

> "Mario can restart his own VM, cannot delete it, and cannot touch Andrija's. An
> allow test proves a rule exists; a deny test proves the rule is doing the
> work."

### 13:00–14:30 — Variable user count

The strongest argument for the design:

```bash
echo 'ivan;ivic;developer' >> examples/users.csv
./deploy.sh --csv examples/users.csv --cloud azure --plan-only
```

> "The appended slug creates a new Keystone project and project-scoped
> workspace while existing workspaces remain unchanged. The Azure student
> subscription requires a separately discovered region/SKU placement before a
> third developer can be claimed there."

### 14:30–15:00 — Close

> "Both clouds run from the same CSV. The document covers the cost estimate —
> calculated from the exact deployed regions, SKUs and current Azure meters —
> so I build, demo and destroy in one controlled session. It also covers the
> provider comparison and the limitations:
> the database is a single point of failure, sessions use source-IP affinity
> rather than a shared store, and traffic inside the VNet is HTTP. Each of those
> has a documented fix and a price.
>
> Thanks for watching."

## Upload

1. YouTube → Upload → set visibility to **Private**.
2. Title: `TechSprint - Implementacija računarstva u oblaku - <your name>`.
3. Description: repository link, the four diagram references, and a timestamped
   chapter list — chapters make it far easier to mark.
4. Put the link in the Word document **and** check it opens in a private window
   while signed in as the account you shared it with.

> Private on YouTube means only accounts you explicitly share with can view.
> Obtain the assessor's address and verify access while signed in as that
> account; the assignment explicitly requires Private visibility.

## Checklist

- [ ] Script runs start to finish, and the run is real
- [ ] You explain *why*, not just narrate *what*
- [ ] Moodle shown in a browser
- [ ] Load balancer failover demonstrated
- [ ] Isolation negative test shown
- [ ] RBAC `AuthorizationFailed` shown
- [ ] Adding a user shows `0 to change, 0 to destroy`
- [ ] No password, subscription id or home IP visible on screen
- [ ] Cuts are captioned with the real elapsed time
- [ ] Uploaded, visibility set, link verified from another account

---

Previous: [Troubleshooting](16-troubleshooting.md) ·
Back to the [README](../README.md)
