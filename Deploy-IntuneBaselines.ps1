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
    [string]$AppDisplayName = 'IntuneBaselinesDeployer',
    [switch]$SkipAppCreation,
    [string]$ClientId,
    [string]$ClientSecret
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

# Well-known public client used by Microsoft Graph Command Line Tools.
# Supports device code flow without requiring a pre-registered app.
$BOOTSTRAP_CLIENT_ID = '14d82eec-204b-4c2f-b7e8-296a70dab67e'

$GRAPH_APP_ID = '00000003-0000-0000-c000-000000000000'
$GRAPH_BASE   = 'https://graph.microsoft.com'

$REQUIRED_PERMISSIONS = @(
    'DeviceManagementConfiguration.ReadWrite.All',
    'DeviceManagementApps.ReadWrite.All',
    'DeviceManagementManagedDevices.ReadWrite.All'
)

# odata.type prefix -> relative Graph path (more specific first)
$PROFILE_ROUTE_KEYS = @(
    '#microsoft.graph.deviceManagementConfigurationPolicy',
    '#microsoft.graph.windowsAutopilotDeploymentProfile',
    '#microsoft.graph.groupPolicyConfiguration',
    '#microsoft.graph.deviceCompliancePolicy',
    '#microsoft.graph.deviceEnrollmentConfiguration',
    '#microsoft.graph.deviceConfiguration',
    '#microsoft.graph.'
)

$PROFILE_ROUTE_VALUES = @{
    '#microsoft.graph.deviceManagementConfigurationPolicy' = 'beta/deviceManagement/configurationPolicies'
    '#microsoft.graph.windowsAutopilotDeploymentProfile'   = 'beta/deviceManagement/windowsAutopilotDeploymentProfiles'
    '#microsoft.graph.groupPolicyConfiguration'            = 'beta/deviceManagement/groupPolicyConfigurations'
    '#microsoft.graph.deviceCompliancePolicy'              = 'beta/deviceManagement/deviceCompliancePolicies'
    '#microsoft.graph.deviceEnrollmentConfiguration'       = 'beta/deviceManagement/deviceEnrollmentConfigurations'
    '#microsoft.graph.deviceConfiguration'                 = 'beta/deviceManagement/deviceConfigurations'
    '#microsoft.graph.'                                    = 'beta/deviceManagement/deviceConfigurations'
}

# ---------------------------------------------------------------------------
# Helper functions
# ---------------------------------------------------------------------------

function Write-Header {
    param([string]$Text)
    Write-Host ''
    Write-Host "---  $Text  ---" -ForegroundColor Cyan
}

function Write-Step {
    param([string]$Text)
    Write-Host "  -> $Text" -ForegroundColor White
}

function Write-Ok {
    param([string]$Text)
    Write-Host "  OK $Text" -ForegroundColor Green
}

function Write-Warn {
    param([string]$Text)
    Write-Host "  !! $Text" -ForegroundColor Yellow
}

function Invoke-GraphRequest {
    param(
        [string]$Method,
        [string]$Uri,
        $Body,
        [string]$Token
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
    catch {
        $detail = $null
        if ($_.Exception.Response) {
            try {
                $stream = $_.Exception.Response.GetResponseStream()
                $reader = New-Object System.IO.StreamReader($stream)
                $detail = $reader.ReadToEnd() | ConvertFrom-Json
            }
            catch { }
        }

        if ($detail -and $detail.error -and $detail.error.message) {
            throw "Graph API error: $($detail.error.message)"
        }
        throw
    }
}

function Get-DeviceCodeToken {
    param(
        [string]$TenantId,
        [string]$ClientId,
        [string[]]$Scopes
    )

    $scopeStr = ($Scopes -join ' ') + ' offline_access'
    $tokenUrl = "https://login.microsoftonline.com/$TenantId/oauth2/v2.0"

    $codeResponse = Invoke-RestMethod -Method Post -Uri "$tokenUrl/devicecode" -Body @{
        client_id = $ClientId
        scope     = $scopeStr
    }

    Write-Host ''
    Write-Host '  To sign in, open:' -ForegroundColor White
    Write-Host "    $($codeResponse.verification_uri)" -ForegroundColor Yellow
    Write-Host '  And enter code:' -ForegroundColor White
    Write-Host "    $($codeResponse.user_code)" -ForegroundColor Yellow
    Write-Host ''

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
            $body = $null
            try { $body = ($_.ErrorDetails.Message | ConvertFrom-Json) } catch { }

            if ($body -and $body.error -eq 'authorization_pending') { continue }
            if ($body -and $body.error -eq 'slow_down') { $interval += 5; continue }

            $errMsg = if ($body -and $body.error_description) { $body.error_description } else { $_.Exception.Message }
            throw "Authentication failed: $errMsg"
        }
    }

    throw 'Device code authentication timed out.'
}

