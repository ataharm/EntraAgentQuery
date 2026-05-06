# Cross-Tenant Deployment Setup

This document describes the manual steps required when the Entra ID app registration lives in a **different tenant** from the Azure subscription where the app is deployed.

## Background

The normal `azd up` flow creates the Entra app registration via the Microsoft Graph Bicep extension in the same tenant as the Azure CLI login. When app registration is restricted in the deployment tenant (e.g., a corporate tenant where only admins can create apps), the app must be pre-created in a separate tenant, and `ENTRA_TENANT_ID` is set to that external tenant ID before provisioning.

In this deployment:

| | Value |
|---|---|
| **App Registration Tenant** | `cadc9f05-62ec-490e-85c9-b2fdaa77f5be` |
| **Deployment Tenant** (Azure subscription) | `cf36141c-ddd7-45a7-b073-111f66d0b30c` |
| **SPA Client ID** | `1cc91ec6-67dd-412b-b3e0-f918a53e219d` |
| **Container App URL** | `https://ca-web-zg45tevq5pmco.calmbeach-aee65426.eastus2.azurecontainerapps.io` |
| **AI Foundry Endpoint** | `https://ai-account-7ccbhxrcshh52.services.ai.azure.com/api/projects/ai-project-azdai01` |

When `ENTRA_TENANT_ID` differs from the CLI tenant, `postprovision.ps1` detects this and **skips** all Graph API calls — those steps must be completed manually as described below.

---

## Steps in the App Registration Tenant

