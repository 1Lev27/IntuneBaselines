#Requires -Version 5.1
<#
.SYNOPSIS
    Creates an Intune App Registration in a destination tenant and deploys
    Intune Configuration Profiles from local JSON files.

.DESCRIPTION
    This script performs the following steps:
      1. Authenticates as a Global Admin / Intune Admin via device code flow
      2. Creates an Azure AD App Registration with required Graph API permissions:
           - DeviceManagementConfiguration.ReadWrite.All
           - DeviceManagementApps.ReadWrite.All
           - DeviceManagementManagedDevices.ReadWrite.All
      3. Creates the corresponding Service Principal and grants admin consent
      4. Generates a client secret for the app registration
      5. Re-authenticates using the new app credentials (client credentials flow)
      6. Opens a file picker so you can select one or more local JSON baseline files
      7. Detects each profile type from the JSON and uploads it to the correct
         Microsoft Graph / Intune endpoint

.PARAMETER TenantId
    The destination tenant ID (GUID or domain, e.g. contoso.onmicrosoft.com).
    If omitted you will be prompted.

.PARAMETER AppDisplayName
    Display name for the new App Registration. Defaults to "IntuneBaselinesDeployer".

.PARAMETER SkipAppCreation
    Skip app registration creation. Supply -ClientId and -ClientSecret to use
    an existing app registration.

.PARAMETER ClientId
    Used with -SkipAppCreation. Client ID of an existing app registration.

.PARAMETER ClientSecret
    Used with -SkipAppCreation. Client secret of an existing app registration.

.EXAMPLE
    .\Deploy-IntuneBaselines.ps1 -TenantId "contoso.onmicrosoft.com"

