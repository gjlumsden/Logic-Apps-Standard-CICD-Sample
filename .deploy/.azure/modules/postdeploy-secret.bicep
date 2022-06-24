@secure()
param signature string
param keyVaultName string
param secretName string

resource keyVault 'Microsoft.KeyVault/vaults@2021-11-01-preview' existing = {
  name: keyVaultName
}

resource workflowSignatureSecret 'Microsoft.KeyVault/vaults/secrets@2021-11-01-preview' = {
  name: secretName
  parent: keyVault
  properties: {
    value: signature
  }
}

