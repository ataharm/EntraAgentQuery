targetScope = 'subscription'

// Force re-deployment after resource group deletion
@minLength(1)
@maxLength(64)
@description('Name of the environment (e.g., dev, prod)')
param environmentName string

@minLength(1)
@description('Primary location for all resources')
param location string

@description('AI Agent endpoint (auto-discovered by preprovision hook)')
param aiAgentEndpoint string = ''

@description('AI Agent ID (configured via azd env set AI_AGENT_ID)')
param aiAgentId string = ''

@description('Entra ID Tenant ID (set by azd hook or auto-detected)')
param entraTenantId string = tenant().tenantId

@description('Service Management Reference GUID (required by some orgs for Entra app registration)')
param serviceManagementReference string = ''

@description('Enable OBO (On-Behalf-Of) flow for user-delegated access to Agent Service (secretless via FIC)')
param enableObo bool = false

@description('Pre-existing Entra SPA app client ID. When provided, skips Graph Bicep module (use in tenants that restrict programmatic app registration).')
param entraSpaClientId string = ''

@description('Container image for web service (set by postprovision hook)')
param webImageName string = 'mcr.microsoft.com/k8se/quickstart:latest'  // Placeholder during initial provision

@description('Default tags applied by Azure Policy (optional)')
param defaultTags object = {}

var abbrs = loadJsonContent('./abbreviations.json')
var resourceToken = toLower(uniqueString(subscription().id, environmentName, location))
var appTags = {
  'azd-env-name': environmentName
  'app-name': 'ai-foundry-agent'
}

var tags = union(defaultTags, appTags)

resource rg 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: '${abbrs.resourcesResourceGroups}${environmentName}'
  location: location
  tags: tags
}

// Deploy infrastructure (ACR + Container Apps Environment)
module infrastructure 'main-infrastructure.bicep' = {
  name: 'infrastructure'
  scope: rg
  params: {
    location: location
    tags: tags
    resourceToken: resourceToken
  }
}

// Create Entra app registration (Microsoft Graph Bicep extension)
// Creates with localhost-only redirect URIs; postprovision adds Container App FQDN + FIC
// Skip when entraSpaClientId is provided (use in tenants that restrict programmatic app registration)
module entraApp 'entra-app.bicep' = if (empty(entraSpaClientId)) {
  name: 'entra-app'
  scope: rg
  params: {
    environmentName: environmentName
    serviceManagementReference: serviceManagementReference
    enableObo: enableObo
  }
}

// Resolve the SPA client ID: use the pre-existing one if provided, otherwise use the Bicep-created one
var resolvedSpaClientId = !empty(entraSpaClientId) ? entraSpaClientId : entraApp.outputs.clientAppId
var resolvedAppObjectId = !empty(entraSpaClientId) ? '' : entraApp.outputs.appObjectId
var resolvedBackendClientId = !empty(entraSpaClientId) ? '' : (enableObo ? entraApp.outputs.backendClientAppId : '')
var resolvedBackendAppObjectId = !empty(entraSpaClientId) ? '' : (enableObo ? entraApp.outputs.backendAppObjectId : '')

// Deploy application (Container Apps + RBAC)
module app 'main-app.bicep' = {
  name: 'app'
  scope: rg
  params: {
    location: location
    tags: tags
    resourceToken: resourceToken
    containerAppsEnvironmentId: infrastructure.outputs.containerAppsEnvironmentId
    containerRegistryName: infrastructure.outputs.containerRegistryName
    aiAgentEndpoint: aiAgentEndpoint
    aiAgentId: aiAgentId
    entraSpaClientId: resolvedSpaClientId
    entraTenantId: entraTenantId
    entraBackendClientId: resolvedBackendClientId
    webImageName: webImageName
    userAssignedIdentityId: infrastructure.outputs.managedIdentityId
    oboManagedIdentityClientId: infrastructure.outputs.managedIdentityClientId
    appInsightsConnectionString: infrastructure.outputs.appInsightsConnectionString
    appInsightsFrontendConnectionString: infrastructure.outputs.appInsightsFrontendConnectionString
  }
}

// Note: Role assignment to AI Foundry resource is done via Azure CLI in postprovision.ps1
// This avoids azd tracking the external resource group and deleting it on 'azd down'

output AZURE_CONTAINER_REGISTRY_ENDPOINT string = infrastructure.outputs.containerRegistryLoginServer
output AZURE_CONTAINER_REGISTRY_NAME string = infrastructure.outputs.containerRegistryName
output AZURE_CONTAINER_APPS_ENVIRONMENT_ID string = infrastructure.outputs.containerAppsEnvironmentId
output AZURE_RESOURCE_GROUP_NAME string = rg.name
output AZURE_CONTAINER_APP_NAME string = app.outputs.webAppName
output WEB_ENDPOINT string = app.outputs.webEndpoint
output WEB_IDENTITY_PRINCIPAL_ID string = infrastructure.outputs.managedIdentityPrincipalId
output ENTRA_SPA_CLIENT_ID string = resolvedSpaClientId
output ENTRA_APP_OBJECT_ID string = resolvedAppObjectId
output ENTRA_BACKEND_CLIENT_ID string = resolvedBackendClientId
output ENTRA_BACKEND_APP_OBJECT_ID string = resolvedBackendAppObjectId
output APPLICATIONINSIGHTS_CONNECTION_STRING string = infrastructure.outputs.appInsightsConnectionString
output APPLICATIONINSIGHTS_FRONTEND_CONNECTION_STRING string = infrastructure.outputs.appInsightsFrontendConnectionString