function Get-ClientCredentialToken {
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
    param(
        [string]$DisplayName,
        [string]$AdminToken,
        [string]$TenantId
    )

    # Resolve Graph service principal to get dynamic app role GUIDs
    Write-Step 'Resolving Microsoft Graph service principal in tenant...'

    # Build URI separately so PS 5.1 does not misparse the & character
    $spUri = 'https://graph.microsoft.com/v1.0/servicePrincipals?$filter=appId eq ''{0}''&$select=id,appRoles' -f $GRAPH_APP_ID

    $graphSp   = Invoke-GraphRequest -Method Get -Uri $spUri -Token $AdminToken
    $graphSpId = $graphSp.value[0].id
    $appRoles  = $graphSp.value[0].appRoles

    $requiredRoles = @()
    foreach ($permName in $REQUIRED_PERMISSIONS) {
        $role = $appRoles | Where-Object { $_.value -eq $permName }
        if (-not $role) { throw "Could not find Graph app role: $permName" }
        $requiredRoles += $role
        Write-Ok "Found permission: $permName"
    }

    # Build requiredResourceAccess array
    $resourceAccess = @()
    foreach ($role in $requiredRoles) {
        $resourceAccess += @{ id = $role.id; type = 'Role' }
    }

    $requiredResourceAccess = @(
        @{
            resourceAppId  = $GRAPH_APP_ID
            resourceAccess = $resourceAccess
        }
    )

    # Create the application
    Write-Step "Creating App Registration '$DisplayName'..."
    $appBody = @{
        displayName            = $DisplayName
        signInAudience         = 'AzureADMyOrg'
        requiredResourceAccess = $requiredResourceAccess
    }

    $app = Invoke-GraphRequest -Method Post `
        -Uri "$GRAPH_BASE/v1.0/applications" `
        -Body $appBody `
        -Token $AdminToken

    Write-Ok "App Registration created (appId: $($app.appId))"

    # Create service principal
    Write-Step 'Creating Service Principal...'
    $sp = Invoke-GraphRequest -Method Post `
        -Uri "$GRAPH_BASE/v1.0/servicePrincipals" `
        -Body @{ appId = $app.appId } `
        -Token $AdminToken

    Write-Ok "Service Principal created: $($sp.id)"

    # Grant admin consent for each application permission
    Write-Step 'Granting admin consent for application permissions...'
    foreach ($role in $requiredRoles) {
        $grant = @{
            principalId = $sp.id
            resourceId  = $graphSpId
            appRoleId   = $role.id
        }
        try {
            $assignUri = "$GRAPH_BASE/v1.0/servicePrincipals/$($sp.id)/appRoleAssignments"
            Invoke-GraphRequest -Method Post -Uri $assignUri -Body $grant -Token $AdminToken | Out-Null
            Write-Ok "Consented: $($role.value)"
        }
        catch {
            Write-Warn "Could not grant $($role.value): $_"
        }
    }

    # Create client secret (1-year expiry)
    Write-Step 'Creating client secret (valid 1 year)...'
    $expiry = (Get-Date).AddYears(1).ToString('o')
    $secretBody = @{
        passwordCredential = @{
            displayName = 'IntuneBaselinesDeployer'
            endDateTime = $expiry
        }
    }
    $secretUri    = "$GRAPH_BASE/v1.0/applications/$($app.id)/addPassword"
    $secretResult = Invoke-GraphRequest -Method Post -Uri $secretUri -Body $secretBody -Token $AdminToken

    Write-Ok "Client secret created."

    return @{
        AppId        = $app.appId
        ClientSecret = $secretResult.secretText
    }
}

function Get-ODataType {
    param($PolicyObj)

    # Use PSObject.Properties for StrictMode-safe access (no throw on missing key)
    $props = $PolicyObj.PSObject.Properties

    $typeProp = $props['@odata.type']
    if ($typeProp -and $typeProp.Value) { return $typeProp.Value }

    # Settings Catalog: has templateReference or platforms+technologies+settings
    if ($props['templateReference'] -and $props['templateReference'].Value) {
        return '#microsoft.graph.deviceManagementConfigurationPolicy'
    }
    if ($props['platforms'] -and $props['technologies'] -and $props['settings']) {
        return '#microsoft.graph.deviceManagementConfigurationPolicy'
    }

    # ADMX / Group Policy configuration
    if ($props['settingsDelta']) {
        return '#microsoft.graph.groupPolicyConfiguration'
    }

    return $null
}

