# RCA-001: SSH from Hub to Spoke Stopped Working (NSG Rule Deleted, Alert Did Not Fire)

| Field | Value |
|---|---|
| Milestone | M3, controlled failure |
| Date | 2026-10-25 (all times UTC) |
| Environment | Personal lab subscription. `rg-hubspoke-vms` (Lab 2 workload) monitored from `rg-monitoring-lab` |
| Impact | TCP 22 from `vm-hub-lab2` (10.20.1.4) to `vm-spoke-lab2` (10.21.1.4) blocked for about 16 minutes |
| Detection gap | The NSG alert built for this failure **did not fire** for the change that caused it |
| Status | Resolved and verified. Detection gap fixed in code and proven with a live event |

## Summary

An inbound NSG rule, `Allow-SSH-From-Hub-Shared` (priority 100 on `nsg-spoke-lab2`), was deleted in the Azure portal to simulate a human error. SSH from the hub stopped working. The alert rule `alert-nsg-rule-deleted` stayed silent, because it matched only `Microsoft.Network/networkSecurityGroups/securityRules/delete`, and **a rule deleted in the portal is logged as `Microsoft.Network/networkSecurityGroups/write`**. A KQL query using the Activity log's `CorrelationId` showed the change was manual (not part of any deployment). The rule was restored by redeploying the Lab 2 Bicep. The alert condition was changed to match either operation, and the remediation deployment itself fired the corrected alert.

## Timeline (UTC)

| Time | Event | Evidence |
|---|---|---|
| 22:22:31 | Baseline captured: rules 100, 110, 120, 4000 present; VMs deallocated | `m3-02` |
| **22:23:38** | **Rule 100 deleted in the portal.** Activity log records `networkSecurityGroups/write` Succeeded on `nsg-spoke-lab2` | `m3-02`, `m3-04`, `m5-01` query A |
| 22:25:28 / 22:26:38 | Hub and spoke VMs started for testing | `m4-02`, `m5-01` query B |
| **22:27:38** | **Symptom:** `nc -zv -w 5 10.21.1.4 22` from the hub: *timed out*, `RESULT_tcp22=1` | `m3-03` |
| 22:29:28 | Two alert emails arrive. **These are `alert-vm-started`, not the NSG alert** (see Finding 3) | `m3-04` |
| 22:32:58 | Source Activity log checked: the only NSG operation is `networkSecurityGroups/write` (Started → Accepted → Succeeded). No `securityRules/delete` exists | `m3-04` |
| 22:34:50 | Fired-alerts list checked: **no `alert-nsg-rule-deleted` instance** | `m3-04` |
| 22:38:02 | Detection fix deployed (`anyOf` condition), Succeeded in 27 s | `m3-07`, `m3-08` |
| 22:38:36–37 | Remediation: Lab 2 Bicep redeployed. Both NSGs written by the deployment (correlation `e4273fbf`) | `m3-06`, `m5-01` query A |
| **22:39:14** | **Service restored:** TCP 22 from the hub *succeeded*, `RESULT_tcp22=0` | `m3-06` |
| **22:39:28** | **Corrected alert fires** on `nsg-spoke-lab2` (0.8 min after the write) | `m5-01` |
| 22:44:29 | Two more `alert-nsg-rule-deleted` instances (`nsg-hub-lab2`, `nsg-spoke-lab2`) | `m5-01` |
| 22:48–22:52 | Full Lab 2 test matrix: SSH allowed, other paths denied as designed; VMs deallocated | `m3-09` |

Time to restore after the break: **15.6 min** (22:23:38 → 22:39:14). In a real incident, nothing would have alerted. The break was found only because a test was run.

## 1. Symptom

TCP 22 from `vm-hub-lab2` to `vm-spoke-lab2` **timed out**:

```
nc: connect to 10.21.1.4 port 22 (tcp) timed out: Operation now in progress
RESULT_tcp22=1
```

A **timeout** (not "connection refused") points to traffic being dropped on the network path, for example by an NSG. A refusal would mean the packet reached the VM and nothing was listening. This distinction comes from the Lab 2 test script.

## 2. Initial Hypotheses

1. An NSG rule changed or was removed (most likely: the spoke NSG is the only filter on this path).
2. Peering or routing broke.
3. The spoke VM or `sshd` is down.

Hypothesis 1 was tested first because it's the cheapest to check and because the alert rule was supposed to catch it.

## 3. Diagnostics

**a. Current rules vs. the known-good baseline** (`m3-02`): rule 100 `Allow-SSH-From-Hub-Shared` is missing. Rule 4000 `Deny-VNet-Inbound` now matches hub traffic. This explains a timeout, so hypotheses 2 and 3 became unnecessary (the full test matrix later confirmed peering and the VM were healthy).

**b. Why didn't the alert fire?** The fired-alerts list had no NSG alert (`m3-04`). The source Activity log showed which operation was actually logged:

```
22:23:38Z  Microsoft.Network/networkSecurityGroups/write   Succeeded  nsg-spoke-lab2
```

The rule matched `.../securityRules/delete`, which never occurred.

**c. Who changed it, and was it code or a person?** KQL query A (saved in the workbook and in `scripts/Test-LabStatus.ps1`) joins NSG writes against `deployments/write` events by `CorrelationId`:

