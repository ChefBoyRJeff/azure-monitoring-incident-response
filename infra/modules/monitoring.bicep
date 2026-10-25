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

// --- Activity log alerts: VM power events (M2) -----------------------------
// Evaluated directly against the Activity log (no workspace or query). Free.
// Measured detection time in testing: about 7-8 minutes from event to alert.
// Note: Activity log alert rules have no severity setting; the portal shows them as Sev 4 (Verbose).
var vmPowerAlerts = [
  {
    name: 'alert-vm-started'
    operation: 'start'
    description: 'A VM in ${monitoredResourceGroupName} was started (compute billing begins).'
  }
  {
    name: 'alert-vm-deallocated'
    operation: 'deallocate'
    description: 'A VM in ${monitoredResourceGroupName} was deallocated (compute billing stops).'
  }
]

resource vmPowerAlert 'Microsoft.Insights/activityLogAlerts@2020-10-01' = [for alert in vmPowerAlerts: {
  name: alert.name
  location: 'global'
  tags: tags
  properties: {
    enabled: true
    description: alert.description
    scopes: [
      '${subscription().id}/resourceGroups/${monitoredResourceGroupName}'
    ]
    condition: {
      allOf: [
        {
          field: 'category'
          equals: 'Administrative'
        }
        {
          // Microsoft.Compute, not Microsoft.DevTestLab: the portal lists look-alike signals.
          field: 'operationName'
          equals: 'Microsoft.Compute/virtualMachines/${alert.operation}/action'
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

output workspaceId string = workspace.id
output workspaceName string = workspace.name
output actionGroupId string = actionGroup.id
output vmPowerAlertNames array = [for (alert, i) in vmPowerAlerts: vmPowerAlert[i].name]
