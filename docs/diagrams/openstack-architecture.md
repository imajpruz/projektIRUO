# OpenStack architecture diagram

**Worth 3 points (I2).** Export the rendered diagram for the document.

Horizon draws an authoritative version for you as well — *Project → Network →
Network Topology*. Include both: the hand-made one shows the design, the Horizon
screenshot proves it exists.

---

## Full deployment

```mermaid
graph TB
    ADMIN["DevOps Lead workstation<br/>admin_source_ip/32"]
    EXT(["External / provider network<br/>floating IP pool"])
    STORAGE(["provider-storage<br/>native CephFS client network"])

    subgraph KS["SQL-backed Keystone domain: TechSprint"]
        subgraph MGMT["Project: proj-techsprint-test-mgmt"]
            FIP["Floating IP<br/><b>the only one in the deployment</b>"]
            SGJ["sg-techsprint-test-jump<br/>22 from workstation only"]
            RTRM["router-techsprint-test-mgmt<br/>SNAT out, DNAT for the FIP"]
            JUMP["vm-techsprint-test-jump<br/>RHEL 8, boot volume<br/>IP forwarding disabled"]
            FIP --- RTRM --- JUMP
            SGJ -.->|"attached to the port"| JUMP
        end

        subgraph P1["Project: proj-techsprint-test-marion"]
            RTR1["router-...-marion<br/>external gateway, SNAT"]
            NET1["net-...-marion<br/>subnet 10.10.1.0/24"]
            RBAC1["Neutron RBAC<br/>access_as_shared only to mgmt project"]
            JP1["management-owned jump port<br/>10.10.1.253"]
            SG1["sg-...-marion-moodle<br/>22 only from 10.10.1.253<br/>80 from subnet, 3306 intra-group"]
            LB1["Octavia Amphora SINGLE<br/>10.10.1.250<br/>SOURCE_IP + HTTP health monitor"]
            I1A["vm-...-marion-moodle-1<br/>2 vCPU / 4 GB, RHEL 8<br/>boot volume + data volume<br/>MariaDB primary"]
            I1B["vm-...-marion-moodle-2<br/>2 vCPU / 4 GB, RHEL 8<br/>boot volume + data volume"]
            SW1["Swift container<br/>rclone mount with Swift-only service identity"]
            MA1["Manila native CephFS<br/>CephX access unique to marion"]

            RTR1 --- NET1
            NET1 --- RBAC1 --- JP1
            LB1 --> I1A
            LB1 --> I1B
            I1B -.->|"3306"| I1A
            I1A -.->|"rclone"| SW1
            I1B -.->|"rclone"| SW1
            I1A -.->|"CephX"| MA1
            I1B -.->|"CephX"| MA1
            SG1 -.->|"attached to ports"| I1A
        end

        subgraph P2["Project: proj-techsprint-test-andrijam"]
            RTR2["router-...-andrijam"]
            NET2["net-...-andrijam<br/>subnet 10.11.1.0/24"]
            RBAC2["RBAC only to mgmt"]
            JP2["management-owned jump port<br/>10.11.1.253"]
            LB2["Amphora SINGLE<br/>10.11.1.250"]
            I2A["vm-...-andrijam-moodle-1"]
            I2B["vm-...-andrijam-moodle-2"]
            SW2["Swift + Manila CephFS"]
            RTR2 --- NET2
            NET2 --- RBAC2 --- JP2
            LB2 --> I2A
            LB2 --> I2B
            I2A -.-> SW2
        end
    end

    ADMIN ==>|"SSH 22, key only"| FIP
    JUMP --- JP1
    JUMP --- JP2
    JP1 ==>|"SSH 22 and private LB access"| I1A
    JP1 ==>|"SSH 22"| I1B
    JP2 ==>|"SSH 22 and private LB access"| I2A
    JP2 ==>|"SSH 22"| I2B
    RTR1 --> EXT
    RTR2 --> EXT
    RTRM --> EXT
    I1A -.-> STORAGE
    I1B -.-> STORAGE
    I2A -.-> STORAGE
    I2B -.-> STORAGE

    P1 x--x|"disjoint networks and projects:<br/>no shared RBAC grant or route"| P2
```