```kusto
let deployments = AzureActivity
    | where OperationNameValue =~ "Microsoft.Resources/deployments/write"
    | distinct CorrelationId;
AzureActivity
| where OperationNameValue has "Microsoft.Network/networkSecurityGroups"
| where ActivityStatusValue in~ ("Succeeded", "Success")
| extend NSG = extract(@"(?i)networksecuritygroups/([^/]+)", 1, _ResourceId)
| extend Source = iff(CorrelationId in (deployments), "Code (deployment)", "Manual (no deployment)")
| project TimeGenerated, NSG, Operation = OperationNameValue, Source, Correlation = substring(CorrelationId, 0, 8)
```

Result (`m5-01`):

```
22:23:38 | nsg-spoke-lab2 | .../NETWORKSECURITYGROUPS/WRITE | Manual (no deployment) | bcd7133e
22:38:36 | nsg-hub-lab2   | .../NETWORKSECURITYGROUPS/WRITE | Code (deployment)      | e4273fbf
22:38:37 | nsg-spoke-lab2 | .../NETWORKSECURITYGROUPS/WRITE | Code (deployment)      | e4273fbf
```

The `Caller` column identifies the account that made the change. It was checked in the portal but left out of committed evidence, because it's an email address.

## 4. Root Cause

**Direct cause:** the inbound rule allowing SSH from the hub's shared subnet was deleted outside of code, so the explicit `Deny-VNet-Inbound` rule (4000) blocked the traffic.

**Why it wasn't detected:** the alert rule assumed that deleting a rule produces a `securityRules/delete` event. That's only true for some clients:

| How the rule is removed | Operation in the Activity log |
|---|---|
| `az network nsg rule delete` | `Microsoft.Network/networkSecurityGroups/securityRules/delete` |
| Azure portal (NSG → Inbound rules → Delete) | `Microsoft.Network/networkSecurityGroups/write` (the whole NSG is saved) |
| Bicep/ARM redeploy without the rule | `Microsoft.Network/networkSecurityGroups/write` |

The alert was designed from the operation's **name**, not from an observed event. It was never tested against the way the change would actually be made.

## 5. Remediation

1. **Service:** redeployed the Lab 2 Bicep (`azure-hub-spoke-network/lab2/main.bicep`), which declares rule 100. What-if beforehand showed the rule being re-added (`m3-05`). The deployment took 4 s (`m3-06`).
2. **Detection:** changed the alert condition in `infra/modules/monitoring.bicep` to match **either** operation:

   ```bicep
   operationNames: [
     'Microsoft.Network/networkSecurityGroups/securityRules/delete'
     'Microsoft.Network/networkSecurityGroups/write'
   ]
   // one operation → a plain condition; several → anyOf
   ```

   What-if showed exactly that change (`m3-07`). The portal wizard can't build an `anyOf` condition, so this rule is now code-only.

## 6. Verification

- Rules 100, 110, 120, 4000 present again (`m3-06`, `m5-01`).
- TCP 22 hub → spoke: *succeeded* (`m3-06`).
- Full Lab 2 matrix (`m3-09`): ping both ways OK; hub → spoke TCP 22 allowed; hub → spoke TCP 8080 and spoke → hub TCP 22 denied by `Deny-VNet-Inbound` (confirmed with Network Watcher **IP flow verify**). VMs deallocated after 3.5 min.
- **The fix was proven with a real event:** the remediation deployment wrote `nsg-spoke-lab2` at 22:38:37, and `alert-nsg-rule-deleted` fired at 22:39:28.

## 7. Findings

1. **Test detection against the real change path.** The same intent ("delete a rule") produces different operations depending on the client. The alert now covers both.
2. **The broader condition is noisier.** `networkSecurityGroups/write` fires on *any* NSG change, including a redeploy that changes nothing. The single remediation deployment produced **three** NSG alerts: the hub NSG (rewritten although unchanged), the spoke NSG, and a second spoke instance. Two NSG writes were logged, so the third alert is **unexplained** (possibly a duplicate evaluation; not confirmed).
3. **Check which rule fired before acting on an alert email.** The 22:29 emails arrived while the NSG alert was expected and were at first taken as proof it had fired. The fired-alerts list showed they were `alert-vm-started` (the test VMs starting). The alert's rule name, not the timing, is the evidence.
4. **`CorrelationId` separates people from pipelines.** An NSG write that shares an ID with a `deployments/write` came from code. One that doesn't was made by hand.
5. **Alerts fired on a 5-minute grid.** Every Activity log alert in this project fired at x4:28 or x9:28 past the hour. Measured detection ranged from 0.8 to 7.9 minutes depending on when the event landed. This suggests batch evaluation; it's an observation, not documented behavior.
6. **The alert rule was first created in the wrong resource group.** The portal wizard pre-filled the workload RG (`rg-hubspoke-vms`). It was recreated in `rg-monitoring-lab` (`m3-01`).

## 8. Prevention

| Control | Status |
|---|---|
| Alert on both NSG operations (`anyOf`) | ✅ Done, proven |
| Saved KQL query: manual vs. code NSG changes | ✅ Done (workbook + `Test-LabStatus.ps1`) |
| Drift check: what-if against the Lab 2 Bicep shows any out-of-band change | ✅ Available (used in `m3-05`) |
| Prevent the change: restrict `networkSecurityGroups/write` with RBAC, or a `ReadOnly` lock on the NSG (a lock on the whole RG would also block VM start) | Not done. Covered conceptually in Project 4 (RBAC, resource locks) |
| Reduce noise: alert processing rule to suppress NSG alerts during planned deployments | Not done (future improvement) |
| Pipeline-only changes (Project 3): if every change goes through CI/CD, any manual write is an incident | Planned |
