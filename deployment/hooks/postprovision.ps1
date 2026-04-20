#!/usr/bin/env pwsh
# Post-provision: Configures Entra app (identifierUri + redirect URIs), assigns RBAC, generates local dev config
# The Entra app itself is created declaratively by Bicep (infra/entra-app.bicep)

$ErrorActionPreference = "Stop"
. "$PSScriptRoot/modules/HookLogging.ps1"
Start-HookLog -HookName "postprovision" -EnvironmentName $env:AZURE_ENV_NAME

Write-Host "Post-Provision: Configure Entra App, RBAC & Local Config" -ForegroundColor Cyan

# Get required env vars (ENTRA_SPA_CLIENT_ID is now a Bicep output)
$clientId = azd env get-value ENTRA_SPA_CLIENT_ID 2>$null
$containerAppUrl = azd env get-value WEB_ENDPOINT 2>$null
$webIdentityPrincipalId = azd env get-value WEB_IDENTITY_PRINCIPAL_ID 2>$null
$aiFoundryResourceGroup = azd env get-value AI_FOUNDRY_RESOURCE_GROUP 2>$null
$aiFoundryResourceName = azd env get-value AI_FOUNDRY_RESOURCE_NAME 2>$null
$subscriptionId = azd env get-value AZURE_SUBSCRIPTION_ID 2>$null
$tenantId = azd env get-value ENTRA_TENANT_ID 2>$null

if (-not $clientId) {
    Write-Host "[ERROR] ENTRA_SPA_CLIENT_ID not set (should be output from Bicep)" -ForegroundColor Red
    exit 1
}
if (-not $containerAppUrl) {
    Write-Host "[ERROR] WEB_ENDPOINT not set" -ForegroundColor Red
    exit 1
}

Write-Host "[OK] Client ID: $clientId (from Bicep)" -ForegroundColor Green
Write-Host "[OK] Container App: $containerAppUrl" -ForegroundColor Green

# Detect if the Entra app is in a different tenant from the Azure CLI context.
# This happens when app registrations are restricted in the deployment tenant and the
# app was pre-created in a separate tenant (set via: azd env set ENTRA_TENANT_ID <id>).
$cliTenantId = az account show --query tenantId -o tsv 2>$null
$isExternalEntraTenant = $tenantId -and $cliTenantId -and ($tenantId -ne $cliTenantId)

