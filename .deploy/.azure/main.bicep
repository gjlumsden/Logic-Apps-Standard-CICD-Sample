@description('A prefix from which all resource names are derived.')
param appNamePrefix string
@allowed([
  'd'
  'i'
  'p'
])
param env string = 'd'

@description('The location of the deployed resources. Defaults to the Resource Group location')
param location string = resourceGroup().location

@description('The SQL Admin Password for the \'dbuser\' login')
@secure()
param sqlAdminPassword string

@description('A client IP to add to the SQL Server Firewall.')
param clientIpAddress string = ''


var locationAbbr = {
  uksouth: 'uks'
  ukwest: 'ukw'
  //More required for other locations
}
var baseName = '${appNamePrefix}${env}'
var sqlServerName = '${baseName}-${locationAbbr[location]}-sqlsrv'
var keyVaultName = '${baseName}-${locationAbbr[location]}-kv'
var sqlAdminUsername = 'dbuser'
var sqlDatabaseName = '${baseName}-Lookup-sqldb'
var storageAccountName = toLower('${baseName}lappstg') //Consider using uniqueString(resourceGroup().id) for uniqueness
var appServicePlanName = '${baseName}-ws-asp'
var logicAppName = '${baseName}-lapp'
var appInsightsName = '${baseName}-ai'
var workspaceName = '${baseName}-law'

resource sqlServer 'Microsoft.Sql/servers@2021-11-01-preview' = {
  name: sqlServerName
  location: location
  properties: {
    administratorLogin: sqlAdminUsername
    administratorLoginPassword: sqlAdminPassword
  }
}

resource sqlFirewallRuleAzureIps 'Microsoft.Sql/servers/firewallRules@2021-11-01-preview' = {
  name: 'AllowAllWindowsAzureIps'
  parent: sqlServer
  properties: {
    endIpAddress: '0.0.0.0'
    startIpAddress: '0.0.0.0'
  }
}

resource sqlFirewallRuleClientIp 'Microsoft.Sql/servers/firewallRules@2021-11-01-preview' = if(clientIpAddress != '' && clientIpAddress != null) {
  name: 'ClientIp'
  parent: sqlServer
  properties: {
    endIpAddress: clientIpAddress
    startIpAddress: clientIpAddress
  }
}

resource lookupDatabase 'Microsoft.Sql/servers/databases@2021-11-01-preview' = {
  parent: sqlServer
  name: sqlDatabaseName
  location: location
  sku: {
    name: 'Standard'
    tier: 'Standard'
    capacity: 10
  }
  properties: {
    sampleName: 'AdventureWorksLT'
  }
}

resource keyVault 'Microsoft.KeyVault/vaults@2019-09-01' = {
  name: keyVaultName
  location: location
  properties: {
    tenantId: subscription().tenantId
    enabledForDeployment: false
    enabledForTemplateDeployment: false
    enabledForDiskEncryption: false
    enableSoftDelete: (env == 'd' || env == 'i') ? false : true
    enableRbacAuthorization: false
    softDeleteRetentionInDays: 7
    sku: {
      name: 'standard'
      family: 'A'
    }
    accessPolicies: [
    ]
  }
}

resource keyVaultAccessPolicy 'Microsoft.KeyVault/vaults/accessPolicies@2021-11-01-preview' = {
  name: 'add'
  parent: keyVault
  properties: {
    accessPolicies:[
      {
        permissions: {
          secrets: [
            'get'
          ]
        }
        tenantId: logicApp.identity.tenantId
        objectId: logicApp.identity.principalId
      }
    ]
  }
}

resource sqlConnectionStringSecret 'Microsoft.KeyVault/vaults/secrets@2019-09-01' = {
  name: 'sqlAdminConnectionString'
  parent: keyVault
  properties: {
    value: 'Server=tcp:${sqlServer.name}${environment().suffixes.sqlServerHostname},1433;Initial Catalog=${lookupDatabase.name};Persist Security Info=False;User ID=${sqlAdminUsername};Password=${sqlAdminPassword};MultipleActiveResultSets=False;Encrypt=True;TrustServerCertificate=False;Connection Timeout=30;'
  }
}