function Resolve-GraphEndpoint {
    param([string]$ODataType)

    # Exact-prefix matching (table entries ordered most-specific first)
    foreach ($prefix in $PROFILE_ROUTE_KEYS) {
        if ($ODataType -like "$prefix*") {
            return "$GRAPH_BASE/$($PROFILE_ROUTE_VALUES[$prefix])"
        }
    }

    # Suffix-based fallback: compliance policy subtypes all end in 'CompliancePolicy'
    # e.g. windows10CompliancePolicy, androidCompliancePolicy, macOSCompliancePolicy
    if ($ODataType -like '*CompliancePolicy') {
        return "$GRAPH_BASE/beta/deviceManagement/deviceCompliancePolicies"
    }

    # Autopilot profile subtypes (azureAD*, activeDirectory*)
    if ($ODataType -like '*AutopilotDeploymentProfile') {
        return "$GRAPH_BASE/beta/deviceManagement/windowsAutopilotDeploymentProfiles"
    }

    return "$GRAPH_BASE/beta/deviceManagement/deviceConfigurations"
}

function Select-JsonFiles {
    $files = @()

    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop

        $dialog = New-Object System.Windows.Forms.OpenFileDialog
        $dialog.Title       = 'Select Intune Baseline JSON files'
        $dialog.Filter      = 'JSON files (*.json)|*.json|All files (*.*)|*.*'
        $dialog.Multiselect = $true
        $dialog.InitialDirectory = $PWD.Path

        # Hidden owner form keeps the dialog in front
        $owner = New-Object System.Windows.Forms.Form
        $owner.TopMost      = $true
        $owner.WindowState  = 'Minimized'
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
        Write-Warn 'GUI file picker unavailable. Falling back to console input.'
    }

    if ($files.Count -eq 0) {
        Write-Host ''
        Write-Host '  Enter the full path(s) to your JSON baseline files.' -ForegroundColor White
        Write-Host '  Press ENTER on an empty line when done.' -ForegroundColor Gray
        Write-Host ''

        $list = New-Object System.Collections.Generic.List[string]
        do {
            $line = Read-Host '  File path'
            if ($line -and (Test-Path $line)) {
                $list.Add($line)
            }
            elseif ($line) {
                Write-Warn "File not found, skipping: $line"
            }
        } while ($line)

        $files = $list.ToArray()
    }

    return $files
}

function Remove-ODataMetadata {
    param($Obj)

    $readOnly = @(
        # Standard read-only Graph fields
        'id', 'createdDateTime', 'lastModifiedDateTime', 'version',
        'supportsScopeTags', 'roleScopeTagIds', '@odata.context', '@odata.etag',
        # configurationPolicy extras
        'settingCount', 'isAssigned',
        # Navigation property links — Graph rejects these on create/update
        'settingDefinitions', 'assignments', 'scheduledActionsForRule'
    )

    # Round-trip through JSON to get a plain PSObject we can mutate
    $clone = $Obj | ConvertTo-Json -Depth 20 | ConvertFrom-Json

    foreach ($key in $readOnly) {
        if ($clone.PSObject.Properties[$key]) {
            $clone.PSObject.Properties.Remove($key)
        }
    }

    return $clone
}