if ($isExternalEntraTenant) {
    Write-Host "[SKIP] Entra app update — app ($clientId) is in external tenant $tenantId" -ForegroundColor Yellow
    Write-Host "[!] Complete these steps manually in https://portal.azure.com (tenant $tenantId):" -ForegroundColor Yellow
    Write-Host "    1. Open App registrations → $clientId" -ForegroundColor White
    Write-Host "    2. Authentication → Add redirect URI (SPA): $containerAppUrl" -ForegroundColor White
    Write-Host "    3. Expose an API → Set Application ID URI to: api://$clientId" -ForegroundColor White
} else {
    # Set identifierUri and update redirect URIs on Entra app
    # identifierUri can't be set in Bicep because it references the auto-generated appId
    $app = az ad app show --id $clientId | ConvertFrom-Json
    $objectId = $app.id
    $identifierUri = "api://$clientId"

    $patchBody = @{
        identifierUris = @($identifierUri)
        spa = @{
            redirectUris = @(
                "http://localhost:8080",
                "http://localhost:5173",
                $containerAppUrl
            )
        }
    } | ConvertTo-Json -Depth 10

    $tempFile = [System.IO.Path]::GetTempFileName()
    $patchBody | Out-File -FilePath $tempFile -Encoding utf8

    az rest --method PATCH `
        --uri "https://graph.microsoft.com/v1.0/applications/$objectId" `
        --headers "Content-Type=application/json" `
        --body "@$tempFile" | Out-Null

    Remove-Item $tempFile -EA SilentlyContinue

    if ($LASTEXITCODE -ne 0) {
        Write-Host "[ERROR] Failed to update Entra app" -ForegroundColor Red
        exit 1
    }

    Write-Host "[OK] Identifier URI: $identifierUri" -ForegroundColor Green
    Write-Host "[OK] Redirect URIs updated" -ForegroundColor Green
}

# OBO: Bicep creates backend app registration + service principal + requiredResourceAccess.
# FIC + identifierUri + admin consent are handled here (not Bicep) because Graph API
# eventual consistency causes child resources to fail when the parent app hasn't replicated yet.
$backendClientId = azd env get-value ENTRA_BACKEND_CLIENT_ID 2>$null
if ($backendClientId) {
    Write-Host "OBO: Configuring backend app ($backendClientId)..." -ForegroundColor Yellow
    
    $backendObjectId = az ad app show --id $backendClientId --query "id" -o tsv 2>$null
    
    # Set identifierUri on backend app (required for scope resolution)
    az ad app update --id $backendClientId --identifier-uris "api://$backendClientId" 2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "[ERROR] Failed to set identifierUri on backend app — OBO will not work" -ForegroundColor Red
        exit 1
    }
    
    # Create Federated Identity Credential (MI → backend app, secretless OBO)
    $existingFic = az ad app federated-credential list --id $backendObjectId --query "[?name=='container-app-mi-fic']" 2>$null | ConvertFrom-Json
    if ($existingFic -and $existingFic.Count -gt 0) {
        Write-Host "[OK] FIC already exists" -ForegroundColor Green
    } else {
        $ficBody = @{
            name = "container-app-mi-fic"
            issuer = "https://login.microsoftonline.com/$tenantId/v2.0"
            subject = $webIdentityPrincipalId
            audiences = @("api://AzureADTokenExchange")
            description = "User-assigned managed identity for secretless OBO"
        } | ConvertTo-Json
        $ficFile = [System.IO.Path]::GetTempFileName()
        try {
            $ficBody | Out-File -FilePath $ficFile -Encoding utf8
            az ad app federated-credential create --id $backendObjectId --parameters $ficFile 2>$null | Out-Null
            if ($LASTEXITCODE -ne 0) {
                Write-Host "[ERROR] FIC creation failed — OBO will not work without it" -ForegroundColor Red
                Write-Host "  Create manually: az ad app federated-credential create --id $backendObjectId --parameters <json>"
                exit 1
            }
            Write-Host "[OK] FIC created (MI → backend app)" -ForegroundColor Green
        } finally {
            Remove-Item $ficFile -ErrorAction SilentlyContinue
        }
    }
    
    # Grant admin consent (best-effort — may require Entra admin)
    $backendSpId = az ad sp show --id $backendClientId --query "id" -o tsv 2>$null
    $spaSpId = az ad sp show --id $clientId --query "id" -o tsv 2>$null
    if ($backendSpId -and $spaSpId) {
        $existingConsent = az rest --method GET --url "https://graph.microsoft.com/v1.0/oauth2PermissionGrants?`$filter=clientId eq '$spaSpId' and resourceId eq '$backendSpId'" --query "value[0].id" -o tsv 2>$null
        if (-not $existingConsent) {
            $consentBody = @{ clientId = $spaSpId; consentType = "AllPrincipals"; resourceId = $backendSpId; scope = "Chat.ReadWrite" } | ConvertTo-Json
            $consentFile = [System.IO.Path]::GetTempFileName()
            try {
                $consentBody | Out-File -FilePath $consentFile -Encoding utf8
                az rest --method POST --url "https://graph.microsoft.com/v1.0/oauth2PermissionGrants" --body "@$consentFile" --headers "Content-Type=application/json" 2>$null | Out-Null
                if ($LASTEXITCODE -eq 0) {
                    Write-Host "[OK] Admin consent granted" -ForegroundColor Green
                } else {
                    Write-Host "[WARN] Admin consent failed — an Entra admin must grant consent" -ForegroundColor Yellow
                    Write-Host "  az ad app permission admin-consent --id $backendClientId"
                }
            } finally {
                Remove-Item $consentFile -ErrorAction SilentlyContinue
            }
        } else {
            Write-Host "[OK] Admin consent already exists" -ForegroundColor Green
        }
    }
    
    Write-Host "[OK] OBO configuration complete" -ForegroundColor Green
}

