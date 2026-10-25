# Azure Monitoring and Incident Response

Azure Monitor lab: Log Analytics, KQL, Activity log and metric alerts, action groups, and workbooks. Each resource is built in the portal first, then codified in Bicep and verified with what-if. Controlled-failure incidents are documented with root-cause analysis and evidence. Built as a hands-on project while studying for **AZ-104: Microsoft Azure Administrator**. This is lab work in a personal subscription, not a production environment.

> **Status: planning complete, nothing deployed yet.** This README is updated as each milestone is finished and verified. See [`docs/plan.md`](docs/plan.md) for the approved plan.

## Problem It Solves

Operations teams need to **detect** changes and failures automatically, **investigate** them with logs, and **prove** what happened. In this portfolio's [hub-and-spoke Lab 2](https://github.com/ChefBoyRJeff/azure-hub-spoke-network#lab-2-portal-built-connectivity-validation), an interrupted test script left a VM running, and nobody knew until someone checked by hand. This project builds the monitoring that would have caught it.

## Milestones

| # | Milestone | Status |
|---|---|---|
| M1 | Log Analytics workspace, action group, Activity log → workspace | Planned |
| M2 | Activity log alert: VM started or deallocated | Planned |
| M3 | Incident: "SSH to the spoke stopped working" (NSG rule deleted) | Planned |
| M4 | Metric alert: high CPU, fired and resolved | Planned |
| M5 | Workbook | Planned |
| M6 | Documentation, RCAs, interview guide, teardown | Planned |

## Repository Structure

```
├── docs/
│   ├── plan.md          # Approved project plan
│   ├── evidence/        # Sanitized command output per milestone
│   └── screenshots/     # Sanitized portal screenshots (originals in docs/screenshots/raw/, gitignored)
└── infra/               # Bicep for all monitoring resources
```

## Cost

Target: **$0–1/month**. Activity log collection and alerting and platform metrics carry no charge. Log Analytics includes 5 GB/month of free ingestion. Every potentially billable item is priced and approved before it's created. See [`docs/plan.md`](docs/plan.md#cost).

## Security and Privacy

- The alert email address is supplied at deploy time from a `*.local.bicepparam` file, which is gitignored.
- Subscription and tenant IDs, email addresses, and public IPs are removed from all evidence and screenshots before committing.