.EXAMPLE
    .\Deploy-IntuneBaselines.ps1 -TenantId "contoso.onmicrosoft.com" `
        -SkipAppCreation -ClientId "<appId>" -ClientSecret "<secret>"
#>

[CmdletBinding()]
param (
    [string]$TenantId,
    [string]$AppDisplayName = "IntuneBaselinesDeployer",
    [switch]$SkipAppCreation,
    [string]$ClientId,
    [string]$ClientSecret
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ─── Constants ────────────────────────────────────────────────────────────────

# Well-known public client used by Microsoft Graph Command Line Tools.
# Supports device code flow without requiring a pre-registered app.
$BOOTSTRAP_CLIENT_ID = '14d82eec-204b-4c2f-b7e8-296a70dab67e'

$GRAPH_APP_ID = '00000003-0000-0000-c000-000000000000'   # Microsoft Graph
$GRAPH_BASE   = 'https://graph.microsoft.com'

$REQUIRED_PERMISSIONS = @(
    'DeviceManagementConfiguration.ReadWrite.All',
    'DeviceManagementApps.ReadWrite.All',
    'DeviceManagementManagedDevices.ReadWrite.All'
)

# odata.type prefixes → Graph endpoint
# Order matters: more-specific matches first
$PROFILE_ROUTES = [ordered]@{
    '#microsoft.graph.deviceManagementConfigurationPolicy'    = 'beta/deviceManagement/configurationPolicies'
    '#microsoft.graph.windowsAutopilotDeploymentProfile'      = 'beta/deviceManagement/windowsAutopilotDeploymentProfiles'
    '#microsoft.graph.groupPolicyConfiguration'               = 'beta/deviceManagement/groupPolicyConfigurations'
    '#microsoft.graph.deviceCompliancePolicy'                 = 'beta/deviceManagement/deviceCompliancePolicies'
    '#microsoft.graph.deviceEnrollmentConfiguration'          = 'beta/deviceManagement/deviceEnrollmentConfigurations'
    '#microsoft.graph.deviceConfiguration'                    = 'beta/deviceManagement/deviceConfigurations'
    # catch-all for any remaining known subtype prefixes
    '#microsoft.graph.'                                       = 'beta/deviceManagement/deviceConfigurations'
}

# ─── Helper functions ─────────────────────────────────────────────────────────

function Write-Header {
    param([string]$Text)
    Write-Host ""
    Write-Host "━━━  $Text  ━━━" -ForegroundColor Cyan
}

function Write-Step {
    param([string]$Text)
    Write-Host "  → $Text" -ForegroundColor White
}

function Write-Ok {
    param([string]$Text)
    Write-Host "  ✓ $Text" -ForegroundColor Green
}

function Write-Warn {
    param([string]$Text)
    Write-Host "  ⚠ $Text" -ForegroundColor Yellow
}

function Invoke-GraphRequest {
    <#
    .SYNOPSIS Thin wrapper around Invoke-RestMethod for Microsoft Graph calls.#>
    param(
        [string]$Method,
        [string]$Uri,
        $Body,
        [string]$Token,
        [switch]$Raw
    )

    $headers = @{
        Authorization  = "Bearer $Token"
        'Content-Type' = 'application/json'
    }

    $params = @{
        Method  = $Method
        Uri     = $Uri
        Headers = $headers
    }

    if ($null -ne $Body) {
        $params.Body = ($Body | ConvertTo-Json -Depth 20 -Compress)
    }

    try {
        Invoke-RestMethod @params
    }
    catch [System.Net.WebException] {
        $response = $_.Exception.Response
        if ($null -ne $response) {
            $stream = $response.GetResponseStream()
            $reader = [System.IO.StreamReader]::new($stream)
            $detail = $reader.ReadToEnd() | ConvertFrom-Json -ErrorAction SilentlyContinue
            $msg    = if ($detail.error.message) { $detail.error.message } else { $_.Exception.Message }
            throw "Graph API error ($($response.StatusCode)): $msg"
        }
        throw
    }
}

function Get-DeviceCodeToken {
    <#
    .SYNOPSIS Performs OAuth 2.0 device code flow and returns an access token.#>
    param(
        [string]$TenantId,
        [string]$ClientId,
        [string[]]$Scopes
    )

    $scopeStr = ($Scopes -join ' ') + ' offline_access'
    $tokenUrl = "https://login.microsoftonline.com/$TenantId/oauth2/v2.0"

    # Request device code
    $codeResponse = Invoke-RestMethod -Method Post -Uri "$tokenUrl/devicecode" -Body @{
        client_id = $ClientId
        scope     = $scopeStr
    }

    Write-Host ""
    Write-Host "  To sign in, open:" -ForegroundColor White
    Write-Host "    $($codeResponse.verification_uri)" -ForegroundColor Yellow
    Write-Host "  And enter code:" -ForegroundColor White
    Write-Host "    $($codeResponse.user_code)" -ForegroundColor Yellow -BackgroundColor DarkBlue
    Write-Host ""

    # Poll until the user completes auth
    $interval   = [int]$codeResponse.interval
    $expiresSec = [int]$codeResponse.expires_in
    $waited     = 0

    while ($waited -lt $expiresSec) {
        Start-Sleep -Seconds $interval
        $waited += $interval

        try {
            $tokenResponse = Invoke-RestMethod -Method Post -Uri "$tokenUrl/token" -Body @{
                grant_type  = 'urn:ietf:params:oauth:grant-type:device_code'
                client_id   = $ClientId
                device_code = $codeResponse.device_code
            }
            return $tokenResponse.access_token
        }
        catch {
            $body = $_.ErrorDetails.Message | ConvertFrom-Json -ErrorAction SilentlyContinue
            if ($body.error -eq 'authorization_pending') { continue }
            if ($body.error -eq 'slow_down') { $interval += 5; continue }
            throw "Authentication failed: $($body.error_description)"
        }
    }

    throw "Device code authentication timed out."
}

function Get-ClientCredentialToken {
    <#
    .SYNOPSIS Gets an access token using the client credentials flow.#>
    param(
        [string]$TenantId,
        [string]$ClientId,
        [string]$ClientSecret
    )

    $response = Invoke-RestMethod -Method Post `
        -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" `
        -Body @{
            grant_type    = 'client_credentials'
            client_id     = $ClientId
            client_secret = $ClientSecret
            scope         = "$GRAPH_BASE/.default"
        }

    return $response.access_token
}