function Invoke-ProfileUpload {
    param(
        [string[]]$FilePaths,
        [string]$Token
    )

    $success = 0
    $failed  = 0

    foreach ($filePath in $FilePaths) {
        $fileName = Split-Path $filePath -Leaf
        Write-Host ''
        Write-Host "  Uploading: $fileName" -ForegroundColor White

        try {
            $raw  = Get-Content -Path $filePath -Raw -Encoding UTF8
            $json = $raw | ConvertFrom-Json

            $odataType = Get-ODataType -PolicyObj $json
            if (-not $odataType) {
                Write-Warn "Cannot determine policy type for '$fileName'. Using deviceConfigurations endpoint."
                $odataType = '#microsoft.graph.deviceConfiguration'
            }

            $endpoint = Resolve-GraphEndpoint -ODataType $odataType
            Write-Step "Type     : $odataType"
            Write-Step "Endpoint : $endpoint"

            $cleaned  = Remove-ODataMetadata -Obj $json
            $response = Invoke-GraphRequest -Method Post -Uri $endpoint -Body $cleaned -Token $Token

            # PS 5.1 compatible name resolution (no ?? operator)
            if ($response.displayName) {
                $createdName = $response.displayName
            }
            elseif ($response.name) {
                $createdName = $response.name
            }
            else {
                $createdName = $response.id
            }

            Write-Ok "Created: $createdName"
            $success++
        }
        catch {
            Write-Warn "Failed '$fileName': $_"
            $failed++
        }
    }

    return @{ Success = $success; Failed = $failed }
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

Write-Host ''
Write-Host '========================================' -ForegroundColor Cyan
Write-Host '   Intune Baselines Deployer            ' -ForegroundColor Cyan
Write-Host '========================================' -ForegroundColor Cyan

if (-not $TenantId) {
    Write-Host ''
    $TenantId = Read-Host 'Enter destination Tenant ID (GUID or domain)'
}
if (-not $TenantId) { throw 'Tenant ID is required.' }

$appCredentials = $null

if ($SkipAppCreation) {
    if (-not $ClientId) {
        $ClientId = Read-Host 'Enter Client ID (appId) of existing App Registration'
    }
    if (-not $ClientSecret) {
        $ClientSecret = Read-Host 'Enter Client Secret'
    }
    $appCredentials = @{ AppId = $ClientId; ClientSecret = $ClientSecret }
}
else {
    # -- Step 1: Admin bootstrap auth ------------------------------------------
    Write-Header 'Step 1 of 4 - Admin Authentication'
    Write-Host '  Sign in with a Global Admin or Intune Admin account.' -ForegroundColor Gray

    $adminScopes = @(
        'Application.ReadWrite.All',
        'AppRoleAssignment.ReadWrite.All',
        'Directory.ReadWrite.All'
    )

    $adminToken = Get-DeviceCodeToken `
        -TenantId $TenantId `
        -ClientId $BOOTSTRAP_CLIENT_ID `
        -Scopes   $adminScopes

    Write-Ok 'Admin authenticated.'

    # -- Step 2: Create App Registration ---------------------------------------
    Write-Header 'Step 2 of 4 - Creating App Registration'

    $appCredentials = New-AppRegistration `
        -DisplayName $AppDisplayName `
        -AdminToken  $adminToken `
        -TenantId    $TenantId

    Write-Host ''
    Write-Host '  +----------------------------------------------------------+' -ForegroundColor Green
    Write-Host '  |  App Registration Details  (save these somewhere safe)   |' -ForegroundColor Green
    Write-Host '  |                                                           |' -ForegroundColor Green
    Write-Host "  |  Tenant ID     : $TenantId" -ForegroundColor Green
    Write-Host "  |  Client ID     : $($appCredentials.AppId)" -ForegroundColor Green
    Write-Host "  |  Client Secret : $($appCredentials.ClientSecret)" -ForegroundColor Green
    Write-Host '  |                                                           |' -ForegroundColor Green
    Write-Host '  +----------------------------------------------------------+' -ForegroundColor Green
}

# -- Step 3: App authentication ------------------------------------------------
Write-Header 'Step 3 of 4 - Authenticating as App'

# Newly created app registrations take a few seconds to replicate across
# Azure AD before client credentials auth will succeed.
if (-not $SkipAppCreation) {
    Write-Step 'Waiting 20 seconds for app registration to propagate in Azure AD...'
    Start-Sleep -Seconds 20
}

$maxRetries = 5
$retryDelay = 10
$appToken   = $null

for ($attempt = 1; $attempt -le $maxRetries; $attempt++) {
    try {
        Write-Step "Acquiring token using client credentials (attempt $attempt of $maxRetries)..."
        $appToken = Get-ClientCredentialToken `
            -TenantId     $TenantId `
            -ClientId     $appCredentials.AppId `
            -ClientSecret $appCredentials.ClientSecret
        break
    }
    catch {
        if ($attempt -eq $maxRetries) { throw }
        Write-Warn "Token request failed: $_"
        Write-Step "Retrying in $retryDelay seconds..."
        Start-Sleep -Seconds $retryDelay
    }
}

Write-Ok 'App token acquired.'

# -- Step 4: Select and upload JSON baselines ----------------------------------
Write-Header 'Step 4 of 4 - Select and Upload Intune Baselines'
Write-Host '  A file picker will open. Select one or more JSON baseline files.' -ForegroundColor Gray

$selectedFiles = Select-JsonFiles

if ($selectedFiles.Count -eq 0) {
    Write-Warn 'No files selected. Exiting.'
    exit 0
}

Write-Step "Selected $($selectedFiles.Count) file(s)."

$results = Invoke-ProfileUpload -FilePaths $selectedFiles -Token $appToken

Write-Host ''
Write-Host '--- Upload Complete ---' -ForegroundColor Cyan
Write-Host "  Succeeded : $($results.Success)" -ForegroundColor Green

if ($results.Failed -gt 0) {
    Write-Host "  Failed    : $($results.Failed)" -ForegroundColor Red
}
else {
    Write-Host "  Failed    : $($results.Failed)" -ForegroundColor Green
}

Write-Host ''