resource storageConnectionStringSecret 'Microsoft.KeyVault/vaults/secrets@2019-09-01' = {
  name: 'storageConnectionString'
  parent: keyVault
  properties: {
    value: 'DefaultEndpointsProtocol=https;AccountName=${storageAccountName};AccountKey=${listKeys(storageAccount.id, '2021-09-01').keys[0].value};EndpointSuffix=core.windows.net'
  }
}

resource aiInstrumentationKeySecret 'Microsoft.KeyVault/vaults/secrets@2019-09-01' = {
  name: 'aiInstrumentationKey'
  parent: keyVault
  properties: {
    value: appInsights.properties.InstrumentationKey
  }
}

resource aiConnectionStringSecret 'Microsoft.KeyVault/vaults/secrets@2019-09-01' = {
  name: 'aiConnectionString'
  parent: keyVault
  properties: {
    value: appInsights.properties.ConnectionString
  }
}

resource storageAccount 'Microsoft.Storage/storageAccounts@2021-09-01' = {
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  name: storageAccountName
  location: location
}

//We need to create the File Share for the Logic App since the connection string uses a Key Vault Reference.
resource contentShare 'Microsoft.Storage/storageAccounts/fileServices/shares@2021-09-01' = {
  name: '${storageAccount.name}/default/${toLower(logicAppName)}'
}

resource workflowPlan 'Microsoft.Web/serverfarms@2021-03-01' = {
  name: appServicePlanName
  location: location
  sku: {
    name: 'WS1'
    tier: 'WorkflowStandard'
  }
  kind: 'windows'
}

resource logicApp 'Microsoft.Web/sites@2021-03-01' = {
  name: logicAppName
  location: location
  kind: 'workflowapp,functionapp'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    serverFarmId: workflowPlan.id
    siteConfig: {
      netFrameworkVersion: 'v4.6'
      appSettings: [
        {
          name: 'APP_KIND'
          value: 'workflowApp'
        }
        {
          name: 'AzureFunctionsJobHost__extensionBundle__id'
          value: 'Microsoft.Azure.Functions.ExtensionBundle.Workflows'
        }
        {
          name: 'AzureFunctionsJobHost__extensionBundle__version'
          value: '[1.*, 2.0.0)'
        }
        {
          name: 'AzureWebJobsStorage'
          value: '@Microsoft.KeyVault(VaultName=${keyVault.name};SecretName=${storageConnectionStringSecret.name})'
        }
        {
          name: 'FUNCTIONS_EXTENSION_VERSION'
          value: '~3'
        }
        {
          name: 'FUNCTIONS_WORKER_RUNTIME'
          value: 'node'
        }
        {
          name: 'WEBSITE_CONTENTAZUREFILECONNECTIONSTRING'
          value: '@Microsoft.KeyVault(VaultName=${keyVault.name};SecretName=${storageConnectionStringSecret.name})'
        }
        {
          name: 'WEBSITE_CONTENTSHARE'
          value: toLower(logicAppName)
        }
        {
          name: 'WEBSITE_NODE_DEFAULT_VERSION'
          value: '~14'
        }
        {
          name: 'sql_connectionString'
          value: '@Microsoft.KeyVault(VaultName=${keyVault.name};SecretName=${sqlConnectionStringSecret.name})'
        }
        {
          name: 'APPINSIGHTS_INSTRUMENTATIONKEY'
          value: '@Microsoft.KeyVault(VaultName=${keyVault.name};SecretName=${aiInstrumentationKeySecret.name})'
        }
        {
          name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
          value: '@Microsoft.KeyVault(VaultName=${keyVault.name};SecretName=${aiConnectionStringSecret.name})'
        }
        {
          name: 'WEBSITE_SKIP_CONTENTSHARE_VALIDATION'
          value: '1'
        }
      ]
    }
    clientAffinityEnabled: false
  }
}

resource logAnalyticsWorkspace 'Microsoft.OperationalInsights/workspaces@2020-10-01' = {
  name: workspaceName
  location: location
  properties: {
    sku: {
      name: 'PerGB2018'
    }
  }
}


resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: appInsightsName
  location: location
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: logAnalyticsWorkspace.id
    IngestionMode: 'LogAnalytics'
  }
}

output keyVaultName string = keyVaultName
output subscriptionId string = subscription().subscriptionId
output logicAppName string = logicAppName
