# Interview Guide: Azure Monitoring and Incident Response

Talking points for this project. Everything here happened in a **personal lab subscription**. Describe it as hands-on lab work, not production experience.

> **Framing line:** "This is a lab I built while studying for AZ-104. I monitored my own hub-and-spoke environment, broke it on purpose, and documented what the monitoring caught and what it missed."

## 1. Three-to-Five-Minute Walkthrough

**Problem (30 s).** In an earlier lab, a test script was interrupted and left a VM running. Nobody noticed until I checked by hand. I wanted monitoring that would tell me when something changes: VMs starting, network rules changing, resources under load. And I wanted to prove it works by breaking things on purpose.

**What I built (60 s).**
- The subscription's **Activity log** flows into a **Log Analytics workspace** through a diagnostic setting, so I can query every control-plane change with KQL. That table is free; I confirmed it with `_IsBillable`.
- **Three Activity log alerts:** VM started, VM deallocated, NSG changed.
- **One metric alert** on CPU, which fires and resolves on its own.
- All of them notify one **action group** (email).
- A **workbook** that shows alert history, VM power events, NSG changes, and CPU on one page.
- Everything was built in the portal first, then written in **Bicep**. I used **what-if** to prove the code matched what the portal created.

**The incident (90 s).** I deleted the NSG rule that allows SSH from the hub to the spoke, in the portal, to simulate a human mistake. SSH timed out, as expected. But **the alert I built for exactly this case didn't fire.** I checked the source Activity log: the portal doesn't log a "security rule delete". It saves the whole NSG, so the operation is `networkSecurityGroups/write`. My rule only matched the delete operation, which the CLI uses. I used a KQL query that joins on `CorrelationId` to show the change was manual, not from a deployment. I restored the rule by redeploying the network's Bicep, changed the alert to match both operations, and the remediation deployment itself fired the corrected alert in under a minute.

**Results and trade-offs (45 s).** Activity log alerts took **0.8 to 7.9 minutes** across 10 measurements, and they all fired on a 5-minute grid, so they're for awareness, not real-time protection. The broader NSG condition is **noisier**: one remediation produced three alerts. The CPU alert fired 7.3 minutes after load started and resolved about 8 minutes after it ended. One instance got stranded, which I think was caused by redeploying the rule mid-alert. The whole project costs about 10 cents a month, for the metric alert.

**Close (15 s).** The biggest lesson: **an alert you haven't tested against the real change path is an assumption, not a control.**

## 2. Ten-Minute Deep Dive (Outline)

| Minutes | Topic | Show |
|---|---|---|
| 0–2 | Architecture: Activity log vs. metrics; detection (alerts) vs. investigation (workspace) | README diagram |
| 2–4 | Portal first, then code: export → Bicep → what-if NoChange; the blind spots (`@secure()`, `reference()`, workbook content) | `m3m4-01` vs. `m3m4-02` |
| 4–7 | M3 incident end to end: timeout vs. refused, NSG write vs. delete, `CorrelationId` query, `anyOf` fix, proof | RCA-001; the KQL screenshot |
| 7–8 | Stateful vs. stateless alerts; the stranded instance | RCA-002 |
| 8–9 | Cost: free tables, daily cap, the 10-cent rule, VM deallocation discipline | Cost table |
| 9–10 | What I'd do in production | Section 5 below |

**Live demo (if a subscription is available):** run `.\scripts\Test-LabStatus.ps1 -OutFile status.txt`. It's read-only and $0, and shows rules, fired alerts, and all three KQL queries in about a minute. Have the workbook open in the portal as a backup.

## 3. Likely Questions and Answers

**Q: What's the difference between an Activity log alert and a metric alert?**
An Activity log alert watches **control-plane events**, things done *to* a resource, like start, delete, or write. It's stateless: each matching event creates an alert, and there's nothing to resolve. It's free. A metric alert watches **numeric telemetry** like CPU over a time window. It's stateful: it fires when the condition becomes true and resolves when it clears. It's billed per time series. I saw both behaviors in my tests.

**Q: Why didn't your NSG alert fire?**
I wrote the condition from the operation name I expected, `securityRules/delete`. That's what the CLI logs. The portal saves the whole NSG, so it logs `networkSecurityGroups/write`. I found it by reading the actual event in the Activity log. Then I changed the rule to match either operation, and proved the fix with a real event.

**Q: Doesn't matching `networkSecurityGroups/write` create a lot of noise?**
Yes. Any NSG change fires it, including redeploys that change nothing. One remediation produced three alerts. I accepted the noise because a missed security change is worse than an extra email. In production I'd add an **alert processing rule** to suppress it during planned deployment windows, or route pipeline changes differently.

