# RCA-003: Web App in Spoke1 Down From the Hub (Allow Rule Edited to the Wrong Port)

| Field | Value |
|---|---|
| Milestone | Lab 4 M4, controlled failure |
| Date | 2026-11-05 (all times Eastern, UTC-5) |
| Environment | Personal lab subscription. Workload `rg-netwatch-lab` on the Project 1 network (`rg-hubspoke-lab`), monitored from `rg-monitoring-lab` |
| Impact | TCP 443 from `vm-nw-hub` (10.0.1.20) to `vm-nw-spoke1` (10.1.1.20) blocked for **7.2 minutes**. SSH (22) unaffected |
| Detection | Connection monitor alert **fired 2.9 minutes** after the change; email received |
| Status | Resolved and verified. Live configuration matches the Project 1 code again |

## Summary

The inbound rule `Allow-HTTPS-From-Hub` (priority 100 on `nsg-spoke1-workload`) was edited in the portal, and its destination port was changed from 443 to 8443 to simulate a typo during a change. Traffic to 443 then fell through to `Deny-VNet-Inbound` (priority 4000) and was dropped. The connection monitor test `tc-tcp-443` started failing within a minute. The alert `cm-hub-to-spoke1` fired and emailed through `ag-lab-ops`. Every Network Watcher tool named the **blocking** rule (`Deny-VNet-Inbound`). Only the activity log and a what-if against the Project 1 Bicep identified the **changed** rule and the exact property (`destinationPortRange: "8443" => "443"`). The port was set back to 443 in the portal, and the alert resolved by itself.

## Timeline (Eastern)

| Time | Event | Evidence |
|---|---|---|
| 16:06–16:20 | Baseline: both tests pass every 30 s (4 of 4 per 2-minute bucket); RTT 1.7 ms (443) and 3.8 ms (22) | `lab4-03`, `lab4-04` |
| **16:20:36** | **Change:** `securityRules/write` on `Allow-HTTPS-From-Hub`, port 443 → 8443 | `lab4-04` (activity log) |
| 16:20–16:22 | `tc-tcp-443`: 1 pass, 3 fail, then all fail. `tc-tcp-22` keeps passing | `lab4-04` (KQL) |
| 16:20:40 | First denied 443 flow in Traffic Analytics (`deny-vnet-inbound`) | `lab4-02` (KQL) |
| **16:23:29** | **Alert `cm-hub-to-spoke1` fired** (Sev 3); email received | `lab4-04` |
| ~16:24 | Investigation: connection monitor path, connection troubleshoot, IP flow verify, flow log, what-if | `lab4-04` |
| **16:27:49** | **Fix:** port set back to 443 (a second write followed at 16:27:58) | `lab4-04` (activity log) |
| 16:27:44 | Last denied 443 flow in Traffic Analytics | `lab4-02` (KQL) |
| 16:28 | `tc-tcp-443` passes again from this 2-minute bucket on | `lab4-04` (KQL) |
| **16:38:30** | **Alert resolved** on its own, 10.7 minutes after the fix | `lab4-04` |

Detection 2.9 min · Outage 7.2 min · Alert resolution 10.7 min after the fix.

## 1. Symptom

Hub users couldn't reach the web app on vm-nw-spoke1. The alert email arrived before any manual check.

## 2. Initial Hypotheses

1. An NSG change in the spoke. It's the only filter on the path, because the hub subnet has no NSG.
2. Routing or peering changed.
3. The web service on the VM stopped.

The connection monitor separated these quickly: only port 443 failed, while port 22 to the same VM over the same path kept passing. That rules out peering, routing and the VM as a whole, and points to something specific to port 443.

## 3. Diagnostics

