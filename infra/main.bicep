// Project 2 (azure-monitoring-incident-response): monitoring foundation.
// Codifies resources first built in the Azure portal (M1). Verified with what-if against the portal build.
targetScope = 'subscription'

@description('Region for the resource group and the Log Analytics workspace')
param location string = 'eastus'

@description('Resource group that holds the monitoring resources')
param resourceGroupName string = 'rg-monitoring-lab'

@description('Log Analytics workspace name')
param workspaceName string = 'law-monitoring-lab'

@description('Action group name')
param actionGroupName string = 'ag-lab-ops'

@description('Resource group whose VMs are monitored for power events (Lab 2 in azure-hub-spoke-network)')
param monitoredResourceGroupName string = 'rg-hubspoke-vms'

@description('VM watched by the CPU metric alert')
param cpuAlertVmName string = 'vm-spoke-lab2'

@description('Workbook resource name. Workbooks are named by GUID; this is the one the portal created in M5.')
param workbookName string = '0abd4092-de83-46c2-b27b-5fa7a18a6053'

@description('Workbook title shown in the portal')
param workbookDisplayName string = 'Lab Operations - Incidents and Changes'

@description('Email address for alert notifications. Supplied from a gitignored *.local.bicepparam file. @secure() keeps it out of deployment history.')
@secure()
param alertEmail string

@description('Standard tags applied to every taggable resource')
param tags object = {
  project: 'azure-monitoring-incident-response'
  environment: 'lab'
  owner: 'jeff'
  costCenter: 'CC-1001'
}

// --- Resource group --------------------------------------------------------
resource rg 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: resourceGroupName
  location: location
  tags: tags
}

// --- Workspace and action group (resource-group scope, so a module) --------
module monitoring 'modules/monitoring.bicep' = {
  name: 'deploy-monitoring'
  scope: rg
  params: {
    location: location
    workspaceName: workspaceName
    actionGroupName: actionGroupName
    alertEmail: alertEmail
    monitoredResourceGroupName: monitoredResourceGroupName
    cpuAlertVmName: cpuAlertVmName
    workbookName: workbookName
    workbookDisplayName: workbookDisplayName
    tags: tags
  }
}

// --- Subscription Activity log -> workspace ---------------------------------
// Subscription-scope diagnostic setting. AzureActivity ingestion is free.
resource activityLogToWorkspace 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'diag-activitylog-to-law'
  properties: {
    workspaceId: monitoring.outputs.workspaceId
    logs: [for category in [
      'Administrative'
      'Security'
      'ServiceHealth'
      'Alert'
      'Recommendation'
      'Policy'
      'Autoscale'
      'ResourceHealth'
    ]: {
      category: category
      enabled: true
    }]
  }
}

output workspaceName string = monitoring.outputs.workspaceName
output actionGroupId string = monitoring.outputs.actionGroupId
output activityLogAlertNames array = monitoring.outputs.activityLogAlertNames
output cpuAlertName string = monitoring.outputs.cpuAlertName
