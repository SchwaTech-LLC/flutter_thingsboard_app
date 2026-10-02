[CmdletBinding()]
param(
    [string]$ConfigPath = "config\thingsboard.local.json"
)

$ErrorActionPreference = "Stop"
$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$resolvedConfigPath = Join-Path $repositoryRoot $ConfigPath

if (-not (Test-Path -LiteralPath $resolvedConfigPath -PathType Leaf)) {
    throw "Configuration file not found: $resolvedConfigPath. Copy config\thingsboard.local.example.json to config\thingsboard.local.json and edit it first."
}

$config = Get-Content -LiteralPath $resolvedConfigPath -Raw | ConvertFrom-Json
$endpoint = [string]$config.thingsboardApiEndpoint

if ([string]::IsNullOrWhiteSpace($endpoint)) {
    throw "thingsboardApiEndpoint is required in $ConfigPath."
}

try {
    $endpointUri = [Uri]$endpoint
} catch {
    throw "thingsboardApiEndpoint is not a valid absolute URL: $endpoint"
}

if (-not $endpointUri.IsAbsoluteUri -or @("http", "https") -notcontains $endpointUri.Scheme.ToLowerInvariant()) {
    throw "thingsboardApiEndpoint must be an absolute http:// or https:// URL: $endpoint"
}

$iosApplicationId = [string]$config.iosApplicationId
$iosApplicationName = [string]$config.iosApplicationName
$appLinksHost = [string]$config.appLinksUrlHost

if ([string]::IsNullOrWhiteSpace($iosApplicationId)) {
    $iosApplicationId = [string]$config.androidApplicationId
}
if ([string]::IsNullOrWhiteSpace($iosApplicationName)) {
    $iosApplicationName = [string]$config.androidApplicationName
}
if ([string]::IsNullOrWhiteSpace($appLinksHost)) {
    $appLinksHost = $endpointUri.Host
}

$iosConfigPath = Join-Path $repositoryRoot "ios\Flutter\AppConfig.xcconfig"
$iosConfig = @(
    "// Generated from $ConfigPath by tool/prepare-thingsboard.ps1. Do not commit."
    "IOSAPPLICATIONID=$iosApplicationId"
    "IOSAPPLICATIONNAME=$iosApplicationName"
    "APPLINKSURLHOST=$appLinksHost"
)
Set-Content -LiteralPath $iosConfigPath -Value $iosConfig -Encoding utf8

Write-Host "Prepared local ThingsBoard configuration."
Write-Host "Endpoint: $endpoint"
Write-Host "Generated: $iosConfigPath"
Write-Host "Use --dart-define-from-file=$ConfigPath with Flutter commands."