# Assign RBAC roles to web managed identity on AI Foundry resource
# - Cognitive Services User: wildcard data action (covers AIServices/agents/*)
# - Cognitive Services OpenAI Contributor: model access, conversations (OpenAI/*)
# - Azure AI Developer: v2 agents API (SpeechServices, ContentSafety, MaaS)
# Done via CLI (not Bicep) to prevent azd from tracking the external resource group
if ($webIdentityPrincipalId -and $aiFoundryResourceGroup -and $aiFoundryResourceName -and $subscriptionId) {
    Write-Host "Assigning AI Foundry RBAC roles to web app identity..." -ForegroundColor Yellow
    
    $scope = "/subscriptions/$subscriptionId/resourceGroups/$aiFoundryResourceGroup/providers/Microsoft.CognitiveServices/accounts/$aiFoundryResourceName"
    
    $roles = @("Cognitive Services User", "Cognitive Services OpenAI Contributor", "Azure AI Developer")
    foreach ($roleName in $roles) {
        $existingAssignment = az role assignment list `
            --assignee $webIdentityPrincipalId `
            --role $roleName `
            --scope $scope 2>$null | ConvertFrom-Json
        
        if ($existingAssignment -and $existingAssignment.Count -gt 0) {
            Write-Host "[OK] $roleName — already assigned" -ForegroundColor Green
        } else {
            az role assignment create `
                --assignee-object-id $webIdentityPrincipalId `
                --assignee-principal-type ServicePrincipal `
                --role $roleName `
                --scope $scope | Out-Null
            
            if ($LASTEXITCODE -eq 0) {
                Write-Host "[OK] $roleName — assigned" -ForegroundColor Green
            } else {
                Write-Host "[WARN] $roleName — failed (you may need to assign manually)" -ForegroundColor Yellow
            }
        }
    }
} else {
    Write-Host "[SKIP] AI Foundry role assignment - missing configuration" -ForegroundColor Yellow
    Write-Host "  Set AI_FOUNDRY_RESOURCE_GROUP and AI_FOUNDRY_RESOURCE_NAME environment variables" -ForegroundColor Gray
}

# Generate local dev config files (moved from preprovision — clientId comes from Bicep)
$aiAgentEndpoint = azd env get-value AI_AGENT_ENDPOINT 2>$null
$aiAgentId = azd env get-value AI_AGENT_ID 2>$null
$aiAgentVersion = azd env get-value AI_AGENT_VERSION 2>$null

# Frontend .env.local
$frontendEnv = @"
# Auto-generated - Do not commit
VITE_ENTRA_SPA_CLIENT_ID=$clientId
VITE_ENTRA_TENANT_ID=$tenantId
"@
if ($backendClientId) {
    $frontendEnv += "`nVITE_ENTRA_BACKEND_CLIENT_ID=$backendClientId"
}
$frontendEnv | Out-File -FilePath "frontend/.env.local" -Encoding utf8 -Force

# Backend .env
$backendEnvContent = @"
# Auto-generated - Do not commit
AzureAd__Instance=https://login.microsoftonline.com/
AzureAd__TenantId=$tenantId
AzureAd__ClientId=$clientId
AzureAd__Audience=api://$clientId
AI_AGENT_ENDPOINT=$aiAgentEndpoint
AI_AGENT_ID=$aiAgentId
"@
if ($aiAgentVersion) {
    $backendEnvContent += "`nAI_AGENT_VERSION=$aiAgentVersion"
}
$backendEnvContent | Out-File -FilePath "backend/WebApp.Api/.env" -Encoding utf8 -Force

Write-Host "[OK] Local dev config created" -ForegroundColor Green

# Open browser
try { Start-Process $containerAppUrl } catch { }

Write-Host "[OK] Post-provision complete. URL: $containerAppUrl" -ForegroundColor Green

if ($script:HookLogFile) {
    Write-Host "[LOG] Log file: $script:HookLogFile" -ForegroundColor DarkGray
}
Stop-HookLog
