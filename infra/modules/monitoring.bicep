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

output workspaceId string = workspace.id
output workspaceName string = workspace.name
output actionGroupId string = actionGroup.id
