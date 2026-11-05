# Azure Monitoring and Incident Response

Azure Monitor lab: Log Analytics, KQL, Activity log and metric alerts, action groups, and a workbook. Each resource is built in the portal first, then codified in Bicep and verified with what-if. Controlled failures are documented with root-cause analysis and evidence. Built as a hands-on project while studying for **AZ-104: Microsoft Azure Administrator**. This is lab work in a personal subscription, not a production environment.

> **Status:** M1–M6 complete. Every result below comes from a live deployment, with sanitized evidence in [`docs/evidence/`](docs/evidence/). Root-cause reports: [RCA-001](docs/rca/rca-001-nsg-rule-deleted-ssh-outage.md) (NSG incident), [RCA-002](docs/rca/rca-002-cpu-metric-alert.md) (metric alert test). Interview notes: [`docs/interview-guide.md`](docs/interview-guide.md).

> **Update (2026-11-05): Lab 4, Network Watcher.** VNet flow logs with Traffic Analytics, a connection monitor with an alert, a controlled NSG failure ([RCA-003](docs/rca/rca-003-nsg-port-typo-web-outage.md)) and packet capture, on the Project 1 network. Built in the portal, codified in [`infra/lab4/netwatch.bicep`](infra/lab4/netwatch.bicep) (what-if NoChange), then **torn down the same day**. See [Lab 4](#lab-4-network-watcher).

> **Update (2026-11-01):** the monitored workload (hub-and-spoke Lab 2, `rg-hubspoke-vms`) was torn down. The four alert rules targeting it couldn't be disabled (an update re-validates the rule against its now-deleted scope) and were **deleted** instead ([evidence](docs/evidence/alerts-disabled-2026-11-01.txt)). The workspace, action group, workbook, and subscription diagnostic setting are still deployed, at $0. To run the lab again, rebuild Lab 2 from its Bicep, then redeploy `infra/main.bicep` to recreate the alerts.

## Problem It Solves

Operations teams need to **detect** changes and failures automatically, **investigate** them with logs, and **prove** what happened. In this portfolio's [hub-and-spoke Lab 2](https://github.com/ChefBoyRJeff/azure-hub-spoke-network#lab-2-portal-built-connectivity-validation), an interrupted test script left a VM running, and nobody knew until someone checked by hand. This project builds the monitoring that would have caught it, then breaks the lab on purpose to test it.

**Most important result:** the alert built to catch a deleted NSG rule **didn't fire** when the rule was deleted in the portal. The investigation found why, fixed the rule in code, and proved the fix with a live event ([RCA-001](docs/rca/rca-001-nsg-rule-deleted-ssh-outage.md)).

## Milestones

| # | Milestone | Status | Result |
|---|---|---|---|
| M1 | Log Analytics workspace, action group, Activity log → workspace | ✅ | Activity log queryable with KQL at $0 (`_IsBillable = false`) |
| M2 | Activity log alerts: VM started / deallocated | ✅ | Both fired; detection 7–8 min |
| M3 | Incident: "SSH to the spoke stopped working" (NSG rule deleted in the portal) | ✅ | **Alert missed it.** Root cause found, condition fixed, fix proven; restored through Bicep; Lab 2 test matrix passed |
| M4 | Metric alert: high CPU, fired and resolved | ✅ | Fired 7.3 min after load started; resolved about 8 min after it ended; one instance stranded |
| M5 | Workbook: alert history, VM power, NSG changes (manual vs. code), CPU | ✅ | Portal-built, then codified with a tokenized template |
| M6 | RCAs, README, interview guide, teardown | ✅ | This document |
| Lab 4 | Network Watcher: VNet flow logs + Traffic Analytics, connection monitor + alert, NSG incident, packet capture | ✅ | Alert fired **2.9 min** after the break; outage 7.2 min; packet capture failure traced to a blackhole route and fixed through code. Torn down |

## Architecture

```mermaid
flowchart LR
  subgraph SUB["Subscription"]
    AL["Activity log<br/>(every create, update, delete, start, stop)"]
    DS["Diagnostic setting<br/>diag-activitylog-to-law<br/>(8 categories)"]
    subgraph LAB["rg-hubspoke-vms (Lab 2 workload)"]
      VMS["vm-hub-lab2, vm-spoke-lab2"]
      NSG["nsg-hub-lab2, nsg-spoke-lab2"]
    end
    subgraph MON["rg-monitoring-lab"]
      LAW["Log Analytics workspace<br/>law-monitoring-lab<br/>30 days, daily cap 0.1 GB"]
      AR["Activity log alerts<br/>alert-vm-started<br/>alert-vm-deallocated<br/>alert-nsg-rule-deleted"]
      MA["Metric alert<br/>alert-vm-spoke-cpu-high<br/>(Sev 2, auto-resolve)"]
      WB["Workbook<br/>Lab Operations"]
      AG["Action group<br/>ag-lab-ops (email)"]
    end
    MET["Platform metrics<br/>(Percentage CPU)"]
  end
  VMS & NSG -- "control-plane events" --> AL
  VMS -- "no agent needed" --> MET
  AL --> DS --> LAW
  AL -- "evaluated directly" --> AR
  MET --> MA
  AR & MA --> AG --> EMAIL["Email"]
  LAW -- "KQL" --> WB
  MET --> WB
```

- **Activity log alerts** evaluate the Activity log **directly**. They don't depend on the workspace, so they kept working while workspace delivery was delayed (troubleshooting case 2). They're **stateless**: one alert per event, never "resolved".
- **The metric alert** evaluates platform metrics. It's **stateful**: it fires, then resolves on its own (`autoMitigate`).
- **The workspace** is for investigation (KQL), not detection. Only the free `AzureActivity` table is ingested.

## What's Deployed

| Resource | Name | Key settings |
|---|---|---|
| Resource group | `rg-monitoring-lab` | eastus; standard tags |
| Log Analytics workspace | `law-monitoring-lab` | Pay-as-you-go (PerGB2018); 30-day retention; **daily cap 0.1 GB**; resource-context access mode |
| Action group | `ag-lab-ops` | Short name `lab-ops`; one email receiver; region Global |
| Subscription diagnostic setting | `diag-activitylog-to-law` | All 8 Activity log categories → `law-monitoring-lab` |
| Activity log alert *(deleted 2026-11-01)* | `alert-vm-started` | Scope `rg-hubspoke-vms`; `Microsoft.Compute/virtualMachines/start/action`; Succeeded |
| Activity log alert *(deleted 2026-11-01)* | `alert-vm-deallocated` | Scope `rg-hubspoke-vms`; `.../virtualMachines/deallocate/action`; Succeeded |
| Activity log alert *(deleted 2026-11-01)* | `alert-nsg-rule-deleted` | Scope `rg-hubspoke-vms`; **any of** `.../securityRules/delete` or `.../networkSecurityGroups/write`; Succeeded. **Code-only** (the wizard can't build `anyOf`) |
| Metric alert *(deleted 2026-11-01)* | `alert-vm-spoke-cpu-high` | `vm-spoke-lab2`; Percentage CPU, Average > 80; window 5 min, frequency 1 min; Sev 2; auto-resolve. **About USD 0.10/month** |
| Workbook | Lab Operations - Incidents and Changes | Alert history (Resource Graph), VM power events (KQL), NSG changes manual vs. code (KQL), CPU (metrics) |

All of it is declared in [`infra/main.bicep`](infra/main.bicep) and [`infra/modules/monitoring.bicep`](infra/modules/monitoring.bicep).

## How It Was Built: Portal First, Then Code

The AZ-104 exam expects portal fluency as well as CLI and Bicep, so each resource type was built **in the portal first**, then codified:

1. Build it in the Azure portal and capture screenshots of the successful result.
2. Export what Azure actually stored (`az ... show -o json`, kept in the gitignored `infra/export/`). The portal adds defaults and renames things. For example, it stored the email receiver as `email-ops_-EmailAction-`.
3. Write Bicep that matches the stored state.
4. Run **what-if against the portal build**. The goal is **NoChange**, apart from known what-if blind spots.
5. From then on, change everything **through code**, and investigate in the portal.

| Milestone | What-if vs. portal build | Evidence |
|---|---|---|
| M1 | RG, workspace, diagnostic setting: **NoChange** (plus an intended removal of two test tags) | `m1-07` |
| M2 | Both VM alert rules: **NoChange** first time | `m2-04` |
| M3/M4 | NSG alert: **NoChange**. Metric alert: a false change from `reference()`, fixed in code, then **NoChange** | `m3m4-01`, `m3m4-02` |
| M5 | Workbook: only `serializedData` reported, a known blind spot (see case 12) | `m5-03` |

The action group always shows `emailAddress → [parameters('alertEmail')]`. That's expected, because what-if can't evaluate `@secure()` values (case 4).

## Results

### M1: Activity Log in Log Analytics

| Measure | Result |
|---|---|
| `_IsBillable` | **False** for every row (294 rows by end of M5, `m5-01`). `AzureActivity` ingestion is free |
| Latency once data was flowing | Average **4.6 min**, maximum **8 min** |

![KQL ingestion latency](docs/screenshots/m1-06-kql-ingestion-latency.png)

### M2: VM Power Alerts

Start `vm-spoke-lab2`, then deallocate it immediately (`m2-02`). Both alerts fired, and emails arrived at fire time. Both were then **closed** through the alert lifecycle with a comment.

![Fired alerts](docs/screenshots/m2-02-fired-alerts.png)

### Activity Log Alert Detection Time (All Tests)

Event time from the Activity log vs. fire time from the Alerts Management API (`m2-03`, `m5-01`):

| Alert | Target | Event (UTC) | Fired (UTC) | Detection |
|---|---|---|---|---|
| `alert-vm-started` | vm-spoke-lab2 | 18:41:33 | 18:49:29 | 7.9 min |
| `alert-vm-deallocated` | vm-spoke-lab2 | 18:42:15 | 18:49:29 | 7.2 min |
| `alert-vm-started` | vm-hub-lab2 | 22:25:28 | 22:29:28 | 4.0 min |
| `alert-vm-started` | vm-spoke-lab2 | 22:26:38 | 22:29:28 | 2.8 min |
| `alert-nsg-rule-deleted` | nsg-spoke-lab2 | 22:38:37 | 22:39:28 | 0.8 min |
| `alert-nsg-rule-deleted` | nsg-hub-lab2 | 22:38:36 | 22:44:29 | 5.9 min |
| `alert-vm-started` | vm-hub-lab2 | 22:48:27 | 22:54:28 | 6.0 min |
| `alert-vm-started` | vm-spoke-lab2 | 22:48:40 | 22:54:28 | 5.8 min |
| `alert-vm-deallocated` | vm-hub-lab2 | 22:50:59 | 22:54:28 | 3.5 min |
| `alert-vm-deallocated` | vm-spoke-lab2 | 22:51:38 | 22:59:28 | 7.8 min |

**Range 0.8–7.9 minutes.** Every alert fired at **x4:28 or x9:28** past the hour, so they appear to be evaluated in 5-minute batches. Detection time depends mostly on where the event lands in that cycle. That's an observation from 10 data points, not documented behavior. Design implication: Activity log alerts answer "tell me this happened, within minutes". They aren't a near-real-time control.

### M3: Incident: SSH from Hub to Spoke Stopped Working

Full report: **[RCA-001](docs/rca/rca-001-nsg-rule-deleted-ssh-outage.md)**.

| Step | What happened | Evidence |
|---|---|---|
| Break | `Allow-SSH-From-Hub-Shared` (priority 100) deleted from `nsg-spoke-lab2` **in the portal** at 22:23:38 | `m3-02` |
| Symptom | Hub → spoke TCP 22 **timed out** (dropped, not refused) | `m3-03` |
| Detection | **`alert-nsg-rule-deleted` didn't fire** | `m3-04` |
| Root cause | The rule matched `securityRules/delete`. A portal deletion is logged as **`networkSecurityGroups/write`** | `m3-04` |
| Who / how | KQL `CorrelationId` join: the write had **no matching deployment**, so it was a manual change | `m5-01` query A |
| Remediation | Lab 2 Bicep redeployed (drift correction); alert changed to `anyOf` both operations | `m3-05`…`m3-08` |
| Verification | TCP 22 succeeded; **the corrected alert fired on the remediation write** (0.8 min); Lab 2 matrix passed with IP flow verify | `m3-06`, `m3-09`, `m5-01` |

Time from break to restore: **15.6 minutes.** Nothing would have alerted without the fix.

![KQL: manual vs. code NSG changes](docs/screenshots/m3-04-kql-manual-vs-code.png)

### M4: Metric Alert: High CPU

Full report: **[RCA-002](docs/rca/rca-002-cpu-metric-alert.md)**.

| Measure | Result |
|---|---|
| Load | `scripts/cpu-load.sh` through Run Command: busy loop, self-limited to 720 s |
| Load start → **Fired** | 22:27:03 → 22:34:20 = **7.3 min** |
| Load end → **Resolved** | about 22:39 → 22:47 = **about 8 min** (email received) |
| Unexpected | The **first instance was never resolved**. A second instance opened at 22:40:22 and resolved. Hypothesis: redeploying the unchanged rule at 22:38 (for the M3 fix) reset its state. Not confirmed |

### M5: Workbook

One page for the incidents above:

| Section | Data source | Shows |
|---|---|---|
| Alert history | Azure Resource Graph (`alertsmanagementresources`) | Every fired alert: rule, target, Fired/Resolved, lifecycle state |
| VM power events | KQL on `AzureActivity` | When each VM started or was deallocated (compute billing on/off) |
| NSG changes: manual vs. code | KQL on `AzureActivity`, `CorrelationId` join | The M3 incident (manual) and its remediation (code) |
| VM Percentage CPU | Platform metrics | The M4 load |

![Workbook](docs/screenshots/m5-02-workbook.png)

**Codifying it:** a workbook's content is a JSON string (`serializedData`) that contains the subscription ID. It's stored in [`infra/workbooks/lab-operations.workbook`](infra/workbooks/lab-operations.workbook) with a `{subscriptionId}` token, and the template fills it in at deploy time:

```bicep
serializedData: replace(loadTextContent('../workbooks/lab-operations.workbook'), '{subscriptionId}', subscription().subscriptionId)
```

## Lab 4: Network Watcher

**Date:** 2026-11-05 · **Status:** completed, verified, torn down the same day · **Workload:** two VMs in `rg-netwatch-lab` on the [Project 1 network](https://github.com/ChefBoyRJeff/azure-hub-spoke-network)

### Why This Lab Exists

The earlier milestones watch the **control plane**: who changed what. They can't tell you whether packets actually get through. In the Project 1 Lab 3 incident, I had to diagnose one command at a time, and Network Watcher couldn't even test the probe address. This lab adds the **data-plane** tools:

- a continuous synthetic test that alerts: **connection monitor**
- a record of every allowed and denied flow: **VNet flow logs**, queryable through **Traffic Analytics**
- packets on demand: **packet capture**

Then it breaks the network on purpose to see what each tool shows.

### Architecture

```mermaid
flowchart LR
  subgraph HUB["vnet-hub (Project 1)"]
    H["vm-nw-hub 10.0.1.20<br/>snet-shared (private, no NSG)<br/>Network Watcher agent"]
  end
  subgraph SPOKE["vnet-spoke1 (Project 1)"]
    S["vm-nw-spoke1 10.1.1.20<br/>HTTP on 443<br/>Network Watcher agent"]
    NSG["nsg-spoke1-workload"]
    RT["rt-spoke1-workload<br/>0.0.0.0/0 -> 10.0.1.4 (no NVA)"]
  end
  SA["stnwlab... (Standard LRS)<br/>raw flow logs, .cap files"]
  LAW["law-monitoring-lab<br/>NTANetAnalytics,<br/>NWConnectionMonitor*"]
  AL["alert cm-hub-to-spoke1<br/>TestResult max > 2"] --> AG["ag-lab-ops (email)"]
  H -->|"connection monitor TCP 443 + 22 every 30 s"| S
  NSG -.->|"VNet flow log (JSON v2)"| SA
  SA -->|"Traffic Analytics every 10 min"| LAW
  H -.->|"test results"| LAW
  LAW --- AL
  S -.->|"packet capture upload<br/>(needed a service endpoint)"| SA
```

| Resource | Built | Key settings |
|---|---|---|
| `vm-nw-hub`, `vm-nw-spoke1` | CLI (M1) | D2als_v6, Ubuntu 24.04, no public IP, Network Watcher agent 1.4. Standard security type, not Trusted Launch |
| `stnwlab...` storage account | Portal | Standard LRS, East US (it must be in the VNet's region), TLS 1.2, no anonymous access |
| `fl-vnet-spoke1` (VNet flow log) | **Portal** | Target vnet-spoke1, 1-day retention, **Traffic Analytics every 10 min** into `law-monitoring-lab` |
| `cm-hub-to-spoke1` (connection monitor) | **Portal** | `tc-tcp-443` and `tc-tcp-22`, every 30 s, thresholds 5% failed / 100 ms. Output to `law-monitoring-lab` |
| `cm-hub-to-spoke1` (metric alert) | **Portal** (auto-named) | `TestResult` Maximum > 2 (1 = Pass, 2 = Warning, 3 = Fail), 5-min window, every 1 min, auto-resolve, Sev 3, `ag-lab-ops` |

NSG flow logs can no longer be created (blocked since June 2025, retired in September 2027), so this lab uses **VNet flow logs**.

### Results

| Test | Result | Evidence |
|---|---|---|
| Flow log: allowed vs. denied | 20 × HTTP 443 and 10 × SSH logged as `B`/`E` under their allow rules; 10 × TCP 8080 logged as **30 `D` (denied)** under `Deny-VNet-Inbound` | `lab4-02` |
| Why 30 denials from 10 attempts | A sender-side `tcpdump` showed **3 SYNs per attempt**, about **1 s apart, not 1 s and 3 s**. The kernel setting `tcp_syn_linear_timeouts = 4` explains it: the first SYN retries are evenly spaced | `lab4-05` |
| Connection monitor baseline | 100% pass; RTT 1.7 ms (443) and 3.8 ms (22) | `lab4-03` |
| **Incident (M4)** | Port typo on the allow rule. **Alert fired 2.9 min** after the change; email received; outage 7.2 min; alert **resolved 10.7 min** after the fix | [RCA-003](docs/rca/rca-003-nsg-port-typo-web-outage.md), `lab4-04` |
| Traffic Analytics view of the incident | 443 **Denied, 637 flows, 16:20:40–16:27:44**, matching the break and the fix to within seconds | `lab4-02` |
| Packet capture, receiver side | **0 packets** captured on the spoke VM while its NSG dropped the SYNs, which proves NSG drops happen before the guest OS | `lab4-05` |
| Portal → code | Connection monitor and alert **NoChange** on the first what-if; flow log differs only in `reference()` values | `lab4-06` |

### Investigation 1: Traffic Analytics Showed No Data

**Symptom.** `NTANetAnalytics` returned no rows at 16:11 and again at about 16:24, 30–40 minutes after enabling.

**Diagnosis.** The flow log was enabled and the raw blobs were being written. Traffic Analytics had created a data collection rule and endpoint in `rg-monitoring-lab`, and the workspace held **10** `NTANetAnalytics` rows by 16:45.

**Root cause: first-run latency.** The first processing interval was aligned to the hour (16:00–16:21) and landed at **16:25:06**, about **43 minutes after enabling**. My two earlier queries ran just before. After that, each 10-minute interval landed about 5 minutes after it ended.

**Lesson.** Confirm data exists before concluding a pipeline is broken. My first conclusion ("no longer normal lag") was wrong.

### Investigation 2: Packet Capture Wouldn't Start on the Spoke VM

The activity log held the real errors; the portal showed only a generic message for the second one.

| Error | Root cause | How it was proven |
|---|---|---|
| `PacketCaptureLocalFilePathInvalidFormat` (6 attempts) | **Hyphens in the local file name** (`/var/captures/pc-spoke1-8080.cap`). Not documented; the docs only say the path must start with `/var/captures` and include `*.cap` | Creating the folder changed nothing. `/var/captures/pchub.cap` worked on the hub. A hyphenated name was **also rejected on the hub**, where everything else worked |
| `InternalServerError` (storage-only capture) | The spoke VM **couldn't reach the storage account**. `rt-spoke1-workload` sends `0.0.0.0/0`, which includes storage's public IPs, to `10.0.1.4`, where no appliance exists. Next hop reported **`None`** | **Control:** the identical capture on the hub VM (no route table) worked and uploaded an 834-byte `.cap`. The hub reached storage (HTTP 400), the spoke timed out |

**Fix (through code, in Project 1):** a **`Microsoft.Storage` service endpoint** on the spoke subnets (`modules/spoke.bicep`). It adds routes for the region's storage address ranges with next hop `VirtualNetworkServiceEndpoint`. Those routes are more specific than `0.0.0.0/0`, so they win. What-if showed 0 deletions; then the deploy.

**Verified:** next hop → `VirtualNetworkServiceEndpoint`; storage from the spoke `000` → **HTTP 400**; the spoke capture ran and uploaded its `.cap`.

**Trade-off:** storage traffic now bypasses any future hub firewall. A private endpoint (Project 7) is the stricter option. Azure also added `westus` and `westus3` to the endpoint's locations by itself, which I recorded as no-effect noise in what-if.

### Lab 4 Findings

1. **Network Watcher names the rule that blocks, not the rule that changed.** In RCA-003, every tool named `Deny-VNet-Inbound`. Only the activity log and the what-if against code found the edited rule.
2. **A capture on the receiving VM can't see NSG-dropped traffic.** Capture on the sender, or read the flow log.
3. **The portal defaults to a new default workspace** for connection monitor (a separate Workspace tab), which would bypass the 0.1 GB daily cap. Caught on the Review page.
4. **The portal put the alert in `NetworkWatcherRG`**, named it after the monitor, and locked the name field. The connection monitor and alert have **no tags**.
5. **Traffic Analytics leaves its data collection rule and endpoint behind** when the flow log is deleted. Both had to be removed by hand at teardown.
6. **The activity log lags.** Two of my timeline calculations were wrong because events arrived late. One portal fix also produced two rule writes 9 seconds apart, which is unexplained.

### Evidence Index (Lab 4)

| File | Contents |
|---|---|
| `lab4-00-preflight.txt` | Providers, Network Watcher, workspace, the Project 1 network, free IPs, VM size and quota, policy, budgets |
| `lab4-01-build.txt` | VMs, agent, web server, baseline tests, storage account check |
| `lab4-02-flow-logs.txt` | Flow log config, raw tuples (B/E/D), the Traffic Analytics investigation |
| `lab4-03-connection-monitor.txt` | Connection monitor and alert config, first results, metrics |
| `lab4-04-incident-nsg-edit.txt` | The M4 incident: detection, investigation, fix, recovery, corrected timeline |
| `lab4-05-packet-capture.txt` | Storage path predictions, capture failures and their error codes, control tests, the fix, SYN timing |
| `lab4-06-bicep-whatif.txt` | What-if of `infra/lab4/netwatch.bicep` against the portal build |
| `lab4-07-teardown.txt` | Teardown and verification |

### Teardown and Cost (Lab 4)

Removed:
- the connection monitor and its alert, and the flow log (all in `NetworkWatcherRG`)
- the Traffic Analytics data collection rule and endpoint, by hand
- `rg-netwatch-lab` (VMs, disks, NICs, storage account)

After teardown: 0 VMs in the subscription, 0 flow logs, 0 connection monitors, 0 packet captures, 0 metric alerts. The Project 1 network still has its 7 resources; the service endpoint stays in code.

Cost estimate, **not a billed figure**:
- two D2als_v6 for about 1.8 hours: about $0.25
- Traffic Analytics and flow logs: a few MB, so cents (flow logs have a 5 GB/month free tier)
- connection monitor: inside the free 10 tests
- storage: under $0.01

`budget-az104-lab` read **$0.76 of $10** for the period, which includes earlier work.

## Troubleshooting Cases

| # | Symptom | Root cause | Resolution | Evidence |
|---|---|---|---|---|
| 1 | Creating the action group failed: *"The subscription is not registered to use namespace 'microsoft.insights'"* | The `Microsoft.Insights` resource provider wasn't **registered**. `Microsoft.AlertsManagement` was also missing | Registered both (approved, subscription-wide, no cost) | `m1-02a`, `m1-02b` |
| 2 | `AzureActivity` stayed empty after the diagnostic setting was created | Configuration was correct at every step. The new setting took **about 45 minutes to start exporting**, and events in that window were never delivered. No documented cause | Waited rather than recreating it; verified source vs. destination | `m1-05` |
| 3 | The portal showed *"You don't have access"* on the action group | Error **401**: an **expired token** (authentication), not a missing role (403) | Signed in again. No role change | Session notes |
| 4 | What-if showed the action group email changing to `[parameters('alertEmail')]` | What-if **doesn't evaluate `@secure()` parameters**. The local parameter file still held the placeholder; deploying would have **silently redirected alerts** | Fixed the file; action group test after every deploy | `m1-07`, `m1-09` |
| 5 | The alert wizard listed two "Start virtual machine" signals | One maps to **`Microsoft.DevTestLab`** and would never fire for these VMs | Chose the `Microsoft.Compute` signal; verified the operation name | `m2-01` |
| 6 | The NSG alert rule appeared in `rg-hubspoke-vms` | The wizard's resource group field **pre-fills from the selected scope** | Recreated in `rg-monitoring-lab`; removed the copy | `m3-01` |
| 7 | **NSG rule deleted in the portal; no alert** | Portal deletion = `networkSecurityGroups/write`, not `securityRules/delete` | `anyOf` both operations; proven live | [RCA-001](docs/rca/rca-001-nsg-rule-deleted-ssh-outage.md) |
| 8 | What-if reported a change to the metric alert's `targetResourceRegion` on every run | What-if **can't evaluate `reference()`** (used through `monitoredVm.location`) | Used the `location` parameter instead; what-if → NoChange | `m3m4-01`, `m3m4-02` |
| 9 | `az rest` silently ignored query parameters (`canFetchContent`, `timeRange`) | On Windows, `az` is a batch file (`az.cmd`), and **cmd.exe cuts the URL at `&`** | Pass them with `--url-parameters` | `scripts/Test-LabStatus.ps1` |
| 10 | KQL `VM` and `NSG` columns came back empty | `extract()` is **case-sensitive**, and `_ResourceId` is lowercase | Added `(?i)` to the regex | Workbook queries |
| 11 | A PowerShell report printed `status=bool Equals(...)` | `$_.equals` resolved to the .NET **`Equals()` method**, not the JSON property | `PSObject.Properties['equals'].Value` | Session notes |
| 12 | What-if always showed the workbook's `serializedData` as added | A GET of a workbook **omits its content** unless `canFetchContent=true`, so what-if has nothing to compare | Verified by fetching the content with `--url-parameters canFetchContent=true` | `m5-03` |
| 14 | Traffic Analytics tables empty 30–40 min after enabling | **First-run latency:** first interval aligned to the hour, landed about 43 min after enabling | Waited; confirmed with the data itself | `lab4-02` |
| 15 | Connection monitor review showed `DefaultWorkspace-...` | The portal's separate **Workspace** tab defaults to creating a new workspace | Unchecked the default; chose `law-monitoring-lab` | Lab 4 M3 |
| 16 | Couldn't add a deny rule at priority 90 | NSG priorities are **100–4096**, and 100 was taken | Changed the scenario to an edit of an existing rule | `lab4-04` |
| 17 | Couldn't change the port on `Allow-HTTPS-From-Hub` | **Service = HTTPS** locks the port field | Switch Service to **Custom** first | RCA-003 |
| 18 | Packet capture: `PacketCaptureLocalFilePathInvalidFormat` | **Hyphens in the local file name** (undocumented) | Hyphen-free name; isolated on a second VM | `lab4-05` |
| 19 | Packet capture: `InternalServerError` on the spoke only | No path from the spoke VM to storage (UDR to an appliance that doesn't exist) | `Microsoft.Storage` service endpoint through Project 1 code | `lab4-05` |
| 20 | KQL syntax errors at `first` and `last` | Reserved words used as column names | Renamed to `firstSeen`, `lastSeen` | `lab4-03` |
| 21 | A truncated GUID (in an `NWTA-...` resource name) passed the leak check | The mask matched only complete GUIDs | Mask partial GUIDs and `NWTA-...` names; the leak check now looks for partial patterns | `lab4-02` |
| 13 | **The subscription ID was found in four committed evidence files** (and one in Project 4) | The pre-commit redaction **only matched emails**, and pushed files weren't re-checked | Sanitized; **rewrote history** (`git filter-branch`), force-pushed with lease, verified with `git log -S`. Leak check now scans **GUIDs** too | Commit history |

## Deploy It Yourself

**Prerequisites:** an Azure subscription, the Azure CLI, Bicep, and Owner or Contributor rights. Register the providers first:

```powershell
az provider register -n Microsoft.Insights --wait
az provider register -n Microsoft.AlertsManagement --wait
```

**Parameters:** the alert email is private, so it lives in a gitignored file.

```powershell
Copy-Item infra\main.example.bicepparam infra\main.local.bicepparam
# edit infra\main.local.bicepparam and set alertEmail, then save
```

| File | Committed? | Purpose |
|---|---|---|
| `infra/main.example.bicepparam` | Yes | Template with a placeholder email |
| `infra/main.local.bicepparam` | **No** (`*.local.bicepparam` is gitignored) | Your real values |

**Preview and deploy** (subscription scope):

```powershell
az deployment sub what-if -l eastus -f infra\main.bicep -p infra\main.local.bicepparam
az deployment sub create  -l eastus -n monitoring-foundation -f infra\main.bicep -p infra\main.local.bicepparam
```

**After every deployment:**
1. Test the action group (Monitor → Alerts → Action groups → `ag-lab-ops` → Test). What-if can't verify the secure email value.
2. Check for alerts still in the *Fired* condition (RCA-002).

The alerts monitor `rg-hubspoke-vms` (`monitoredResourceGroupName`), and the CPU alert watches `vm-spoke-lab2` (`cpuAlertVmName`), which must exist first. A new diagnostic setting can take a while before data appears; confirm `AzureActivity` has rows before relying on it.

**Status check** (read-only, $0):

```powershell
.\scripts\Test-LabStatus.ps1 -OutFile status.txt
```

It reports VM power state, NSG rules, alert rules, fired alerts, and runs the workbook's KQL queries.

## Repository Structure

```
├── infra/
│   ├── main.bicep                     # Subscription scope: RG, monitoring module, Activity log diagnostic setting
│   ├── main.example.bicepparam        # Parameter template (placeholder email)
│   ├── lab4/
│   │   └── netwatch.bicep             # Lab 4: flow log + Traffic Analytics, connection monitor, alert (NetworkWatcherRG; what-if only)
│   ├── modules/
│   │   └── monitoring.bicep           # Workspace, action group, Activity log alerts (loop), metric alert, workbook
│   └── workbooks/
│       └── lab-operations.workbook    # Workbook content with a {subscriptionId} token
├── scripts/
│   ├── Test-LabStatus.ps1             # Read-only status check and KQL queries
│   ├── cpu-load.sh                    # M4: self-limiting CPU load (Run Command)
│   └── ssh-check-from-hub.sh          # M3: TCP 22 check from the hub VM (Run Command)
└── docs/
    ├── plan.md                        # Approved project plan
    ├── interview-guide.md             # Walkthrough, deep dive, likely questions
    ├── rca/                           # Root-cause reports (RCA-001, RCA-002, RCA-003)
    ├── evidence/                      # Sanitized command output per milestone
    └── screenshots/                   # Sanitized portal screenshots of successful results
```

Gitignored: `infra/*.local.bicepparam`, `infra/export/`, `docs/screenshots/raw/`, compiled `*.json`, `.vscode/`.

## Cost

| Item | Cost |
|---|---|
| Activity log collection and `AzureActivity` ingestion | $0 (free table, `_IsBillable = false`) |
| Activity log alert rules (3) | $0 |
| Platform metrics | $0 (no agent) |
| **Metric alert rule** | **About USD 0.10/month** (portal estimate, one time series). Was the only ongoing charge; **deleted 2026-11-01**, so the lab now costs $0 |
| Action group email | $0 (up to 1,000 per month) |
| Workspace | $0 (no billable data; daily cap 0.1 GB as a guardrail) |
| Workbook | $0 |
| Lab 4 (Network Watcher) | About $0.25 estimated (two D2als_v6 for about 1.8 h; Traffic Analytics, flow logs and storage in cents; connection monitor inside the free tier). All torn down |
| Test VM runtime | M2: about 1.5 min. M3+M4: about 27 min of two B1s VMs (about $0.01). VMs deallocated after every test |

## Security and Privacy

- The alert email comes from a gitignored `*.local.bicepparam` file and is marked `@secure()`, so it stays out of deployment history.
- No subscription or tenant IDs in code. Scopes use `subscription().id`; the workbook uses a token.
- Evidence files query **names only**. Before every commit, staged files are scanned for **email addresses and GUIDs** (case 13), and correlation IDs are shortened to 8 characters.
- The `Caller` field (who made a change) was reviewed in the portal but not committed, because it's an email address.
- Screenshots are saved to a gitignored `raw/` folder first and checked or redacted before being committed.

## Teardown

**To stop the only ongoing charge but keep the lab:** delete the metric alert.

```powershell
az monitor metrics alert delete -g rg-monitoring-lab -n alert-vm-spoke-cpu-high
```

It's in the Bicep, so the next deployment recreates it.

**Full teardown:**
1. Close any open alerts (Monitor → Alerts → select → Change state → Closed).
2. Delete `rg-monitoring-lab` (workspace, action group, alert rules, workbook).
3. Delete the **subscription** diagnostic setting `diag-activitylog-to-law`. It lives outside the resource group, so deleting the RG doesn't remove it:

   ```powershell
   az monitor diagnostic-settings subscription delete -n diag-activitylog-to-law --yes
   ```
4. Optionally unregister `Microsoft.Insights` and `Microsoft.AlertsManagement` (only possible if no resources of those types remain).

The monitored Lab 2 environment isn't affected by this teardown. (Lab 2 itself was torn down separately on 2026-11-01; see the update at the top.)

**Lab 4 teardown note:** deleting the flow log **doesn't remove** the `NWTA-...` data collection rule and endpoint that Traffic Analytics created in `rg-monitoring-lab`. Delete them separately (`az resource delete --ids ...`), after the flow log.

**Lesson from 2026-11-01:** delete or retarget alert rules **before** deleting the resources they watch. Once the target is gone, `az monitor ... alert update --enabled false` fails (`ResourceGroupNotFound` for the metric alert, `ScopeIsInvalid` for the Activity log alerts), because an update sends the whole rule back for validation. Deleting still works.

## Known Limitations

- **Activity log alerts take minutes** (0.8–7.9 min measured). They aren't a real-time control.
- **The NSG alert is noisy.** Matching `networkSecurityGroups/write` catches portal deletions, but also every NSG redeploy, including unchanged ones. One remediation produced three alerts, one of them unexplained. An alert processing rule during planned deployments would reduce this; not added.
- **The NSG alert detects; it doesn't prevent.** RBAC or a resource lock would prevent the change (Project 4 topics).
- **Redeploying an alert rule during an active alert may strand it** (RCA-002, hypothesis).
- **What-if blind spots:** `@secure()` values, `reference()`, and workbook content. Each has a workaround above.
- **Activity log alerts have no severity setting** (always Sev 4).
- **No alert for the daily cap.** If the cap is reached, billable data stops silently. Not added, because it would be a billable log alert.
- **The diagnostic setting's activation gap** (about 45 minutes, events lost) has no confirmed cause.
- **A VM shut down from inside the OS** (stopped, still billing) isn't alerted on. The alerts cover start and deallocate only.
- **Lab 4: one test client and one target.** No UDP, ICMP or HTTP-status tests in the connection monitor. TCP only.
- **Lab 4: the connection monitor and alert are untagged** (portal defaults), and the code keeps them that way to match live.
- **Lab 4: storage traffic from the spokes bypasses the (future) hub firewall** because of the service endpoint fix.
- **Old commits are reachable by direct URL.** After the history rewrite (case 13), GitHub still serves pre-rewrite commits to anyone with the exact hash. They contain the subscription ID, an identifier that isn't a credential.

## AZ-104 Skills Demonstrated

| Objective (Monitor and maintain Azure resources) | Where |
|---|---|
| Interpret metrics in Azure Monitor | M4: Percentage CPU, 5-minute average; workbook metrics chart |
| Configure log settings in Azure Monitor | M1: subscription diagnostic setting |
| Query and analyze logs in Azure Monitor | M1, M3, M5: KQL over `AzureActivity` (`let`, `in`, `iff`, `extract`, `ingestion_time()`) |
| Set up alert rules, action groups, and alert processing rules | M1–M4: action group, Activity log alerts, metric alert, alert lifecycle |
| Use Azure Network Watcher | M3: IP flow verify. **Lab 4:** VNet flow logs and Traffic Analytics, connection monitor, connection troubleshoot, next hop, packet capture, effective routes |
| Configure service endpoints | Lab 4: `Microsoft.Storage` endpoint to bypass a blackhole default route |
| Manage subscriptions (resource providers) | Case 1 |
| Interpret and deploy Bicep files; export resources | All milestones: portal → export → Bicep → what-if |
| Configure network security groups | M3: diagnosing and restoring an NSG rule |
