// Lab 4 (Network Watcher): VNet flow log with Traffic Analytics, connection monitor, and its alert.
// Built in the portal first (M2, M3), then written from the live export (infra/export/lab4, gitignored)
// and checked with what-if against the portal build. Deploy scope: NetworkWatcherRG, where Network
// Watcher keeps its child resources (flow logs, connection monitors). The portal also put the alert there.
//
//   az deployment group what-if -g NetworkWatcherRG -f infra/lab4/netwatch.bicep
//
// Not in this template: the two lab VMs and the storage account (rg-netwatch-lab, built with the CLI and
// the portal in M1), and the data collection rule + endpoint that Traffic Analytics created on its own
// in rg-monitoring-lab (named NWTA-..., platform-managed).
targetScope = 'resourceGroup'

@description('Region of the Network Watcher, the monitored VNet, and the storage account')
param location string = 'eastus'

@description('Network Watcher for the region (created automatically by Azure)')
param networkWatcherName string = 'NetworkWatcher_${location}'

@description('Resource group of the Project 1 network (azure-hub-spoke-network)')
param hubSpokeResourceGroup string = 'rg-hubspoke-lab'

@description('VNet whose traffic is logged')
param flowLogVnetName string = 'vnet-spoke1'

@description('Resource group of the Lab 4 VMs and storage account')
param labResourceGroup string = 'rg-netwatch-lab'

@description('Storage account for raw flow logs and packet captures. Must be Standard and in the same region as the VNet')
param storageAccountName string = 'stnwlab4k7q2x'

@description('Connection monitor source VM')
param sourceVmName string = 'vm-nw-hub'

@description('Connection monitor destination VM')
param destinationVmName string = 'vm-nw-spoke1'

@description('Resource group of the Project 2 workspace and action group')
param monitoringResourceGroup string = 'rg-monitoring-lab'

@description('Log Analytics workspace for Traffic Analytics and connection monitor results')
param workspaceName string = 'law-monitoring-lab'

@description('Action group the connection monitor alert notifies')
param actionGroupName string = 'ag-lab-ops'

@description('Standard tags. Applied to the flow log only - the portal created the connection monitor and alert without tags (recorded as a finding; see the README)')
param tags object = {
  project: 'azure-monitoring-incident-response'
  environment: 'lab'
  owner: 'jeff'
  costCenter: 'CC-1001'
  lab: 'lab4'
}

// --- Existing resources this template points at ----------------------------
resource networkWatcher 'Microsoft.Network/networkWatchers@2024-05-01' existing = {
  name: networkWatcherName
}

resource workspace 'Microsoft.OperationalInsights/workspaces@2025-07-01' existing = {
  name: workspaceName
  scope: resourceGroup(monitoringResourceGroup)
}

var flowLogVnetId = resourceId(hubSpokeResourceGroup, 'Microsoft.Network/virtualNetworks', flowLogVnetName)
var storageAccountId = resourceId(labResourceGroup, 'Microsoft.Storage/storageAccounts', storageAccountName)
var sourceVmId = resourceId(labResourceGroup, 'Microsoft.Compute/virtualMachines', sourceVmName)
var destinationVmId = resourceId(labResourceGroup, 'Microsoft.Compute/virtualMachines', destinationVmName)
var actionGroupId = resourceId(monitoringResourceGroup, 'Microsoft.Insights/actionGroups', actionGroupName)

// Endpoint names as the portal built them: "<vm>(<resource group>)"
var sourceEndpointName = '${sourceVmName}(${labResourceGroup})'
var destinationEndpointName = '${destinationVmName}(${labResourceGroup})'

// --- M2: VNet flow log + Traffic Analytics -------------------------------------
resource flowLog 'Microsoft.Network/networkWatchers/flowLogs@2024-05-01' = {
  parent: networkWatcher
  name: 'fl-${flowLogVnetName}'
  location: location
  tags: tags
  properties: {
    targetResourceId: flowLogVnetId
    storageId: storageAccountId
    enabled: true
    retentionPolicy: {
      days: 1 // lab: raw logs only need to outlive the analysis
      enabled: true
    }
    format: {
      type: 'JSON'
      version: 2
    }
    flowAnalyticsConfiguration: {
      networkWatcherFlowAnalyticsConfiguration: {
        enabled: true
        workspaceResourceId: workspace.id
        workspaceId: workspace.properties.customerId
        workspaceRegion: workspace.location
        trafficAnalyticsInterval: 10 // minutes; first data took ~43 min (first interval aligned to the hour)
      }
    }
  }
}

// --- M3: connection monitor, hub VM -> spoke VM, TCP 443 and 22 every 30 s -----
var testConfigurations = [for port in [443, 22]: {
  name: 'tc-tcp-${port}'
  protocol: 'Tcp'
  testFrequencySec: 30
  tcpConfiguration: {
    port: port
    disableTraceRoute: false
  }
  successThreshold: {
    checksFailedPercent: 5
    roundTripTimeMs: 100
  }
}]

resource connectionMonitor 'Microsoft.Network/networkWatchers/connectionMonitors@2024-05-01' = {
  parent: networkWatcher
  name: 'cm-hub-to-spoke1'
  location: location
  properties: {
    endpoints: [
      {
        name: sourceEndpointName
        type: 'AzureVM'
        resourceId: sourceVmId
      }
      {
        name: destinationEndpointName
        type: 'AzureVM'
        resourceId: destinationVmId
      }
    ]
    testConfigurations: testConfigurations
    testGroups: [
      {
        name: 'tg-hub-to-spoke1'
        disable: false
        sources: [
          sourceEndpointName
        ]
        destinations: [
          destinationEndpointName
        ]
        testConfigurations: [for tc in testConfigurations: tc.name]
      }
    ]
    outputs: [
      {
        type: 'Workspace'
        workspaceSettings: {
          workspaceResourceId: workspace.id
        }
      }
    ]
  }
}

// --- M3: alert on test failure (portal-created; the portal named it after the monitor) --
// TestResult metric values: 1 = Pass, 2 = Warning, 3 = Fail, so "Maximum > 2" fires on any Fail in the window.
// Stateful (autoMitigate): resolves after 3 consecutive evaluations without a Fail. Measured in M4:
// fired 2.9 min after the break, resolved 10.7 min after the fix.
resource connectionMonitorAlert 'Microsoft.Insights/metricAlerts@2018-03-01' = {
  name: connectionMonitor.name
  location: 'global'
  properties: {
    description: ''
    severity: 3
    enabled: true
    scopes: [
      connectionMonitor.id
    ]
    evaluationFrequency: 'PT1M'
    windowSize: 'PT5M'
    targetResourceType: 'Microsoft.Network/networkWatchers/connectionMonitors'
    targetResourceRegion: location
    autoMitigate: true
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
      allOf: [
        {
          criterionType: 'StaticThresholdCriterion'
          name: 'Metric1'
          metricNamespace: 'Microsoft.Network/networkWatchers/connectionMonitors'
          metricName: 'TestResult'
          operator: 'GreaterThan'
          threshold: 2
          timeAggregation: 'Maximum'
          dimensions: [for d in ['SourceName', 'DestinationName', 'TestGroupName', 'TestConfigurationName']: {
            name: d
            operator: 'Include'
            values: [
              '*'
            ]
          }]
        }
      ]
    }
    actions: [
      {
        actionGroupId: actionGroupId
      }
    ]
  }
}

output flowLogId string = flowLog.id
output connectionMonitorId string = connectionMonitor.id
output alertId string = connectionMonitorAlert.id
