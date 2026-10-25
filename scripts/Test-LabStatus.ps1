<#
.SYNOPSIS
  Read-only status check for Project 2: VM power state, NSG rules, alert rules, fired alerts,
  and the workbook KQL queries run against the Log Analytics workspace.
.DESCRIPTION
  Makes no changes and costs nothing. Queries Log Analytics through the REST API (az rest),
  so no CLI extension is needed. Output contains no email addresses; correlation IDs are
  shortened to 8 characters so they survive the GUID-redaction step before committing.
.EXAMPLE
  .\scripts\Test-LabStatus.ps1 -OutFile docs\evidence\m5-01-status-and-queries.txt
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)]
  [string]$OutFile,
  [string]$MonitoringRg = 'rg-monitoring-lab',
  [string]$WorkspaceName = 'law-monitoring-lab',
  [string]$LabRg = 'rg-hubspoke-vms',
  [string]$Timespan = 'P1D'   # ISO 8601: last 1 day
)

function Log([string]$Message) { $Message | Tee-Object -FilePath $OutFile -Append }

function Invoke-Kql([string]$Title, [string]$Kql) {
  Log "=== KQL: $Title ==="
  $body = @{ query = $Kql; timespan = $Timespan } | ConvertTo-Json -Compress
  $tmp = [IO.Path]::GetTempFileName()
  [IO.File]::WriteAllText($tmp, $body)   # UTF-8 without BOM, so az rest parses it
  try {
    $raw = az rest --method post --url "https://api.loganalytics.io/v1/workspaces/$script:wsId/query" `
      --resource 'https://api.loganalytics.io' --headers 'Content-Type=application/json' --body "@$tmp" -o json
    if ($LASTEXITCODE -ne 0) { Log '  query failed (see error above)'; return }
    $table = (($raw -join "`n") | ConvertFrom-Json).tables[0]
    Log ('  ' + (($table.columns | ForEach-Object { $_.name }) -join ' | '))
    if (-not $table.rows -or $table.rows.Count -eq 0) { Log '  (no rows)'; return }
    foreach ($row in $table.rows) { Log ('  ' + ($row -join ' | ')) }
    Log "  rows: $($table.rows.Count)"
  }
  finally { Remove-Item $tmp -ErrorAction SilentlyContinue }
}

Set-Content -Path $OutFile -Value "Project 2 status check, $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') local (read-only)"

Log '=== VM power state (expect VM deallocated) ==='
az vm list -d -g $LabRg -o json | ConvertFrom-Json | ForEach-Object { Log "  $($_.name): $($_.powerState)" }

Log '=== nsg-spoke-lab2 inbound rules (expect 100, 110, 120, 4000) ==='
az network nsg rule list -g $LabRg --nsg-name nsg-spoke-lab2 -o json | ConvertFrom-Json | Sort-Object priority |
  ForEach-Object { Log ('  {0,-5} {1,-26} {2}' -f $_.priority, $_.name, $_.access) }

Log '=== Alert rules in rg-monitoring-lab ==='
az monitor activity-log alert list -g $MonitoringRg -o json | ConvertFrom-Json |
  ForEach-Object { Log ('  activity-log  {0,-26} enabled={1}' -f $_.name, $_.enabled) }
az monitor metrics alert list -g $MonitoringRg -o json | ConvertFrom-Json |
  ForEach-Object { Log ('  metric        {0,-26} enabled={1} severity={2}' -f $_.name, $_.enabled, $_.severity) }

Log '=== Fired alerts, last 1 day (Alerts Management API) ==='
$sub = az account show --query id -o tsv
# Query parameters go in --url-parameters: an '&' inside --url is cut off by cmd.exe when az.cmd runs (finding #8).
$alerts = ((az rest --method get --url "https://management.azure.com/subscriptions/$sub/providers/Microsoft.AlertsManagement/alerts" --url-parameters api-version=2019-05-05-preview timeRange=1d -o json) -join "`n" | ConvertFrom-Json).value
$alerts | Sort-Object { $_.properties.essentials.startDateTime } | ForEach-Object {
  Log ('  {0:yyyy-MM-dd HH:mm:ss}Z  {1,-26} target={2,-16} condition={3,-9} state={4}' -f `
    ([datetime]$_.properties.essentials.startDateTime).ToUniversalTime(),
    (($_.properties.essentials.alertRule -split '/')[-1]),
    (($_.properties.essentials.targetResource -split '/')[-1]),
    $_.properties.essentials.monitorCondition, $_.properties.essentials.alertState)
}

$script:wsId = az monitor log-analytics workspace show -g $MonitoringRg -n $WorkspaceName --query customerId -o tsv

Invoke-Kql 'A. NSG changes, manual vs. code (CorrelationId join)' @'
let deployments = AzureActivity
    | where OperationNameValue =~ "Microsoft.Resources/deployments/write"
    | distinct CorrelationId;
AzureActivity
| where OperationNameValue has "Microsoft.Network/networkSecurityGroups"
| where ActivityStatusValue in~ ("Succeeded", "Success")
| extend NSG = extract(@"(?i)networksecuritygroups/([^/]+)", 1, _ResourceId)
| extend Source = iff(CorrelationId in (deployments), "Code (deployment)", "Manual (no deployment)")
| project TimeGenerated, NSG, Operation = OperationNameValue, Source, Correlation = substring(CorrelationId, 0, 8)
| order by TimeGenerated asc
'@

Invoke-Kql 'B. VM power events' @'
AzureActivity
| where OperationNameValue has_any ("virtualMachines/start/action", "virtualMachines/deallocate/action")
| where ActivityStatusValue in~ ("Succeeded", "Success")
| extend VM = extract(@"(?i)virtualmachines/([^/]+)", 1, _ResourceId)
| extend Action = iff(OperationNameValue has "start", "Started", "Deallocated")
| project TimeGenerated, VM, Action
| order by TimeGenerated asc
'@

Invoke-Kql 'C. Ingestion cost check (expect _IsBillable False only)' @'
AzureActivity
| summarize Rows = count() by _IsBillable
'@

Log 'Done.'