## Why a project per developer

Azure isolates with a resource group inside one subscription. OpenStack uses a
dedicated SQL-backed domain and a **Keystone project** per developer. Networks,
quotas, instances, volumes, Swift containers and Manila shares are created with
a token scoped to that project. A developer with no role in another project
cannot obtain a token for it.

The lead's data-plane access is separate from that identity boundary. Each
developer network grants `access_as_shared` to the management project only.
That project owns one fixed `.253` port in each network, attached to the central
jump VM. The bounded RHOSP probe proved this ownership model before it was added
to Terraform. Because IP forwarding is disabled, the jump initiates SSH and
Moodle traffic but cannot route packets between developer networks.

That is a genuinely better isolation story than the Azure side, and it is worth
saying so in the comparison section. The trade-off appears in
[openstack-iam.md](openstack-iam.md): OpenStack has no equivalent of Azure's
custom "power state only" role without a Nova policy override.

```bash
# Prove the isolation: as developer A, try to see developer B's project
export OS_USERNAME=mario.nikolis OS_PROJECT_NAME=proj-techsprint-test-andrijam
openstack server list
# You are not authorized to perform the requested action.   <- correct
```

## Layer-by-layer

| Layer | Resource | Requirement it satisfies |
|---|---|---|
| Identity | one project per developer | *"Kreirani odvojeni projekti/tenanti za izolaciju"* |
| Network | one Neutron network + subnet per project | *"Svaki programer ima svoju izoliranu virtualnu mrežu"* |
| Routing | router with external gateway, SNAT | *"VM-ovi moraju moći pristupiti Internetu"* |
| Ingress | one floating IP, on the bastion only | *"Ne smije postojati izravan javni pristup ostalim instancama"* |
| Firewall | security group per project, `remote_group_id` for intra-tier | *"Pravilno kreirane security grupe"* |
| Balancing | Octavia Amphora `SINGLE`, HTTP health monitor | *"Implementiran load balancer"* |
| Compute | 2 instances, private 2-vCPU/4096-MB flavor, RHEL 8 cloud image | hardware and OS requirements, plus HA |
| Block storage | boot volume + data volume per instance | *"dva diska (OS disk i data disk)"* |
| Object storage | Swift container | *"servisa za objektnu pohranu"* |
| File storage | Manila native CephFS with CephX access | *"servisa za datotečnu pohranu"* |

## The floating-IP DNAT detail

A floating IP is **not** configured on the instance. The router does DNAT, so
`ip addr` inside the bastion shows only `10.100.0.x`, forever. Every student
trips over this once; explaining it correctly shows you understand Neutron
rather than having copied commands.

```bash
openstack floating ip list -f table
# +---------------------+------------------+
# | Floating IP Address | Fixed IP Address |
# +---------------------+------------------+
# | 172.25.250.108      | 10.100.0.12      |
# +---------------------+------------------+

ssh cloud-user@172.25.250.108 'ip -4 addr show | grep inet'
#     inet 10.100.0.12/24 ...      <- the floating IP is nowhere on the guest
```

## MTU, if you hit it

Lab tenant networks usually run over VXLAN or GENEVE, so the MTU is 1442 or
1450 rather than 1500. Symptom: SSH connects then hangs, `curl` returns headers
and stalls, `ping` is fine. Check yours and mention it if it affected you:

```bash
openstack network show net-techsprint-test-marion -f value -c mtu
```

## Lab capabilities established before implementation

Read-only discovery and a bounded create/delete probe established that this
RHOSP 16.1 lab provides Swift, native CephFS Manila and Octavia. OVN consumes no
VM but this RHOSP version lacks health monitors. The implementation therefore
uses an Amphora `SINGLE` flavor profile: one 1-GB amphora per developer load
balancer, with the HTTP monitor required for a meaningful failover demo.

The same probe proved the SQL identity domain, exact private application flavor,
CephFS share-type metadata, project-specific network RBAC and management-owned
cross-project ports. Workload behavior remains explicitly unverified until the
runtime smoke test.
