// Resource-group-scope monitoring resources: Log Analytics workspace and action group.

@description('Region for the workspace')
param location string

@description('Log Analytics workspace name')
param workspaceName string

@description('Action group name')
param actionGroupName string

@description('Email address for alert notifications')
@secure()
param alertEmail string

@description('Resource group whose VMs are monitored for power events')
param monitoredResourceGroupName string

@description('VM watched by the CPU metric alert (in the monitored resource group)')
param cpuAlertVmName string

@description('Tags applied to every resource')
param tags object

// --- Log Analytics workspace -----------------------------------------------
resource workspace 'Microsoft.OperationalInsights/workspaces@2025-07-01' = {
  name: workspaceName
  location: location
  tags: tags
  properties: {
    sku: {
      name: 'PerGB2018' // Pay-as-you-go
    }
    retentionInDays: 30
    workspaceCapping: {
      // Bicep has no decimal literals, so json() converts the string to the number 0.1.
      dailyQuotaGb: json('0.1') // cost guardrail: stops billable ingestion for the day at 0.1 GB
    }
    features: {
      enableLogAccessUsingOnlyResourcePermissions: true // resource-context access mode
    }
    publicNetworkAccessForIngestion: 'Enabled'
    publicNetworkAccessForQuery: 'Enabled'
  }
}

// --- Action group ----------------------------------------------------------
resource actionGroup 'Microsoft.Insights/actionGroups@2023-01-01' = {
  name: actionGroupName
  location: 'Global'
  tags: tags
  properties: {
    groupShortName: 'lab-ops' // max 12 characters; shown in notifications
    enabled: true
    emailReceivers: [
      {
        name: 'email-ops_-EmailAction-' // exact name the portal stored (it appends the suffix)
        emailAddress: alertEmail
        useCommonAlertSchema: false
      }
    ]
  }
}

// --- Activity log alerts (M2, M3) --------------------------------------------
// Evaluated directly against the Activity log (no workspace or query). Free.
// Measured detection time in testing: about 7-8 minutes from event to alert.
// Note: Activity log alert rules have no severity setting; the portal shows them as Sev 4 (Verbose).
var activityLogAlertRules = [
  {
    name: 'alert-vm-started' // M2: compute billing begins
    // Microsoft.Compute, not Microsoft.DevTestLab: the portal lists look-alike signals.
    operationNames: [
      'Microsoft.Compute/virtualMachines/start/action'
    ]
    description: 'A VM in ${monitoredResourceGroupName} was started (compute billing begins).'
  }
  {
    name: 'alert-vm-deallocated' // M2: compute billing stops
    operationNames: [
      'Microsoft.Compute/virtualMachines/deallocate/action'
    ]
    description: 'A VM in ${monitoredResourceGroupName} was deallocated (compute billing stops).'
  }
  {
    name: 'alert-nsg-rule-deleted' // M3: detection for an unplanned access change
    // M3 finding: removing a rule can surface as EITHER operation. The CLI (az network nsg rule delete) uses
    // securityRules/delete; the portal and Bicep re-save the whole NSG (networkSecurityGroups/write). Matching
    // only the first missed the portal deletion. networkSecurityGroups/write also fires on any other NSG change
    // (noisier, but no silent miss). anyOf can't be built in the portal wizard: this condition is code-only.
    operationNames: [
      'Microsoft.Network/networkSecurityGroups/securityRules/delete'
      'Microsoft.Network/networkSecurityGroups/write'
    ]
    description: 'A security rule was removed or an NSG was changed in ${monitoredResourceGroupName} (possible unplanned access change).'
  }
]

resource activityLogAlert 'Microsoft.Insights/activityLogAlerts@2020-10-01' = [for rule in activityLogAlertRules: {
  name: rule.name
  location: 'global'
  tags: tags
  properties: {
    enabled: true
    description: rule.description
    scopes: [
      '${subscription().id}/resourceGroups/${monitoredResourceGroupName}'
    ]
    condition: {
      allOf: [
        {
          field: 'category'
          equals: 'Administrative'
        }
        // One operation: a plain leaf condition (exactly what the portal stores, so what-if stays NoChange).
        // Several operations: anyOf, which matches if any one of them occurs.
        length(rule.operationNames) == 1
          ? {
              field: 'operationName'
              equals: rule.operationNames[0]
            }
          : {
              anyOf: map(rule.operationNames, op => {
                field: 'operationName'
                equals: op
              })
            }
        {
          // Only the completed operation, so one email per action instead of Started/Accepted/Succeeded.
          field: 'status'
          containsAny: [
            'succeeded'
          ]
        }
      ]
    }
    actions: {
      actionGroups: [
        {
          actionGroupId: actionGroup.id
        }
      ]
    }
  }
}]

// --- Metric alert: high CPU on the spoke VM (M4) -----------------------------
// Platform metric (no agent). Billed per monitored time series: portal estimate USD 0.10/month for this rule.
// autoMitigate: the alert resolves on its own when CPU drops back below the threshold.
resource monitoredVm 'Microsoft.Compute/virtualMachines@2024-07-01' existing = {
  name: cpuAlertVmName
  scope: resourceGroup(monitoredResourceGroupName)
}

resource cpuHighAlert 'Microsoft.Insights/metricAlerts@2018-03-01' = {
  name: 'alert-vm-spoke-cpu-high'
  location: 'global'
  tags: tags
  properties: {
    description: 'Average CPU on ${cpuAlertVmName} above 80% over 5 minutes.'
    severity: 2 // Warning
    enabled: true
    scopes: [
      monitoredVm.id
    ]
    evaluationFrequency: 'PT1M' // check every minute
    windowSize: 'PT5M' // average over the last 5 minutes
    targetResourceType: 'Microsoft.Compute/virtualMachines'
    // The VM's region. Uses the location param (eastus) rather than monitoredVm.location, because what-if can't
    // evaluate reference() and would report a false change on every run. Assumes the VM shares the monitoring region.
    targetResourceRegion: location
    autoMitigate: true
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.MultipleResourceMultipleMetricCriteria'
      allOf: [
        {
          criterionType: 'StaticThresholdCriterion'
          name: 'Metric1'
          metricNamespace: 'Microsoft.Compute/virtualMachines'
          metricName: 'Percentage CPU'
          timeAggregation: 'Average'
          operator: 'GreaterThan'
          threshold: 80
          skipMetricValidation: false
        }
      ]
    }
    actions: [
      {
        actionGroupId: actionGroup.id
        webHookProperties: {}
      }
    ]
  }
}

output workspaceId string = workspace.id
output workspaceName string = workspace.name
output actionGroupId string = actionGroup.id
output activityLogAlertNames array = [for (rule, i) in activityLogAlertRules: activityLogAlert[i].name]
output cpuAlertName string = cpuHighAlert.name