function New-AppRegistration {
    <#
    .SYNOPSIS Creates an app registration and service principal, grants admin
               consent for the required application permissions, and returns
               the client ID and a freshly created client secret.#>
    param(
        [string]$DisplayName,
        [string]$AdminToken,
        [string]$TenantId
    )

    # ── Resolve Graph service principal and required app role IDs ──────────────
    Write-Step "Resolving Microsoft Graph service principal in tenant…"
    $graphSp = Invoke-GraphRequest -Method Get `
        -Uri "$GRAPH_BASE/v1.0/servicePrincipals?`$filter=appId eq '$GRAPH_APP_ID'&`$select=id,appRoles" `
        -Token $AdminToken

    $graphSpId = $graphSp.value[0].id
    $appRoles  = $graphSp.value[0].appRoles

    $requiredRoles = @()
    foreach ($permName in $REQUIRED_PERMISSIONS) {
        $role = $appRoles | Where-Object { $_.value -eq $permName }
        if (-not $role) { throw "Could not find Graph app role: $permName" }
        $requiredRoles += $role
        Write-Ok "Found permission: $permName ($($role.id))"
    }

    # ── Create the application ─────────────────────────────────────────────────
    Write-Step "Creating App Registration '$DisplayName'…"

    $requiredResourceAccess = @(
        @{
            resourceAppId  = $GRAPH_APP_ID
            resourceAccess = @(
                foreach ($role in $requiredRoles) {
                    @{ id = $role.id; type = 'Role' }  # Role = Application permission
                }
            )
        }
    )

    $appBody = @{
        displayName            = $DisplayName
        signInAudience         = 'AzureADMyOrg'
        requiredResourceAccess = $requiredResourceAccess
    }

    $app = Invoke-GraphRequest -Method Post `
        -Uri "$GRAPH_BASE/v1.0/applications" `
        -Body $appBody `
        -Token $AdminToken

    Write-Ok "App Registration created: $($app.displayName) (appId: $($app.appId))"

    # ── Create the service principal ───────────────────────────────────────────
    Write-Step "Creating Service Principal…"
    $sp = Invoke-GraphRequest -Method Post `
        -Uri "$GRAPH_BASE/v1.0/servicePrincipals" `
        -Body @{ appId = $app.appId } `
        -Token $AdminToken

    Write-Ok "Service Principal created: $($sp.id)"

    # ── Grant admin consent for each application permission ────────────────────
    Write-Step "Granting admin consent for application permissions…"
    foreach ($role in $requiredRoles) {
        $grant = @{
            principalId = $sp.id
            resourceId  = $graphSpId
            appRoleId   = $role.id
        }
        try {
            Invoke-GraphRequest -Method Post `
                -Uri "$GRAPH_BASE/v1.0/servicePrincipals/$($sp.id)/appRoleAssignments" `
                -Body $grant `
                -Token $AdminToken | Out-Null
            Write-Ok "Consented: $($role.value)"
        }
        catch {
            Write-Warn "Could not grant $($role.value): $_"
        }
    }

    # ── Create a client secret ─────────────────────────────────────────────────
    Write-Step "Creating client secret (valid 1 year)…"
    $secretBody = @{
        passwordCredential = @{
            displayName = 'IntuneBaselinesDeployer'
            endDateTime = (Get-Date).AddYears(1).ToString('o')
        }
    }
    $secretResult = Invoke-GraphRequest -Method Post `
        -Uri "$GRAPH_BASE/v1.0/applications/$($app.id)/addPassword" `
        -Body $secretBody `
        -Token $AdminToken

    Write-Ok "Client secret created (expires: $($secretResult.endDateTime))"

    return @{
        AppId        = $app.appId
        ClientSecret = $secretResult.secretText
    }
}

function Get-ODataType {
    <#
    .SYNOPSIS Extracts the @odata.type value from a policy JSON object.#>
    param($PolicyObj)

    # Common locations for the type discriminator
    if ($PolicyObj.'@odata.type')       { return $PolicyObj.'@odata.type' }
    if ($PolicyObj.templateReference)   { return '#microsoft.graph.deviceManagementConfigurationPolicy' }
    if ($PolicyObj.settingsDelta)       { return '#microsoft.graph.groupPolicyConfiguration' }

    return $null
}

function Resolve-GraphEndpoint {
    <#
    .SYNOPSIS Returns the full Graph URI for a given odata type string.#>
    param([string]$ODataType)

    foreach ($prefix in $PROFILE_ROUTES.Keys) {
        if ($ODataType -like "$prefix*") {
            return "$GRAPH_BASE/$($PROFILE_ROUTES[$prefix])"
        }
    }

    # Default fallback
    return "$GRAPH_BASE/beta/deviceManagement/deviceConfigurations"
}

function Select-JsonFiles {
    <#
    .SYNOPSIS Shows a Windows file open dialog filtered to *.json. Falls back
               to console input on non-Windows or headless sessions.#>

    $files = @()

    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        $dialog = [System.Windows.Forms.OpenFileDialog]::new()
        $dialog.Title       = "Select Intune Baseline JSON files"
        $dialog.Filter      = "JSON files (*.json)|*.json|All files (*.*)|*.*"
        $dialog.Multiselect = $true
        $dialog.InitialDirectory = $PWD.Path

        # ShowDialog needs a window handle; create a hidden owner form
        $owner = [System.Windows.Forms.Form]::new()
        $owner.TopMost = $true
        $owner.WindowState = 'Minimized'
        $owner.ShowInTaskbar = $false
        $owner.Show()
        $owner.Hide()

        $result = $dialog.ShowDialog($owner)
        $owner.Dispose()

        if ($result -eq [System.Windows.Forms.DialogResult]::OK) {
            $files = $dialog.FileNames
        }
    }
    catch {
        Write-Warn "GUI file picker unavailable. Falling back to console input."
    }

    if ($files.Count -eq 0) {
        Write-Host ""
        Write-Host "  Enter the full path(s) to your JSON baseline files." -ForegroundColor White
        Write-Host "  Press ENTER on an empty line when done." -ForegroundColor Gray
        Write-Host ""
        $list = @()
        do {
            $line = Read-Host "  File path"
            if ($line -and (Test-Path $line)) {
                $list += $line
            }
            elseif ($line) {
                Write-Warn "File not found, skipping: $line"
            }
        } while ($line)
        $files = $list
    }

    return $files
}

function Remove-ODataMetadata {
    <#
    .SYNOPSIS Strips read-only OData properties that Intune rejects on create.#>
    param($Obj)

    $readOnly = @(
        'id', 'createdDateTime', 'lastModifiedDateTime', 'version',
        'supportsScopeTags', 'roleScopeTagIds', '@odata.context',
        '@odata.etag', 'settingCount'
    )

    $clone = $Obj | ConvertTo-Json -Depth 20 | ConvertFrom-Json

    foreach ($key in $readOnly) {
        if ($clone.PSObject.Properties[$key]) {
            $clone.PSObject.Properties.Remove($key)
        }
    }

    return $clone
}

function Invoke-ProfileUpload {
    <#
    .SYNOPSIS Reads each JSON file, detects its type, and POSTs it to Intune.#>
    param(
        [string[]]$FilePaths,
        [string]$Token
    )

    $results = @{ Success = 0; Failed = 0 }

    foreach ($filePath in $FilePaths) {
        $fileName = Split-Path $filePath -Leaf
        Write-Host ""
        Write-Host "  Uploading: $fileName" -ForegroundColor White

        try {
            $raw  = Get-Content -Path $filePath -Raw -Encoding UTF8
            $json = $raw | ConvertFrom-Json

            $odataType = Get-ODataType -PolicyObj $json
            if (-not $odataType) {
                Write-Warn "Cannot determine policy type for '$fileName'. Attempting deviceConfigurations endpoint."
                $odataType = '#microsoft.graph.deviceConfiguration'
            }

            $endpoint = Resolve-GraphEndpoint -ODataType $odataType
            Write-Step "Type: $odataType"
            Write-Step "Endpoint: $endpoint"

            $cleaned = Remove-ODataMetadata -Obj $json

            $response = Invoke-GraphRequest -Method Post `
                -Uri $endpoint `
                -Body $cleaned `
                -Token $Token

            Write-Ok "Created: $($response.displayName ?? $response.name ?? $response.id)"
            $results.Success++
        }
        catch {
            Write-Warn "Failed '$fileName': $_"
            $results.Failed++
        }
    }

    return $results
}

# ─── Main ─────────────────────────────────────────────────────────────────────

Write-Host ""
Write-Host "╔══════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║   Intune Baselines Deployer              ║" -ForegroundColor Cyan
Write-Host "╚══════════════════════════════════════════╝" -ForegroundColor Cyan

# Collect Tenant ID
if (-not $TenantId) {
    Write-Host ""
    $TenantId = Read-Host "Enter destination Tenant ID (GUID or domain)"
}
if (-not $TenantId) { throw "Tenant ID is required." }

$appCredentials = $null

if ($SkipAppCreation) {
    # ── Use existing app registration ──────────────────────────────────────────
    if (-not $ClientId -or -not $ClientSecret) {
        $ClientId     = Read-Host "Enter Client ID (appId) of existing App Registration"
        $ClientSecret = Read-Host "Enter Client Secret"
    }
    $appCredentials = @{ AppId = $ClientId; ClientSecret = $ClientSecret }
}
else {
    # ── Phase 1: Admin bootstrap auth ──────────────────────────────────────────
    Write-Header "Step 1 of 4 — Admin Authentication"
    Write-Host "  Sign in with a Global Admin or Intune Admin account." -ForegroundColor Gray

    $adminScopes = @(
        'Application.ReadWrite.All',
        'AppRoleAssignment.ReadWrite.All',
        'Directory.ReadWrite.All'
    )

    $adminToken = Get-DeviceCodeToken `
        -TenantId  $TenantId `
        -ClientId  $BOOTSTRAP_CLIENT_ID `
        -Scopes    $adminScopes

    Write-Ok "Admin authenticated."

    # ── Phase 2: Create App Registration ──────────────────────────────────────
    Write-Header "Step 2 of 4 — Creating App Registration"

    $appCredentials = New-AppRegistration `
        -DisplayName $AppDisplayName `
        -AdminToken  $adminToken `
        -TenantId    $TenantId

    Write-Host ""
    Write-Host "  ┌─────────────────────────────────────────────────────────────┐" -ForegroundColor Green
    Write-Host "  │  App Registration Details (save these somewhere safe)        │" -ForegroundColor Green
    Write-Host "  │                                                               │" -ForegroundColor Green
    Write-Host "  │  Tenant ID     : $TenantId" -ForegroundColor Green
    Write-Host "  │  Client ID     : $($appCredentials.AppId)" -ForegroundColor Green
    Write-Host "  │  Client Secret : $($appCredentials.ClientSecret)" -ForegroundColor Green
    Write-Host "  │                                                               │" -ForegroundColor Green
    Write-Host "  └─────────────────────────────────────────────────────────────┘" -ForegroundColor Green
}

# ── Phase 3: App authentication ────────────────────────────────────────────────
Write-Header "Step 3 of 4 — Authenticating as App"
Write-Step "Acquiring token using client credentials…"

$appToken = Get-ClientCredentialToken `
    -TenantId    $TenantId `
    -ClientId    $appCredentials.AppId `
    -ClientSecret $appCredentials.ClientSecret

Write-Ok "App token acquired."

# ── Phase 4: Select and upload JSON baselines ──────────────────────────────────
Write-Header "Step 4 of 4 — Select and Upload Intune Baselines"
Write-Host "  Select the JSON baseline files you want to upload." -ForegroundColor Gray

$selectedFiles = Select-JsonFiles

if ($selectedFiles.Count -eq 0) {
    Write-Warn "No files selected. Exiting."
    exit 0
}

Write-Step "Selected $($selectedFiles.Count) file(s)."

$results = Invoke-ProfileUpload -FilePaths $selectedFiles -Token $appToken

Write-Host ""
Write-Host "━━━  Upload Complete  ━━━" -ForegroundColor Cyan
Write-Host "  Succeeded : $($results.Success)" -ForegroundColor Green
Write-Host "  Failed    : $($results.Failed)" -ForegroundColor $(if ($results.Failed -gt 0) {'Red'} else {'Green'})
Write-Host ""
