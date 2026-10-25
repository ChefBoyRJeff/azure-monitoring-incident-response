# Project 2 Plan: Azure Monitoring and Incident Response

**Status:** Plan approved 2026-10-25. Nothing has been deployed yet.

## Business Problem

An operations team needs to **detect** changes and failures automatically, **investigate** them with logs, and **prove** what happened. In this portfolio's Lab 2, an interrupted test script left a VM running, and nobody knew until someone checked by hand. This project builds the monitoring that would have caught it, then uses controlled failures to practice detecting, diagnosing, and resolving incidents.

## Scope

- **Monitored workload:** the existing Lab 2 environment in `rg-hubspoke-vms` (repo `azure-hub-spoke-network`): two Ubuntu B1s VMs, a hub and a spoke VNet, peering, and least-privilege NSGs. It is **not modified** except during controlled-failure exercises, and it's restored through its own Bicep afterward.
- **Monitoring resources:** a new resource group, `rg-monitoring-lab` (eastus).
- **Out of scope unless approved:** Azure Monitor Agent and guest OS logs, VM insights, flow logs, Application Insights, Microsoft Sentinel.

## Working Method: Portal First, Then Code

The AZ-104 exam expects portal fluency (active screen and hot area questions, and possible labs) as well as CLI and Bicep. For each **new resource type**, the first time it's used:

1. **Build it in the Azure portal**, capturing sanitized screenshots of the key settings.
2. **Write the matching Bicep** in `infra/`.
3. **Run what-if against the portal build.** The expected result is **NoChange**, apart from known noise. This proves the code matches the deployed resource.
4. **Make all later changes through code.** Investigation happens in the portal (Logs, Alerts, Activity log), the way administrators work.

## Architecture

| Component | Location | Purpose |
|---|---|---|
| Log Analytics workspace | `rg-monitoring-lab` | Central log store. 30-day retention; daily cap as a cost guardrail |
| Subscription diagnostic setting | **Subscription scope** | Sends the Activity log into the workspace so it can be queried with KQL |
| Action group | `rg-monitoring-lab` | Email notification. The address is supplied at deploy time from a `.local.bicepparam` file that is never committed |
| Alert rules | `rg-monitoring-lab`, scoped to `rg-hubspoke-vms` | Detection (Activity log and metric alerts) |
| Workbook | `rg-monitoring-lab` | Operational view of VM power events, NSG changes, and alert history |

## Milestones

| # | Milestone | Controlled failure / test | Acceptance criteria |
|---|---|---|---|
| M1 | Workspace, action group, Activity log → workspace | None | What-if reviewed; the portal build and the Bicep match; Activity log entries for `rg-hubspoke-vms` can be queried with KQL |
| M2 | Activity log alert: VM started or deallocated in `rg-hubspoke-vms` | Start a VM deliberately | Email received; **time from VM start to notification measured**; VM deallocated afterward |
| M3 | **Incident:** "SSH to the spoke stopped working" | Delete `Allow-SSH-From-Hub-Shared` in the portal (simulated human error) | An alert fires on the NSG change; KQL identifies who changed what and when; fixed by a Bicep redeploy; verified with the Lab 2 test matrix; full RCA |
| M4 | Metric alert: high CPU on `vm-spoke-lab2` | CPU load through Run Command for about 10 minutes | The alert fires and then **resolves**; both states captured |
| M5 | Workbook | None | Shows the M2–M4 incidents |
| M6 | Documentation | None | README, architecture diagram, RCAs, interview guide, teardown, limitations |
| Optional | Azure Monitor Agent + syslog from one VM | — | **Only with explicit approval** (adds billable ingestion) |

Every milestone follows the same loop: capture "before" evidence → build or change → verify → capture "after" evidence → sanitize → commit.

## Cost

| Item | Basis | Estimate |
|---|---|---|
| Activity log collection and Activity log alerts | No charge, per Microsoft Learn ("Azure Monitor cost and usage") | $0 |
| Platform metrics | No charge, per the same page | $0 |
| Log Analytics ingestion | First 5 GB per billing account per month free, with 31 days of retention included. About $2.30/GB after that (East US example) | Expected $0 |
| Activity log ingestion into the workspace | **To verify at M1** before the diagnostic setting is created | — |
| Metric alert rules | Small monthly charge per rule. **Exact price to verify at M4** before creation | Expected under $1/month |
| Action group email | Free up to 1,000 emails per month | $0 |
| VM runtime for tests | Two B1s VMs, about 5–15 minutes per milestone | Under $0.05 total |

**Target: $0–1/month.** Anything billable gets explicit approval first.

## Safety Rules

- The subscription diagnostic setting is a **subscription-wide change**. It's explained and approved separately at M1.
- Controlled failures happen only in the lab (`rg-hubspoke-vms`) and are restored through Bicep.
- VMs are **deallocated** after every test, and the power state is checked after every run (lesson from the Lab 2 incident).
- No secrets, email addresses, subscription or tenant IDs, or public IPs are committed. Evidence is sanitized before each commit.

## Teardown

1. Delete `rg-monitoring-lab`.
2. Delete the subscription diagnostic setting (subscription-wide change; approval required).
3. Lab 2 is untouched; follow its own cost and preservation policy.

## AZ-104 Coverage

From the AZ-104 study guide (skills measured as of April 17, 2026), **Monitor and maintain Azure resources → Monitor resources in Azure**:

| Objective | Milestones |
|---|---|
| Interpret metrics in Azure Monitor | M4 |
| Configure log settings in Azure Monitor | M1 |
| Query and analyze logs in Azure Monitor | M1, M3, M5 |
| Set up alert rules, action groups, and alert processing rules in Azure Monitor | M1, M2, M3, M4 (alert processing rules: consider adding, for example to suppress alerts during planned maintenance) |
| Configure and interpret monitoring of VMs, storage accounts, and networks by using Azure Monitor Insights | Optional milestone (requires approval) |
| Use Azure Network Watcher and Connection monitor | M3 verification reuses the Lab 2 IP flow verify checks |

Workbooks aren't named in the study guide. They're included because operations teams use them, and they make the incidents easy to demonstrate.