**Q: How did you know the change was manual?**
Every Activity log event has a `CorrelationId`. A deployment logs a `deployments/write` event, and the resources it changes share its ID. My query lists NSG writes and marks each one "code" if its ID matches a deployment, otherwise "manual". The break had no matching deployment. The fix did. The `Caller` field also shows *who*. I reviewed it but kept it out of the repo, because it's an email address.

**Q: How fast are Activity log alerts?**
In my tests, **0.8 to 7.9 minutes** from the event to the alert, 10 measurements. Every alert fired at 4:28 or 9:28 past the hour, which looks like 5-minute batch evaluation. That's my observation, not something I found documented. So they're good for "tell me this happened", not for stopping something in real time.

**Q: What does what-if not show you?**
Three things bit me. It doesn't evaluate `@secure()` parameters, so it can't tell you what email you're about to deploy. I nearly redirected alerts to a placeholder address. It can't evaluate `reference()`, so a property built from another resource shows as a change every time. And it compares against a GET, and a workbook's GET leaves out its content. Each one has a workaround in the repo.

**Q: How did you keep costs down?**
The Activity log table is free, and I confirmed that in the data with `_IsBillable`, not just in the docs. The workspace has a 0.1 GB daily cap as a guardrail. Activity log alerts and platform metrics are free. The only charge is the metric alert, about 10 cents a month, and I approved it after checking the portal's estimate. VMs ran only during tests and were deallocated every time. The full M3/M4 window was about 27 minutes.

**Q: Tell me about a mistake you made.**
Two. First, during the incident, two alert emails arrived right when I expected the NSG alert, and I briefly took them as proof it had fired. Checking the fired-alerts list showed they were VM-started alerts. Now I check which rule fired, not just the timing. Second, I committed evidence files that contained my subscription ID, because my redaction only looked for emails. I sanitized the files, rewrote the Git history, verified it was clean, and now scan for GUIDs before every commit.

**Q: What's the stranded alert?**
The CPU alert's first instance never resolved. A second one opened about two minutes after I redeployed the monitoring template for the NSG fix, and only that one resolved. What-if said the metric alert had no changes, but a deployment still rewrites it. My hypothesis is that rewriting it reset its state. I haven't confirmed it. To confirm it, I'd repeat the test with and without a redeploy in the middle.

**Q: Authentication vs. authorization: did you hit either?**
Yes. The portal said "You don't have access" on the action group, but the error code was **401**, an expired token. That's authentication. A missing role would be **403**, authorization. Signing in again fixed it. No role change was needed.

## 4. Follow-Up Challenges to Practice

Answer these out loud without notes:

1. If you could only keep one of your four alert rules, which one and why?
2. Your alert fires at 3 a.m. for an NSG write. Walk me through your first five minutes.
3. Why use a subscription diagnostic setting instead of querying the Activity log directly?
4. How would you alert on a VM stopped from inside the OS (still billing)?
5. How would you *prevent* the NSG change instead of detecting it? What would that break?
6. Why is the workspace in its own resource group?
7. What happens to `AzureActivity` data if the daily cap is reached? (Hint: is it billable?)
8. How would you move this to CI/CD? What checks would run on a pull request?

## 5. What I'd Change for Production

| Area | Lab | Production |
|---|---|---|
| Change control | Manual changes possible | Changes through a pipeline only; RBAC limits who can write NSGs; any manual write is an incident |
| Noise | Every NSG write alerts | Alert processing rules for maintenance windows; severity routing |
| Notification | One email | Action group with on-call rotation, ITSM ticket (for example ServiceNow), or Teams/webhook |
| Coverage | Control plane + CPU | Guest OS logs (Azure Monitor Agent), VM insights, NSG flow logs, Service Health alerts, a daily-cap alert |
| Data | 30 days | Retention set by policy; archive tier for audit |
| Deployment | Manual `az deployment` | GitHub Actions with what-if on pull requests (Project 3) |
| Scope | One resource group | Azure Policy to deploy diagnostic settings and baseline alerts everywhere |

## 6. Honest Limits to Mention If Asked

- It's a lab: two VMs, one subscription, one person. No real users or on-call rotation.
- Detection times come from 10 data points. The 5-minute grid is an observation.
- The stranded alert and the third NSG alert are unexplained, with hypotheses stated.
- The NSG alert detects but doesn't prevent.

## 7. Lab 4: Network Watcher

### Two-minute walkthrough

"The first part of this project watches the control plane: who changed what. Lab 4 adds the data plane: did the packets get through? I put two VMs on my hub-and-spoke network and set up three things:
- a **connection monitor** testing TCP 443 and 22 every 30 seconds, with an alert
- a **VNet flow log** with Traffic Analytics
- **packet capture**