Sign into [portal.azure.com](https://portal.azure.com) and switch to tenant `cadc9f05-62ec-490e-85c9-b2fdaa77f5be`.

### 1. Set the Application ID URI

Navigate to **App registrations** → `ai-foundry-agent-fndragntweb01` → **Expose an API**.

Set the **Application ID URI** to:
```
api://1cc91ec6-67dd-412b-b3e0-f918a53e219d
```

This is required so MSAL can resolve the audience claim in the JWT token the backend validates.

### 2. Add the Redirect URI

Navigate to **Authentication** → **Single-page application**.

Add the deployed Container App URL as a redirect URI:
```
https://ca-web-zg45tevq5pmco.calmbeach-aee65426.eastus2.azurecontainerapps.io
```

The following localhost URIs should already be present (set by Bicep):
- `http://localhost:5173`
- `http://localhost:8080`

### 3. Verify the Supported Account Type

Under **Authentication** → **Supported account types**, confirm it is set to:
> **Accounts in this organizational directory only** (`AzureADMyOrg`)

If users signing in are from the same app registration tenant (`cadc9f05-...`), this is correct. If users come from the deployment tenant (`cf36141c-...`), change this to **Multitenant**.

---

## Steps in the Deployment Tenant / Azure Subscription

These steps are performed via Azure CLI logged in to the **deployment** subscription (`2325bd62-5b46-4e08-8cc3-3451c8d9a339`).

### 4. Assign RBAC Roles to the Managed Identity

The Container App runs as a user-assigned managed identity. Read its principal ID from the active `azd` environment, derive the AI Foundry account from `AI_AGENT_ENDPOINT`, resolve its resource group in the deployment subscription, then assign roles on that AI Foundry resource:

```powershell
$principalId = azd env get-value WEB_IDENTITY_PRINCIPAL_ID
if ([string]::IsNullOrWhiteSpace($principalId)) {
  throw "WEB_IDENTITY_PRINCIPAL_ID is not set in the current azd environment."
}

$aiAgentEndpoint = azd env get-value AI_AGENT_ENDPOINT
if ([string]::IsNullOrWhiteSpace($aiAgentEndpoint)) {
  throw "AI_AGENT_ENDPOINT is not set in the current azd environment."
}

$subscriptionId = azd env get-value AZURE_SUBSCRIPTION_ID
if ([string]::IsNullOrWhiteSpace($subscriptionId)) {
  throw "AZURE_SUBSCRIPTION_ID is not set in the current azd environment."
}

try {
  $endpointUri = [Uri]$aiAgentEndpoint
} catch {
  throw "AI_AGENT_ENDPOINT is not a valid URI: $aiAgentEndpoint"
}

$aiFoundryResourceName = $endpointUri.Host -replace "\.services\.ai\.azure\.com$", ""
if ([string]::IsNullOrWhiteSpace($aiFoundryResourceName) -or $aiFoundryResourceName -eq $endpointUri.Host) {
  throw "Unable to derive AI Foundry resource name from AI_AGENT_ENDPOINT host: $($endpointUri.Host)"
}

$matches = az resource list `
  --subscription $subscriptionId `
  --resource-type Microsoft.CognitiveServices/accounts `
  --name $aiFoundryResourceName `
  --query "[].{id:id,resourceGroup:resourceGroup}" `
  -o json | ConvertFrom-Json

if ($null -eq $matches -or @($matches).Count -eq 0) {
  throw "No Cognitive Services account named '$aiFoundryResourceName' found in subscription '$subscriptionId'."
}

if (@($matches).Count -gt 1) {
  throw "Multiple Cognitive Services accounts named '$aiFoundryResourceName' found in subscription '$subscriptionId'."
}

$scope = $matches[0].id
$aiFoundryResourceGroup = $matches[0].resourceGroup

if ([string]::IsNullOrWhiteSpace($scope)) {
  throw "Unable to resolve AI Foundry resource ID for scope."
}

foreach ($role in @("Cognitive Services User", "Cognitive Services OpenAI Contributor", "Azure AI Developer")) {
    az role assignment create `
        --assignee-object-id $principalId `
        --assignee-principal-type ServicePrincipal `
        --role $role `
        --scope $scope
}
```

| Role | Purpose |
|---|---|
| `Cognitive Services User` | Data-plane access — covers `AIServices/agents/*` wildcard actions |
| `Cognitive Services OpenAI Contributor` | Model access and conversations (`OpenAI/*`) |
| `Azure AI Developer` | Agents v2 API (`SpeechServices`, `ContentSafety`, `MaaS`) |

> **Note:** These are assigned on the external AI Foundry resource resolved from `AI_AGENT_ENDPOINT`, which is **not** managed by `azd`. They survive `azd down` and do not need to be recreated unless the managed identity is replaced.

### 5. Verify Container App Environment Variables

Confirm the running Container App has the correct values:

```powershell
$containerAppName = azd env get-value AZURE_CONTAINER_APP_NAME
$resourceGroupName = azd env get-value AZURE_RESOURCE_GROUP_NAME

if ([string]::IsNullOrWhiteSpace($containerAppName) -or [string]::IsNullOrWhiteSpace($resourceGroupName)) {
  throw "AZURE_CONTAINER_APP_NAME and AZURE_RESOURCE_GROUP_NAME must be set in the current azd environment."
}

az containerapp show `
  --name $containerAppName `
  --resource-group $resourceGroupName `
  --query "properties.template.containers[0].env[?name=='AI_AGENT_ENDPOINT' || name=='AI_AGENT_ID' || name=='AI_AGENT_IDS'].{name:name,value:value}" `
  -o table
```

Expected:

| Name | Value |
|---|---|
| `AI_AGENT_ENDPOINT` | `https://ai-account-7ccbhxrcshh52.services.ai.azure.com/api/projects/ai-project-azdai01` |
| `AI_AGENT_IDS` | `summarization-agent,prompt-agent` |
| `AI_AGENT_ID` | (empty for multi-agent mode) |

If any value is wrong, update directly without a full redeploy:

```powershell
$containerAppName = azd env get-value AZURE_CONTAINER_APP_NAME
$resourceGroupName = azd env get-value AZURE_RESOURCE_GROUP_NAME

if ([string]::IsNullOrWhiteSpace($containerAppName) -or [string]::IsNullOrWhiteSpace($resourceGroupName)) {
  throw "AZURE_CONTAINER_APP_NAME and AZURE_RESOURCE_GROUP_NAME must be set in the current azd environment."
}

az containerapp update `
  --name $containerAppName `
  --resource-group $resourceGroupName `
  --set-env-vars "AI_AGENT_ENDPOINT=<value>" "AI_AGENT_IDS=<agent-1,agent-2>" "AI_AGENT_ID="
```

---

## What `azd up` Does vs. What Is Manual

| Step | Automated by `azd up` | Manual (cross-tenant) |
|---|---|---|
| Create SPA app registration | Bicep (Graph extension) | — |
| Set Application ID URI | `postprovision.ps1` (same tenant only) | **Step 1** |
| Add Container App redirect URI | `postprovision.ps1` (same tenant only) | **Step 2** |
| Assign AI Foundry RBAC roles | `postprovision.ps1` | **Step 4** (if resource group/name was wrong) |
| Set `AI_AGENT_ENDPOINT` / `AI_AGENT_ID` / `AI_AGENT_IDS` on Container App | Bicep (reads from `.env`) | **Step 5** (if `.env` was stale) |

---

## Re-running After `azd provision`

Every time `azd provision` runs (e.g., to update infrastructure), Bicep recreates the Container App revision from `.env` values. Verify:

1. `.azure/fndragntweb01/.env` has the correct `AI_AGENT_ENDPOINT`, `AI_AGENT_IDS`, `AI_AGENT_ID` (empty for multi-agent mode), `AI_FOUNDRY_RESOURCE_GROUP`, and `AI_FOUNDRY_RESOURCE_NAME`.
2. The redirect URI in the app registration tenant still includes the Container App URL (the FQDN is stable for this environment).
3. RBAC roles on `ai-account-7ccbhxrcshh52` are still present (they persist across `azd` operations).