| Tool | Result | What it tells you |
|---|---|---|
| Connection monitor (KQL, `NWConnectionMonitorTestResult`) | `tc-tcp-443` Fail from 16:20; `tc-tcp-22` Pass throughout | Which test, and when it started |
| Connection monitor path (`NWConnectionMonitorPathResult`) | `Fail`, issues `Error_Inbound_NetworkSecurityRule`, `Error_Local_DestinationUnreachable` | An NSG on the inbound side |
| Connection troubleshoot (on demand) | 443 **Unreachable**, 30 of 30 probes failed, issue names `nsg-spoke1-workload/SecurityRules/Deny-VNet-Inbound`. 22 Reachable, 0 of 66 failed | The rule that drops the traffic |
| IP flow verify | 443 **Deny `Deny-VNet-Inbound`**; 22 Allow `Allow-Mgmt-From-Shared` | Same, from the NSG's evaluation |
| VNet flow log (raw JSON) | 253 `D` tuples on 443 under `UserRule_Deny-VNet-Inbound` | What actually happened to the packets |
| Traffic Analytics (KQL, `NTANetAnalytics`) | 443 **Denied, 637 flows**, 16:20:40–16:27:44, `deny-vnet-inbound` | The outage window, matching the change and the fix to within seconds |
| Activity log | `securityRules/write` on `Allow-HTTPS-From-Hub` at 16:20:36 | **What changed**, and when |
| What-if, Project 1 `main.bicep` | `nsg-spoke1-workload`: `destinationPortRange: "8443" => "443"` | **The exact drift** from the source of truth |

## 4. Root Cause

A manual edit set `Allow-HTTPS-From-Hub`'s destination port to 8443. HTTPS from the hub no longer matched any allow rule, so it fell through to `Deny-VNet-Inbound` (4000), which denies all `VirtualNetwork` traffic not allowed above it.

## 5. Remediation

The destination port was set back to 443 in the portal at 16:27:49. In the portal, the port field is locked while **Service** shows a named service (HTTPS); it has to be switched to **Custom** first.

## 6. Verification

- IP flow verify: 443 **Allow `Allow-HTTPS-From-Hub`**.
- Connection troubleshoot: **Reachable**, 0 of 66 probes failed, average 3 ms.
- Connection monitor: `tc-tcp-443` passes from 16:28 on.
- From vm-nw-hub: HTTP to 10.1.1.20:443, **10 of 10** succeeded.
- What-if: both spoke NSGs **NoChange**.
- Alert **resolved by itself** at 16:38:30.

## 7. Findings

1. **The blocking rule isn't the changed rule.** IP flow verify, connection troubleshoot, the flow log and Traffic Analytics all named `Deny-VNet-Inbound`, which was working exactly as designed. The change was found through the activity log and the what-if against the code. Without code as the source of truth, the investigation would stop at "the deny rule is blocking 443", which is true but doesn't say what changed.
2. **Resolution takes longer than detection by design.** A stateful metric alert resolves only after its condition is false for **three consecutive evaluations** (Microsoft documentation). With a 5-minute window on the Maximum of `TestResult`, the last failure must first age out of the window. Here that took 10.7 minutes; detection took 2.9.
3. **An edit is logged differently from a delete.** This portal edit was logged as `networkSecurityGroups/securityRules/write`. In RCA-001, a portal **delete** was logged as `networkSecurityGroups/write`. An alert that watches only one operation can miss the other; RCA-001's alert matches both.
4. **The portal created the alert outside the monitoring resource group.** `cm-hub-to-spoke1` lives in `NetworkWatcherRG`, beside the connection monitor, and the name field was locked. Recorded for teardown and for the Bicep.
5. **Unexplained tool output, not treated as a finding.** Connection troubleshoot also listed `Error/NetworkSecurityRule/Outbound` at the source hop with no rule name, but the hub subnet has no NSG. Two other open observations: the fix produced two rule writes 9 seconds apart, and Traffic Analytics attributed 3 allowed 443 flows at 16:20:42 to `platformrule`.

## 8. Prevention

- **Make changes through code, with what-if on a pull request** (Project 3). The typo would show up as `"443" => "8443"` before it reached Azure.
- **Detect drift on a schedule.** A daily what-if against the Project 1 Bicep would report this kind of edit even without an outage.
- **Alert on the change, not only the symptom.** An activity log alert on `securityRules/write` for production NSGs gives an earlier signal than a connection test.
- **Keep a synthetic test per critical path.** The 443/22 split in the connection monitor isolated the problem to one port within a minute.

## Mistakes in My Own Process (Recorded)

- I first tried a deny rule at priority 90. NSG priorities run from 100 to 4096, so that wasn't valid, and the scenario changed to an edit.
- Two timeline calculations were wrong because the activity log lags. One took the break event as the fix; the other assumed exactly two writes. The corrected timeline uses all three writes.
- I concluded too early that Traffic Analytics was broken. Its first data arrived at 16:25, about 43 minutes after it was enabled, because the first processing interval was aligned to the hour.
