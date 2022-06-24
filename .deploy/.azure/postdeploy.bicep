targetScope = 'subscription'

param logicAppName string
param logicAppResourceGroup string
param workflowNames array
param keyVaultName string
param keyVaultResourceGroup string

resource logicApp 'Microsoft.Web/sites@2021-03-01' existing = {
  name: logicAppName
  scope: resourceGroup(logicAppResourceGroup)
}

//Add the signature for Logic Apps Standard Workflows to Key Vault Secrets
module workflowSignatureSecrets 'modules/postdeploy-secret.bicep' = [for workflow in workflowNames: {
  scope: resourceGroup(keyVaultResourceGroup)
  name: '${deployment().name}-${workflow}-sig'
  params: {
    //ARM Template Version (doesn't work here due to scope issues): signature: listCallbackUrl(resourceId('Microsoft.Web/sites/hostruntime/webhooks/api/workflows/triggers', logicApp.name, 'runtime', 'workflow', 'management', workflow, 'manual'),'2021-03-01').value
    //This does work
    signature: listCallbackUrl('${logicApp.id}/hostruntime/runtime/webhooks/workflow/api/management/workflows/${workflow}/triggers/manual','2021-03-01').queries.sig
    keyVaultName: keyVaultName
    secretName: '${logicApp.name}-${workflow}-sig'
  }
}]