Then I broke it. I changed an allow rule's port from 443 to 8443, the kind of typo someone makes during a change. The alert fired in **2.9 minutes**. The connection monitor showed only 443 failing while 22 kept passing, which narrowed it to one port straight away. Every Network Watcher tool named the rule doing the blocking, the VNet deny rule, but that rule was working as designed. **What actually changed** came from the activity log and a what-if against my Bicep, which showed the port drift exactly. I fixed it; the outage was 7.2 minutes.

Packet capture then failed with an internal server error on the spoke VM only. A control test on the hub VM worked. The difference was a route: the spoke sends 0.0.0.0/0 to an appliance that doesn't exist, which blackholes traffic to storage too. I fixed it with a storage service endpoint, through code."

### Likely questions

**Q: Flow logs vs. connection monitor: when do you use which?**
A connection monitor is **active**: it sends test traffic on a schedule and alerts when a path breaks, even with no real users. A flow log is **passive**: it records every flow that actually happened, allowed or denied, with the rule that decided it. You alert on the first and investigate with the second. In my incident the alert came from the connection monitor, and the flow log and Traffic Analytics showed 637 denied flows in exactly the outage window.

**Q: Your tools all said `Deny-VNet-Inbound` blocked the traffic. Why wasn't that the root cause?**
Because that rule did exactly what it was built to do. The deny at 4000 catches everything not allowed above it. The real change was an edit to the allow rule at 100. Network Watcher answers "what is blocking this now?". The activity log answers "what changed?". And a what-if against the code answers "how does live differ from what we intended?".

**Q: Why did the alert take 10 minutes to resolve but under 3 to fire?**
Metric alerts are stateful. They resolve only after the condition is false for three consecutive evaluations. With a 5-minute window on the *maximum* test result, the last failure has to age out of the window first, and then three clean checks run, one a minute.

**Q: Why couldn't the packet capture on the spoke see the blocked SYNs?**
The NSG drops them at the host, before they reach the guest OS, and that's where the capture runs. The capture file was empty while three connection attempts timed out. To see dropped traffic, capture on the sender or use the flow log.

**Q: Walk me through the packet capture failure.**
The portal gave a generic error, so I went to the activity log for the real error codes. There were two separate problems.
- **Local file path rejected:** it turned out to be the hyphens in the file name. I proved it on a second VM where everything else worked.
- **Storage-only capture failing with an internal error:** I suspected the storage path, so I ran the identical capture on the hub VM, which has no route table. It worked. Next hop from the spoke to storage said `None` through my route table.
- **The fix:** a storage service endpoint. Its routes are more specific than 0.0.0.0/0, so they win. After it, the spoke capture worked.

**Q: Service endpoint or private endpoint?**
A service endpoint is free and needs no DNS change, but the storage account is still reached on its public IP, and traffic bypasses a hub firewall. A private endpoint gives storage a private IP in the VNet and lets you turn off public access, at a small hourly cost and with private DNS to manage. For a lab with no firewall, the service endpoint was the cheapest correct fix. With a real firewall, I'd use a private endpoint or route storage through the firewall deliberately.

**Q: What surprised you?**
- Traffic Analytics took about 43 minutes to show its first data. I wrongly assumed it was broken.
- Linux retried SYNs at 1-second intervals rather than doubling, because of a newer kernel setting.
- Teardown left two resources behind that the platform had created: the Traffic Analytics data collection rule and endpoint.

### Practice challenges (Lab 4)

1. A connection monitor test fails, but IP flow verify says Allow. What else could block the traffic?
2. How would you prove that a flow log is recording denials, and not just allowed traffic?
3. Your VMs are in a subnet whose route table sends 0.0.0.0/0 to a firewall. Which Azure features stop working if the firewall is down?
4. How would you alert on a manual NSG change, not just on its effect?

**Model answers.**
1. A guest firewall on the VM, the service not listening (that gives "refused", not a timeout), a route table sending the traffic somewhere else, an AVNM security admin rule, or an NSG on the source NIC or subnet in the outbound direction.
2. Generate traffic to a port you know is denied, then find `D` records with that rule in the raw JSON, or `FlowStatus = Denied` in `NTANetAnalytics`, keeping Traffic Analytics' delay in mind.
3. Anything that leaves the VNet: internet access, and Azure PaaS services on public endpoints (storage, Key Vault) unless you have service or private endpoints. In this lab that included packet capture uploads. Platform services on 168.63.129.16, such as Run Command, DNS and the VM agent, keep working.
4. An activity log alert on `Microsoft.Network/networkSecurityGroups/securityRules/write` (and `networkSecurityGroups/write`, per RCA-001), plus a scheduled what-if against the code to report drift.

### Honest limits (Lab 4)

- Two VMs, about 2 hours, one test path. TCP checks only.
- Timings come from one incident. Detection and resolution depend on the alert's window and evaluation settings.
- The connection monitor resources were built in the portal and only checked with what-if, not redeployed from code.
