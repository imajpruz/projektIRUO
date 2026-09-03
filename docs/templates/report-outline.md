# Report outline

> *"Za dokumentiranje projekta koristite standardni template. U dokumentu
> objasnite plan i arhitekturu koju ste zamislili, način i kod za deployment te
> samu implementaciju."*

Use the faculty's standard template for formatting — points are deducted for
formatting and grammar. This is the *content* skeleton: what goes in each
section and which rubric line it collects.

Suggested length 25–35 pages including figures. Sections 4, 5, 7 and 9 carry the
most marks per page.

---

## Title page
Project title, course, your name and student number, date, institution.

## Contents, list of figures, list of tables
Auto-generated. Every figure numbered and referenced from the body text.

## 1. Introduction (1–2 pages)

- **1.1 The scenario.** TechSprint needs automated, isolated test environments
  for Moodle, and cannot decide between Azure and OpenStack.
- **1.2 Objectives.** Restate the brief's requirements as a numbered list — this
  list becomes the traceability table in §2.
- **1.3 Scope and constraints.** Azure for Students (100 EUR / 12 months); the
  Red Hat Academy OpenStack lab and what it does and does not offer. These
  constraints justify design choices later, so state them up front.
- **1.4 Deliverables.** This document, the git repository, the private video.

## 2. Requirements analysis (2 pages) — *collects nothing directly, enables everything*

Table of every requirement from the brief against how it is met and where it is
evidenced. Source: [../rubric-traceability.md](../rubric-traceability.md).

| # | Requirement | Implementation | Evidence |
|---|---|---|---|

Then call out the requirements that **conflict**, because resolving them is the
design:

- The lead must reach every VM; developers must reach none but their own.
- Nothing may be publicly accessible except the jump host, yet Moodle must be
  usable.
- Two Moodle instances for HA, but a managed database costs a quarter of the
  grant per developer.

## 3. Architecture (4–5 pages) — **I2 3pts, I4 3pts, I3 3pts, I5 3pts = 12**

- **3.1 Overview.** One paragraph and one diagram: same architecture, two
  providers, one CSV.
- **3.2 Azure architecture.** → *Figure 1*, from
  [../diagrams/azure-architecture.md](../diagrams/azure-architecture.md).
  Hub-and-spoke, and why peering's non-transitivity is what satisfies isolation.
- **3.3 OpenStack architecture.** → *Figure 2*, from
  [../diagrams/openstack-architecture.md](../diagrams/openstack-architecture.md).
  Keystone project per developer; note it is a stronger boundary than a resource
  group.
- **3.4 Azure RBAC model.** → *Figure 3*, from
  [../diagrams/azure-rbac.md](../diagrams/azure-rbac.md).
- **3.5 OpenStack IAM structure.** → *Figure 4*, from
  [../diagrams/openstack-iam.md](../diagrams/openstack-iam.md).
- **3.6 Address plan.** The table showing disjoint ranges, and that the parser
  assigns them so overlap is impossible by construction.
