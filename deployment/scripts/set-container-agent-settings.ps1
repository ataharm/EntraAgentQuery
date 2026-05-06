#!/usr/bin/env pwsh
# Updates AI agent environment variables directly on the deployed Azure Container App.

[CmdletBinding()]
param(
    [string]$ResourceGroupName,
    [string]$ContainerAppName,
    [string]$AgentIds,
    [string]$AgentId,
    [switch]$SingleAgent,
    [switch]$ShowOnly
)

$ErrorActionPreference = "Stop"

function Get-AzdValue {
    param([string]$Name)

    $value = ""
    try {
        $value = (azd env get-value $Name 2>$null | Select-Object -First 1)
    } catch {
        $value = ""
    }

    if ($null -eq $value) { return "" }
    return $value.Trim()
}

function Show-CurrentConfig {
    param(
        [string]$ResourceGroup,
        [string]$ContainerApp
    )

    az containerapp show `
      --name $ContainerApp `
      --resource-group $ResourceGroup `
      --query "properties.template.containers[0].env[?contains(['AI_AGENT_ID','AI_AGENT_IDS'], name)].{name:name,value:value}" `
      -o table
}

if ([string]::IsNullOrWhiteSpace($ResourceGroupName)) {
    $ResourceGroupName = Get-AzdValue -Name "AZURE_RESOURCE_GROUP_NAME"
}

if ([string]::IsNullOrWhiteSpace($ContainerAppName)) {
    $ContainerAppName = Get-AzdValue -Name "AZURE_CONTAINER_APP_NAME"
}

if ([string]::IsNullOrWhiteSpace($ResourceGroupName) -or [string]::IsNullOrWhiteSpace($ContainerAppName)) {
    Write-Host "[ERROR] Missing container app coordinates." -ForegroundColor Red
    Write-Host "Provide -ResourceGroupName and -ContainerAppName, or ensure azd env has AZURE_RESOURCE_GROUP_NAME and AZURE_CONTAINER_APP_NAME." -ForegroundColor Red
    exit 1
}

Write-Host "Target resource group: $ResourceGroupName" -ForegroundColor Cyan
Write-Host "Target container app:   $ContainerAppName" -ForegroundColor Cyan

if ($ShowOnly) {
    Show-CurrentConfig -ResourceGroup $ResourceGroupName -ContainerApp $ContainerAppName
    exit 0
}

if ($SingleAgent) {
    if ([string]::IsNullOrWhiteSpace($AgentId)) {
        Write-Host "[ERROR] Single-agent mode requires -AgentId." -ForegroundColor Red
        exit 1
    }

    Write-Host "Applying single-agent mode (AI_AGENT_ID=$AgentId)..." -ForegroundColor Yellow

    az containerapp update `
      --name $ContainerAppName `
      --resource-group $ResourceGroupName `
      --set-env-vars "AI_AGENT_ID=$AgentId" `
      --remove-env-vars AI_AGENT_IDS | Out-Null
} else {
    if ([string]::IsNullOrWhiteSpace($AgentIds)) {
        Write-Host "[ERROR] Multi-agent mode requires -AgentIds (comma-separated)." -ForegroundColor Red
        exit 1
    }

    Write-Host "Applying multi-agent mode (AI_AGENT_IDS=$AgentIds)..." -ForegroundColor Yellow

    az containerapp update `
      --name $ContainerAppName `
      --resource-group $ResourceGroupName `
      --set-env-vars "AI_AGENT_IDS=$AgentIds" `
      --remove-env-vars AI_AGENT_ID | Out-Null
}

Write-Host "Updated Container App settings. Current values:" -ForegroundColor Green
Show-CurrentConfig -ResourceGroup $ResourceGroupName -ContainerApp $ContainerAppName
