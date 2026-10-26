# RCA-002: High-CPU Metric Alert Test (Fired, Resolved, One Instance Stranded)

| Field | Value |
|---|---|
| Milestone | M4, controlled test |
| Date | 2026-10-25 (all times UTC) |
| Target | `vm-spoke-lab2` (Ubuntu, B1s) |
| Rule | `alert-vm-spoke-cpu-high`: Percentage CPU, Average > 80 over 5 min, evaluated every 1 min, Sev 2, `autoMitigate` on |
| Result | ✅ Fired and resolved as designed. ⚠️ One alert instance was left in the *Fired* state |

This was a planned test, not an outage. It's written in RCA form because it produced one unexpected result.

## Objective

Prove that a **stateful metric alert** behaves differently from the stateless Activity log alerts: it should fire when the condition becomes true and **resolve on its own** when the condition clears, sending an email for each.

## Method

1. Start the VMs (approved VM window): spoke running at 22:27:01 (`m4-02`).
2. Run `scripts/cpu-load.sh` through Run Command. It starts a detached busy loop limited to 720 s:

   ```sh
   setsid nohup timeout 720 sh -c 'while :; do :; done' &
   ```

   `setsid nohup` lets Run Command return immediately while the load keeps running. `timeout 720` guarantees the load stops by itself. That matters because the lab's VMs are deallocated after every test.
3. Load ran **22:27:03 → about 22:39:03**.

## Results

| Measure | Value | Evidence |
|---|---|---|
| Load start → alert **fired** | 22:27:03 → 22:34:20 = **7.3 min** | `m4-02`, `m5-01`, email |
| Load end → alert **resolved** | about 22:39:03 → 22:47 = **about 8 min** | Resolved email |
| Ingestion cost | $0. Platform metrics need no agent | Microsoft Learn: Azure Monitor cost |
| Rule cost | Portal estimate **USD 0.10/month** (one time series). Approved before creation | `m4-01` |

**Why about 7 minutes to fire:** the rule averages a 5-minute window. A B1s busy loop pins the single vCPU at about 100%, but the average only crosses 80% after roughly 4 minutes of load (4 of 5 minutes at 100%). Then the 1-minute evaluation and metric delivery delay are added.

**Why about 8 minutes to resolve:** the 5-minute average must fall below 80% again, and the alert needs to evaluate the cleared condition. The exact resolve criteria weren't verified against documentation.

## Unexpected Result: A Stranded Alert Instance

The fired-alerts list (`m5-01`) showed **two** instances of the CPU alert:

```
22:34:20Z  alert-vm-spoke-cpu-high  target=vm-spoke-lab2  condition=Fired     state=New
22:40:22Z  alert-vm-spoke-cpu-high  target=vm-spoke-lab2  condition=Resolved  state=New
```

The first instance, the one that actually detected the load, **never resolved**. A second instance fired at 22:40:22 and resolved at 22:47.

**Hypothesis (not confirmed):** at 22:38:02 the monitoring Bicep was redeployed to fix the NSG alert (RCA-001). What-if showed the metric alert as **NoChange**, but a deployment still PUTs every resource in the template. Re-saving the rule appears to have **reset its evaluation state**: the rule "forgot" the open instance, saw CPU still above 80% (the 5-minute average was still high), opened a new one, and later resolved only the new one.

**Evidence for it:** the second instance started about 2 minutes after the redeploy, while the load was still in the 5-minute window.
**What would confirm it:** repeat the test and redeploy the unchanged rule mid-alert, then compare with a run without a redeploy. Not done, to avoid another VM window.

## Impact

- Low in the lab. In operations, a stranded *Fired* instance looks like an open incident that nobody is handling, and it **never sends a resolved notification**.
- `autoMitigate` can't be relied on to close everything if the rule is redeployed during an active alert.

## Remediation

- Close the stranded instance manually (Monitor → Alerts → select it → Change state → **Closed**, with a comment). The alert lifecycle state (New / Acknowledged / Closed) is separate from the monitor condition (Fired / Resolved). Closing it doesn't change the condition.

## Prevention

| Practice | Why |
|---|---|
| Avoid redeploying alert rules while one of their alerts is open, or check fired alerts after any monitoring deployment | A NoChange what-if doesn't mean the deployment has no side effects |
| After any monitoring deployment, list fired alerts that are still *Fired* | `scripts/Test-LabStatus.ps1` prints condition and state |
| Future: deployment stacks or splitting alert rules into their own module | Makes it easier to deploy only what changed |

## Findings

1. **Metric alerts are stateful; Activity log alerts aren't.** The metric alert fired once, then resolved. Each Activity log event produced its own alert with nothing to resolve.
2. **Detection latency is designed in.** A 5-minute window plus 1-minute frequency means about 5–7 minutes before an alert, by design. A shorter window reacts faster but alerts more on brief spikes.
3. **What-if NoChange ≠ no side effects.** (Hypothesis above.)
4. **The rule has an ongoing cost** (USD 0.10/month). Delete it at teardown. It's the only billable resource in this project.