- **3.7 Naming convention.** From [../architecture.md](../architecture.md#naming-convention-and-tagging)
  — 4 points. Include the storage-account exception and why it governs the whole
  scheme.
- **3.8 Tagging.** `project: techsprint`, `environment: testing` — 2 points. Show
  the verification query output.

## 4. Element selection and justification (3–4 pages) — **I1 7pts + 2pts**

The largest single scored item. Source:
[../architecture.md](../architecture.md#design-decisions).

- **4.1 Load balancer.** Standard LB vs Application Gateway, with the cost table.
  Why internal rather than public. Why an HTTP probe rather than TCP. Why
  source-IP affinity, and its limitation.
- **4.2 Object storage vs file storage.** Why both, why not one for everything,
  what each is used for. The least-privilege implementation: managed identity
  scoped to one container, and the honest SMB key exception.
- **4.3 VM type.** B2s vs D2s_v3, burst credits and what happens when they run
  out.
- **4.4 Disk type.** Standard SSD vs Premium vs HDD; why a separate data disk;
  UUID and `nofail`.
- **4.5 Decision summary table.**

## 5. Provider comparison (2–3 pages) — **I1 4pts**

Source: [../cloud-comparison.md](../cloud-comparison.md).

- **5.1 Element-by-element table.**
- **5.2 The differences that shaped this project.** Keystone projects beat
  resource groups for isolation; Azure RBAC beats Keystone roles for least
  privilege. Both directions, honestly.
- **5.3 Managed service availability**, including the Octavia and Manila
  substitutions.
- **5.4 Recommendation for TechSprint**, and when it would flip.

## 6. Deployment method and code (3–4 pages) — **I2 7pts + I4 7pts**

The brief asks explicitly for *"način i kod za deployment"*. Source:
[../architecture.md](../architecture.md#how-the-deployment-works).

- **6.1 The pipeline.** → *Figure 5*: CSV → parser → Terraform → inventory →
  Ansible → verify.
- **6.2 The CSV contract.** Validation, diacritic folding, collision detection,
  address assignment. Include the `Đurđa Šarić → durdas` example — it shows you
  thought about real input.
- **6.3 Why a map, not a list.** `for_each` keyed by slug means adding a user
  cannot destroy another's environment. Show `0 to change, 0 to destroy`.
- **6.4 Terraform structure.** Root module plus a reusable per-developer module,
  instantiated once per CSV row.
- **6.5 Terraform → Ansible handover.** The generated inventory and the bastion
  ProxyCommand, which is what lets Ansible configure hosts with no public
  address.
- **6.6 Ansible roles.** One paragraph each. Highlight: Azure LUN/OpenStack
  non-root disk selection, install-once shared config, and SELinux and
  firewalld on Rocky.
- **6.7 Code listings.** Selected excerpts, not everything — the custom role
  definition, controlled NVA forwarding, OpenStack project-scoped staging, the
  Neutron RBAC grant, and one storage-mount task. Reference the repository for
  the rest.

## 7. IAM implementation (2–3 pages) — **I3 7pts+ , I5 7pts+**

- **7.1 Identities and scoped roles from the CSV**, with OpenStack groups.
- **7.2 The Azure custom role.** Its narrow power/read actions, and why
  `Virtual Machine Contributor` was rejected. Include the JSON.
- **7.3 Scoping.** Why one resource group per developer *is* the permission
  boundary; why the lead receives the role on each TechSprint resource group
  rather than at broad subscription scope; and why OpenStack also needs one
  assignment per project.
- **7.4 The OpenStack asymmetry.** No power-state-only role without a Nova
  policy override; the project boundary carries the requirement instead. State
  the limitation and the fix — this is analysis, and it scores.
- **7.5 Control plane vs data plane.** The human controls the machine; the
  machine's managed identity reads the data. Neither can do the other's job.

## 8. Implementation walkthrough (2–3 pages)

- **8.1 A deployment run**, with the real timings.
- **8.2 What one apply creates** — the resource count table.
- **8.3 Adding a fourth developer**, with the plan output.
- **8.4 Problems encountered and how they were diagnosed.** Do not omit this.
  Candidates: marketplace terms, Entra ID permissions, regional vCPU quota, the
  missing Octavia, SELinux blocking Apache, MTU on the tenant network. A
  documented failure with a root cause reads far better than a suspiciously
  clean run.

## 9. Testing and verification (2–3 pages)

Source: [../testing-and-evidence.md](../testing-and-evidence.md).

- **9.1 Verification output**, both clouds, with the rubric labels visible.
- **9.2 Requirement-by-requirement evidence table.**
- **9.3 Negative tests.** Isolation, RBAC denial, narrow storage credentials.
  Explain that a deny test proves the control is what is doing the work, and the
  timeout-versus-refused distinction.
- **9.4 Load balancer failover demonstration.**
- **9.5 Variable user count demonstration.**

## 10. Cost analysis (2 pages) — **I1 3pts**

Source: [../cost-estimate.md](../cost-estimate.md).

- **10.1 Per-developer breakdown**, from your own subscription's meters.
- **10.2 Full deployment monthly cost**, and the finding that it exceeds the
  student grant by ~2.5× per month.
- **10.3 Cost controls**, and the build-demo-destroy cycle at ~2 EUR.
- **10.4 What the OpenStack side would cost.** Quota consumed, notional
  equivalent, and the operational cost you absorbed.
- **10.5 CapEx vs OpEx** and where the break-even sits.

## 11. Limitations and future work (1–2 pages)

Source: [../cloud-comparison.md](../cloud-comparison.md#known-limitations). The summary
table plus a paragraph on the three that matter most: the single-point-of-failure
database, session affinity instead of a shared store, and HTTP rather than HTTPS.

## 12. Conclusion (1 page)

What was built, whether the objectives in §1.2 were met, the provider
recommendation, and the single most useful thing you learned. Avoid restating the
whole document.

## References

Azure documentation, OpenStack documentation, Moodle installation guide,
Terraform provider docs, course materials. Cite the pages you actually used.

## Appendices

- **A.** Repository link and layout.
- **B.** Private YouTube video link.
- **C.** Full `deploy.sh --help` and a complete run transcript.
- **D.** `verify.sh` output for both clouds.
- **E.** Complete Terraform and Ansible listings, or a repository reference.
- **F.** Figures at full size.

---

## Figure list

Keep this updated as you go.

| # | File | Caption | Section |
|---|---|---|---|
| 1 | `fig-01-azure-architecture.png` | Azure hub-and-spoke architecture | 3.2 |
| 2 | `fig-02-openstack-architecture.png` | OpenStack per-project architecture | 3.3 |
| 3 | `fig-03-azure-rbac.png` | Azure RBAC model | 3.4 |
| 4 | `fig-04-openstack-iam.png` | OpenStack IAM structure | 3.5 |
| 5 | `fig-05-pipeline.png` | Deployment pipeline | 6.1 |
| 6 | `fig-06-resource-tags.png` | Tagged resources | 3.8 |
| 7 | `fig-07-nsg-rules.png` | NSG rules on a developer subnet | 3.2 |
| 8 | `fig-08-custom-role.png` | Custom role definition JSON | 7.2 |
| 9 | `fig-09-authorization-failed.png` | Developer denied on another's VM | 9.3 |
| 10 | `fig-10-keystone-denied.png` | Keystone refusing a cross-project token | 9.3 |
| 11 | `fig-11-moodle-front.png` | Moodle via the bastion tunnel | 8.1 |
| 12 | `fig-12-lb-failover.png` | Backend header changing after a node stops | 9.4 |
| 13 | `fig-13-disks-mounted.png` | `lsblk`, `findmnt`, `/etc/fstab` | 9.2 |
| 14 | `fig-14-storage-mounts.png` | Both storage services mounted | 9.2 |
| 15 | `fig-15-verify-output.png` | Verification, both clouds | 9.1 |
| 16 | `fig-16-cost-analysis.png` | Actual spend | 10.1 |
| 17 | `fig-17-plan-no-changes.png` | `0 to change, 0 to destroy` | 9.5 |

## Final checks

- [ ] All 17 requirements from §2 traceable to a section
- [ ] All four required diagrams present, numbered, referenced in the text
- [ ] Cost figures from your own subscription, not a calculator
- [ ] Every figure referenced from the body text
- [ ] **No secrets**: no passwords, storage keys, subscription ids or home IP
- [ ] Spell-checked in the document's language
- [ ] Faculty template formatting applied
- [ ] Video uploaded, visibility set, link included and verified
- [ ] Git repository access granted to the assessor
- [ ] Exam term registered on Infoeduka
