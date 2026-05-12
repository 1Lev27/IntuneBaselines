#Requires -Version 5.1
<#
.SYNOPSIS  Dark-themed GUI front-end for the Intune Baselines Deployer.
.NOTES     Compile to a standalone .exe with Build-Exe.ps1.
#>

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# ---------------------------------------------------------------------------
# Theme palette
# ---------------------------------------------------------------------------
$C = @{
    Form    = [Drawing.Color]::FromArgb(28, 28, 28)
    Panel   = [Drawing.Color]::FromArgb(40, 40, 40)
    Group   = [Drawing.Color]::FromArgb(45, 45, 45)
    Input   = [Drawing.Color]::FromArgb(55, 55, 55)
    Text    = [Drawing.Color]::FromArgb(220, 220, 220)
    Dim     = [Drawing.Color]::FromArgb(140, 140, 140)
    Border  = [Drawing.Color]::FromArgb(70, 70, 70)
    Blue    = [Drawing.Color]::FromArgb(0,  120, 212)
    BlueDk  = [Drawing.Color]::FromArgb(0,   96, 175)
    Green   = [Drawing.Color]::FromArgb(78,  201, 176)
    Orange  = [Drawing.Color]::FromArgb(244, 135, 113)
    Red     = [Drawing.Color]::FromArgb(240,  80,  80)
    Cyan    = [Drawing.Color]::FromArgb(156, 220, 254)
    Gold    = [Drawing.Color]::FromArgb(220, 185,  60)
    Header  = [Drawing.Color]::FromArgb(86,  156, 214)
    LogBg   = [Drawing.Color]::FromArgb(18,  18,  18)
}
$FONT      = New-Object Drawing.Font('Segoe UI', 9)
$FONT_BOLD = New-Object Drawing.Font('Segoe UI', 9, [Drawing.FontStyle]::Bold)
$FONT_CODE = New-Object Drawing.Font('Consolas', 10, [Drawing.FontStyle]::Bold)
$FONT_LOG  = New-Object Drawing.Font('Consolas', 9)

# ---------------------------------------------------------------------------
# Shared state (GUI thread <-> background runspace)
# ---------------------------------------------------------------------------
$sync = [hashtable]::Synchronized(@{
    Status          = 'idle'   # idle | running | complete | error
    DeviceCodeUrl   = ''
    DeviceCodeCode  = ''
    DeviceCodeReady = $false
    AuthDone        = $false
    Done            = $false
    ErrorMsg        = ''
    OutputQueue     = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()
})

# ---------------------------------------------------------------------------
# Helper: create a styled control
# ---------------------------------------------------------------------------
function New-Label {
    param([string]$Text, [int]$X, [int]$Y, [int]$W = 120, [int]$H = 22)
    $l = New-Object Windows.Forms.Label
    $l.Text = $Text; $l.Location = [Drawing.Point]::new($X,$Y)
    $l.Size = [Drawing.Size]::new($W,$H)
    $l.ForeColor = $C.Text; $l.BackColor = [Drawing.Color]::Transparent
    $l.Font = $FONT; $l.TextAlign = 'MiddleLeft'
    return $l
}

function New-TextBox {
    param([int]$X, [int]$Y, [int]$W = 260, [string]$Placeholder = '', [bool]$Password = $false)
    $t = New-Object Windows.Forms.TextBox
    $t.Location = [Drawing.Point]::new($X,$Y); $t.Width = $W
    $t.BackColor = $C.Input; $t.ForeColor = $C.Text; $t.Font = $FONT
    $t.BorderStyle = 'FixedSingle'
    if ($Password) { $t.UseSystemPasswordChar = $true }
    return $t
}

function New-Button {
    param([string]$Text, [int]$X, [int]$Y, [int]$W = 120, [int]$H = 32,
          [Drawing.Color]$Bg = $null)
    $b = New-Object Windows.Forms.Button
    $b.Text = $Text; $b.Location = [Drawing.Point]::new($X,$Y)
    $b.Size = [Drawing.Size]::new($W,$H); $b.FlatStyle = 'Flat'
    $b.FlatAppearance.BorderSize = 0
    $bgCol = if ($Bg -ne $null) { $Bg } else { $C.Panel }
    $b.BackColor = $bgCol; $b.ForeColor = $C.Text; $b.Font = $FONT
    $b.Cursor = [Windows.Forms.Cursors]::Hand
    return $b
}

function New-GroupBox {
    param([string]$Text, [int]$X, [int]$Y, [int]$W, [int]$H)
    $g = New-Object Windows.Forms.GroupBox
    $g.Text = $Text; $g.Location = [Drawing.Point]::new($X,$Y)
    $g.Size = [Drawing.Size]::new($W,$H)
    $g.ForeColor = $C.Dim; $g.BackColor = $C.Group; $g.Font = $FONT
    return $g
}

# ---------------------------------------------------------------------------
# Background deployment logic (runs in a separate runspace)
# ---------------------------------------------------------------------------
$deployScript = {
    param($sync, $params)

    # -- Output helpers -------------------------------------------------------
    function wLog {
        param([string]$Text, [string]$Type = 'info')
        $sync.OutputQueue.Enqueue("$Type`t$Text")
    }

    # -- Graph helpers --------------------------------------------------------
    function Invoke-Graph {
        param([string]$Method, [string]$Uri, $Body, [string]$Token)
        $headers = @{ Authorization = "Bearer $Token"; 'Content-Type' = 'application/json' }
        $p = @{ Method=$Method; Uri=$Uri; Headers=$headers }
        if ($null -ne $Body) { $p.Body = ($Body | ConvertTo-Json -Depth 20 -Compress) }
        try { Invoke-RestMethod @p }
        catch {
            $d = $null
            if ($_.Exception.Response) {
                try {
                    $s = $_.Exception.Response.GetResponseStream()
                    $d = (New-Object System.IO.StreamReader($s)).ReadToEnd() | ConvertFrom-Json
                } catch { }
            }
            $msg = if ($d -and $d.error.message) { $d.error.message } else { $_.Exception.Message }
            throw "Graph error: $msg"
        }
    }

    function Get-DeviceCodeToken {
        param([string]$TenantId, [string]$ClientId, [string[]]$Scopes)
        $scopeStr = ($Scopes -join ' ') + ' offline_access'
        $base     = "https://login.microsoftonline.com/$TenantId/oauth2/v2.0"
        $cr = Invoke-RestMethod -Method Post -Uri "$base/devicecode" -Body @{
            client_id = $ClientId; scope = $scopeStr
        }
        # Signal GUI
        $sync.DeviceCodeUrl   = $cr.verification_uri
        $sync.DeviceCodeCode  = $cr.user_code
        $sync.DeviceCodeReady = $true
        wLog "Open the sign-in URL shown above and enter the code." 'gold'

        $interval = [int]$cr.interval; $expires = [int]$cr.expires_in; $waited = 0
        while ($waited -lt $expires) {
            Start-Sleep -Seconds $interval; $waited += $interval
            try {
                $r = Invoke-RestMethod -Method Post -Uri "$base/token" -Body @{
                    grant_type  = 'urn:ietf:params:oauth:grant-type:device_code'
                    client_id   = $ClientId; device_code = $cr.device_code
                }
                $sync.AuthDone        = $true
                $sync.DeviceCodeReady = $false
                return $r.access_token
            }
            catch {
                $b = $null; try { $b = ($_.ErrorDetails.Message | ConvertFrom-Json) } catch { }
                if ($b -and $b.error -eq 'authorization_pending') { continue }
                if ($b -and $b.error -eq 'slow_down') { $interval += 5; continue }
                throw "Auth failed: $(if ($b -and $b.error_description) { $b.error_description } else { $_.Exception.Message })"
            }
        }
        throw 'Timed out waiting for sign-in.'
    }

    function Get-AppToken {
        param([string]$TenantId, [string]$ClientId, [string]$Secret)
        $r = Invoke-RestMethod -Method Post `
            -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" `
            -Body @{ grant_type='client_credentials'; client_id=$ClientId
                     client_secret=$Secret; scope='https://graph.microsoft.com/.default' }
        return $r.access_token
    }

    function Find-App {
        param([string]$Name, [string]$Token)
        $uri = 'https://graph.microsoft.com/v1.0/applications?$filter=displayName eq ''{0}''&$select=id,appId,displayName' -f $Name
        $r   = Invoke-Graph -Method Get -Uri $uri -Token $Token
        if ($r.value -and $r.value.Count -gt 0) { return $r.value[0] }
        return $null
    }

    function New-AppSecret {
        param([string]$AppObjectId, [string]$Token)
        $r = Invoke-Graph -Method Post `
            -Uri "https://graph.microsoft.com/v1.0/applications/$AppObjectId/addPassword" `
            -Token $Token `
            -Body @{ passwordCredential = @{
                displayName = 'IntuneBaselinesDeployer'
                endDateTime = (Get-Date).AddYears(1).ToString('o') } }
        return $r.secretText
    }

    function New-FullAppRegistration {
        param([string]$Name, [string]$Token)
        $GRAPH_ID = '00000003-0000-0000-c000-000000000000'
        $PERMS    = @('DeviceManagementConfiguration.ReadWrite.All',
                      'DeviceManagementApps.ReadWrite.All',
                      'DeviceManagementManagedDevices.ReadWrite.All')

        wLog 'Resolving Microsoft Graph service principal...' 'step'
        $spUri   = 'https://graph.microsoft.com/v1.0/servicePrincipals?$filter=appId eq ''{0}''&$select=id,appRoles' -f $GRAPH_ID
        $graphSp = Invoke-Graph -Method Get -Uri $spUri -Token $Token
        $spId    = $graphSp.value[0].id
        $roles   = $graphSp.value[0].appRoles

        $reqRoles = @()
        foreach ($perm in $PERMS) {
            $role = $roles | Where-Object { $_.value -eq $perm }
            if (-not $role) { throw "Graph app role not found: $perm" }
            $reqRoles += $role
            wLog "Found permission: $perm" 'ok'
        }

        $resAccess = @(); foreach ($r in $reqRoles) { $resAccess += @{ id=$r.id; type='Role' } }

        wLog "Creating app registration '$Name'..." 'step'
        $app = Invoke-Graph -Method Post -Uri 'https://graph.microsoft.com/v1.0/applications' -Token $Token -Body @{
            displayName = $Name; signInAudience = 'AzureADMyOrg'
            requiredResourceAccess = @(@{ resourceAppId=$GRAPH_ID; resourceAccess=$resAccess })
        }
        wLog "App created (appId: $($app.appId))" 'ok'

        wLog 'Creating service principal...' 'step'
        $sp = Invoke-Graph -Method Post -Uri 'https://graph.microsoft.com/v1.0/servicePrincipals' `
            -Token $Token -Body @{ appId = $app.appId }
        wLog "Service principal: $($sp.id)" 'ok'

        wLog 'Granting admin consent...' 'step'
        foreach ($role in $reqRoles) {
            try {
                Invoke-Graph -Method Post `
                    -Uri "https://graph.microsoft.com/v1.0/servicePrincipals/$($sp.id)/appRoleAssignments" `
                    -Token $Token `
                    -Body @{ principalId=$sp.id; resourceId=$spId; appRoleId=$role.id } | Out-Null
                wLog "Consented: $($role.value)" 'ok'
            } catch { wLog "Could not grant $($role.value): $_" 'warn' }
        }

        return @{ AppObjectId=$app.id; AppId=$app.appId; IsNew=$true }
    }

    function Get-PolicyType {
        param($Obj)
        $props    = $Obj.PSObject.Properties
        $typeProp = $props['@odata.type']
        if ($typeProp -and $typeProp.Value) { return $typeProp.Value }
        if ($props['templateReference'] -and $props['templateReference'].Value) {
            return '#microsoft.graph.deviceManagementConfigurationPolicy'
        }
        if ($props['platforms'] -and $props['technologies'] -and $props['settings']) {
            return '#microsoft.graph.deviceManagementConfigurationPolicy'
        }
        if ($props['settingsDelta']) { return '#microsoft.graph.groupPolicyConfiguration' }
        return $null
    }

    $ROUTE_KEYS = @(
        '#microsoft.graph.deviceManagementConfigurationPolicy',
        '#microsoft.graph.windowsAutopilotDeploymentProfile',
        '#microsoft.graph.groupPolicyConfiguration',
        '#microsoft.graph.deviceCompliancePolicy',
        '#microsoft.graph.deviceEnrollmentConfiguration',
        '#microsoft.graph.deviceConfiguration',
        '#microsoft.graph.'
    )
    $ROUTE_MAP = @{
        '#microsoft.graph.deviceManagementConfigurationPolicy' = 'beta/deviceManagement/configurationPolicies'
        '#microsoft.graph.windowsAutopilotDeploymentProfile'   = 'beta/deviceManagement/windowsAutopilotDeploymentProfiles'
        '#microsoft.graph.groupPolicyConfiguration'            = 'beta/deviceManagement/groupPolicyConfigurations'
        '#microsoft.graph.deviceCompliancePolicy'              = 'beta/deviceManagement/deviceCompliancePolicies'
        '#microsoft.graph.deviceEnrollmentConfiguration'       = 'beta/deviceManagement/deviceEnrollmentConfigurations'
        '#microsoft.graph.deviceConfiguration'                 = 'beta/deviceManagement/deviceConfigurations'
        '#microsoft.graph.'                                    = 'beta/deviceManagement/deviceConfigurations'
    }

    function Get-Endpoint {
        param([string]$Type)
        foreach ($k in $ROUTE_KEYS) {
            if ($Type -like "$k*") { return "https://graph.microsoft.com/$($ROUTE_MAP[$k])" }
        }
        if ($Type -like '*CompliancePolicy')          { return 'https://graph.microsoft.com/beta/deviceManagement/deviceCompliancePolicies' }
        if ($Type -like '*AutopilotDeploymentProfile') { return 'https://graph.microsoft.com/beta/deviceManagement/windowsAutopilotDeploymentProfiles' }
        return 'https://graph.microsoft.com/beta/deviceManagement/deviceConfigurations'
    }

    function Remove-ReadOnly {
        param($Obj)
        $drop  = @('id','createdDateTime','lastModifiedDateTime','version',
                   'supportsScopeTags','roleScopeTagIds','@odata.context','@odata.etag',
                   'settingCount','isAssigned','settingDefinitions','assignments','scheduledActionsForRule')
        $clone = $Obj | ConvertTo-Json -Depth 20 | ConvertFrom-Json
        foreach ($k in $drop) {
            if ($clone.PSObject.Properties[$k]) { $clone.PSObject.Properties.Remove($k) }
        }
        return $clone
    }

    # ── Main deployment flow ──────────────────────────────────────────────────
    try {
        $appToken  = $null
        $appWasNew = $false

        if ($params.UseExisting) {
            wLog 'Using existing app registration.' 'step'
            $appToken = Get-AppToken -TenantId $params.TenantId `
                -ClientId $params.ClientId -Secret $params.ClientSecret
        }
        else {
            # Admin auth via device code
            wLog '--- Step 1: Admin Authentication ---' 'header'
            wLog 'Sign in with a Global Admin or Intune Admin account.' 'step'
            $adminToken = Get-DeviceCodeToken `
                -TenantId $params.TenantId `
                -ClientId '14d82eec-204b-4c2f-b7e8-296a70dab67e' `
                -Scopes   @('Application.ReadWrite.All','AppRoleAssignment.ReadWrite.All','Directory.ReadWrite.All')
            wLog 'Admin authenticated successfully.' 'ok'

            # Check for existing app
            wLog '--- Step 2: App Registration ---' 'header'
            wLog "Checking for existing app '$($params.AppName)'..." 'step'
            $existingApp = Find-App -Name $params.AppName -Token $adminToken

            if ($existingApp) {
                wLog "Found existing app (appId: $($existingApp.appId)). Reusing it." 'ok'
                wLog 'Adding a new client secret...' 'step'
                $secret   = New-AppSecret -AppObjectId $existingApp.id -Token $adminToken
                $appId    = $existingApp.appId
                $appWasNew = $false
            }
            else {
                $result   = New-FullAppRegistration -Name $params.AppName -Token $adminToken
                $appId    = $result.AppId
                wLog 'Adding client secret...' 'step'
                $secret   = New-AppSecret -AppObjectId $result.AppObjectId -Token $adminToken
                wLog 'Client secret created.' 'ok'
                $appWasNew = $true
            }

            $sync.OutputQueue.Enqueue("appid`t$appId")
            $sync.OutputQueue.Enqueue("secret`t$secret")

            wLog '--- Step 3: Authenticating as App ---' 'header'
            if ($appWasNew) {
                wLog 'Waiting 20 s for new app to propagate in Azure AD...' 'step'
                Start-Sleep -Seconds 20
            }

            $maxTry = 5
            for ($i = 1; $i -le $maxTry; $i++) {
                try {
                    wLog "Acquiring app token (attempt $i of $maxTry)..." 'step'
                    $appToken = Get-AppToken -TenantId $params.TenantId -ClientId $appId -Secret $secret
                    break
                }
                catch {
                    if ($i -eq $maxTry) { throw }
                    wLog "Token failed: $_  Retrying in 10 s..." 'warn'
                    Start-Sleep -Seconds 10
                }
            }
            wLog 'App token acquired.' 'ok'
        }

        # Upload files
        wLog '--- Step 4: Uploading Baselines ---' 'header'
        $ok = 0; $fail = 0

        foreach ($filePath in $params.Files) {
            $name = [System.IO.Path]::GetFileName($filePath)
            wLog "Uploading: $name" 'step'
            try {
                $json  = Get-Content -Path $filePath -Raw -Encoding UTF8 | ConvertFrom-Json
                $type  = Get-PolicyType -Obj $json
                if (-not $type) {
                    wLog "  Cannot determine type. Using deviceConfigurations." 'warn'
                    $type = '#microsoft.graph.deviceConfiguration'
                }
                $ep      = Get-Endpoint -Type $type
                $cleaned = Remove-ReadOnly -Obj $json
                $resp    = Invoke-Graph -Method Post -Uri $ep -Body $cleaned -Token $appToken
                $label   = if ($resp.displayName) { $resp.displayName } elseif ($resp.name) { $resp.name } else { $resp.id }
                wLog "  Created: $label" 'ok'
                $ok++
            }
            catch {
                wLog "  Failed: $_" 'error'
                $fail++
            }
        }

        wLog "--- Complete: $ok succeeded, $fail failed ---" 'header'
        $sync.Done = $true
    }
    catch {
        $sync.ErrorMsg = $_.ToString()
        $sync.Done     = $true
    }
}

# ---------------------------------------------------------------------------
# Build the main form
# ---------------------------------------------------------------------------
$form               = New-Object Windows.Forms.Form
$form.Text          = 'Intune Baselines Deployer'
$form.Size          = [Drawing.Size]::new(860, 800)
$form.MinimumSize   = [Drawing.Size]::new(700, 650)
$form.BackColor     = $C.Form
$form.ForeColor     = $C.Text
$form.Font          = $FONT
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = 'Sizable'

# ── Connection GroupBox ───────────────────────────────────────────────────────
$grpConn          = New-GroupBox 'Connection Settings' 10 10 830 220
$grpConn.Anchor   = 'Top,Left,Right'

$grpConn.Controls.Add((New-Label 'Tenant ID:'      12 22))
$txtTenant        = New-TextBox 130 20 480
$txtTenant.Anchor = 'Top,Left,Right'
$grpConn.Controls.Add($txtTenant)

$grpConn.Controls.Add((New-Label 'App Name:' 12 54))
$txtAppName        = New-TextBox 130 52 480 '' $false
$txtAppName.Text   = 'IntuneBaselinesDeployer'
$txtAppName.Anchor = 'Top,Left,Right'
$grpConn.Controls.Add($txtAppName)

# Radio buttons
$rbAuto              = New-Object Windows.Forms.RadioButton
$rbAuto.Text         = 'Auto-detect / Create App Registration'
$rbAuto.Location     = [Drawing.Point]::new(12, 88)
$rbAuto.Size         = [Drawing.Size]::new(350, 22)
$rbAuto.ForeColor    = $C.Text; $rbAuto.BackColor = [Drawing.Color]::Transparent
$rbAuto.Checked      = $true; $rbAuto.Cursor = [Windows.Forms.Cursors]::Hand
$grpConn.Controls.Add($rbAuto)

$rbExist             = New-Object Windows.Forms.RadioButton
$rbExist.Text        = 'Use Existing App Registration'
$rbExist.Location    = [Drawing.Point]::new(12, 112)
$rbExist.Size        = [Drawing.Size]::new(350, 22)
$rbExist.ForeColor   = $C.Text; $rbExist.BackColor = [Drawing.Color]::Transparent
$rbExist.Cursor      = [Windows.Forms.Cursors]::Hand
$grpConn.Controls.Add($rbExist)

# Existing-app panel (hidden by default)
$pnlExist           = New-Object Windows.Forms.Panel
$pnlExist.Location  = [Drawing.Point]::new(10, 138)
$pnlExist.Size      = [Drawing.Size]::new(800, 70)
$pnlExist.BackColor = [Drawing.Color]::Transparent
$pnlExist.Visible   = $false
$pnlExist.Anchor    = 'Top,Left,Right'

$pnlExist.Controls.Add((New-Label 'Client ID:' 2 4 100))
$txtClientId        = New-TextBox 110 2 380
$txtClientId.Anchor = 'Top,Left,Right'
$pnlExist.Controls.Add($txtClientId)

$pnlExist.Controls.Add((New-Label 'Client Secret:' 2 36 100))
$txtSecret          = New-TextBox 110 34 300 '' $true
$txtSecret.Anchor   = 'Top,Left,Right'
$pnlExist.Controls.Add($txtSecret)

$btnShowPw          = New-Button 'Show' 418 34 60 24
$btnShowPw.Anchor   = 'Top,Left'
$pnlExist.Controls.Add($btnShowPw)

$grpConn.Controls.Add($pnlExist)
$form.Controls.Add($grpConn)

# Toggle existing-app panel
$rbAuto.Add_CheckedChanged({
    $pnlExist.Visible = -not $rbAuto.Checked
    $grpConn.Height   = if ($rbAuto.Checked) { 120 } else { 220 }
    $grpFiles.Top     = $grpConn.Bottom + 8
    Reflow-Panels
})
$rbExist.Add_CheckedChanged({
    $pnlExist.Visible = $rbExist.Checked
    $grpConn.Height   = if ($rbAuto.Checked) { 120 } else { 220 }
    $grpFiles.Top     = $grpConn.Bottom + 8
    Reflow-Panels
})
$btnShowPw.Add_Click({
    $txtSecret.UseSystemPasswordChar = -not $txtSecret.UseSystemPasswordChar
    $btnShowPw.Text = if ($txtSecret.UseSystemPasswordChar) { 'Show' } else { 'Hide' }
})

# Collapse connection group initially (auto mode, no existing-creds panel)
$grpConn.Height = 120

# ── Files GroupBox ────────────────────────────────────────────────────────────
$grpFiles          = New-GroupBox 'Baseline Files' 10 ($grpConn.Bottom+8) 830 170
$grpFiles.Anchor   = 'Top,Left,Right'

$lstFiles              = New-Object Windows.Forms.ListBox
$lstFiles.Location     = [Drawing.Point]::new(12, 20)
$lstFiles.Size         = [Drawing.Size]::new(680, 136)
$lstFiles.BackColor    = $C.Input; $lstFiles.ForeColor = $C.Text
$lstFiles.BorderStyle  = 'FixedSingle'; $lstFiles.Font = $FONT
$lstFiles.SelectionMode = 'MultiExtended'
$lstFiles.Anchor       = 'Top,Left,Right,Bottom'
$grpFiles.Controls.Add($lstFiles)

$btnAdd     = New-Button 'Add Files...'    704 20 118 32 $C.Blue
$btnRemove  = New-Button 'Remove Selected' 704 60 118 32
$btnClrFile = New-Button 'Clear All'       704 96 118 32
$btnAdd.Anchor = 'Top,Right'
$btnRemove.Anchor = 'Top,Right'
$btnClrFile.Anchor = 'Top,Right'
$grpFiles.Controls.Add($btnAdd)
$grpFiles.Controls.Add($btnRemove)
$grpFiles.Controls.Add($btnClrFile)
$form.Controls.Add($grpFiles)

# ── Device-code banner (hidden until needed) ──────────────────────────────────
$pnlCode          = New-Object Windows.Forms.Panel
$pnlCode.Height   = 80
$pnlCode.BackColor = [Drawing.Color]::FromArgb(50, 40, 0)
$pnlCode.Visible  = $false
$pnlCode.Anchor   = 'Top,Left,Right'

$lblCodeTitle     = New-Object Windows.Forms.Label
$lblCodeTitle.Text = 'ACTION REQUIRED — Sign In'
$lblCodeTitle.Location = [Drawing.Point]::new(10,6)
$lblCodeTitle.Size = [Drawing.Size]::new(600,18)
$lblCodeTitle.ForeColor = $C.Gold; $lblCodeTitle.Font = $FONT_BOLD
$pnlCode.Controls.Add($lblCodeTitle)

$lblCodeUrl       = New-Object Windows.Forms.Label
$lblCodeUrl.Text  = ''
$lblCodeUrl.Location = [Drawing.Point]::new(10,26)
$lblCodeUrl.Size  = [Drawing.Size]::new(520,18)
$lblCodeUrl.ForeColor = $C.Cyan; $lblCodeUrl.Font = $FONT
$pnlCode.Controls.Add($lblCodeUrl)

$lblCode          = New-Object Windows.Forms.Label
$lblCode.Text     = ''
$lblCode.Location = [Drawing.Point]::new(10,46)
$lblCode.Size     = [Drawing.Size]::new(300,26)
$lblCode.ForeColor = $C.Gold; $lblCode.Font = $FONT_CODE
$pnlCode.Controls.Add($lblCode)

$btnOpenBrowser   = New-Button 'Open Browser' 550 10 120 28 $C.Blue
$btnCopyCode      = New-Button 'Copy Code'    550 44 120 28
$pnlCode.Controls.Add($btnOpenBrowser)
$pnlCode.Controls.Add($btnCopyCode)
$form.Controls.Add($pnlCode)

$btnOpenBrowser.Add_Click({ Start-Process $lblCodeUrl.Text })
$btnCopyCode.Add_Click({
    [System.Windows.Forms.Clipboard]::SetText($lblCode.Text.Trim())
    $btnCopyCode.Text = 'Copied!'
    $timer.Interval   = 200
})

# ── Output log ────────────────────────────────────────────────────────────────
$grpLog         = New-GroupBox 'Output' 10 0 830 200
$grpLog.Anchor  = 'Top,Left,Right,Bottom'

$rtb              = New-Object Windows.Forms.RichTextBox
$rtb.Location     = [Drawing.Point]::new(12, 20)
$rtb.Size         = [Drawing.Size]::new(800, 155)
$rtb.BackColor    = $C.LogBg; $rtb.ForeColor = $C.Text
$rtb.Font         = $FONT_LOG; $rtb.ReadOnly = $true
$rtb.BorderStyle  = 'None'; $rtb.ScrollBars = 'Vertical'
$rtb.Anchor       = 'Top,Left,Right,Bottom'
$grpLog.Controls.Add($rtb)

$btnClrLog        = New-Button 'Clear Log' 12 180 90 24
$btnClrLog.Anchor = 'Bottom,Left'
$grpLog.Controls.Add($btnClrLog)
$form.Controls.Add($grpLog)

# ── Footer ────────────────────────────────────────────────────────────────────
$pnlFoot          = New-Object Windows.Forms.Panel
$pnlFoot.Height   = 52
$pnlFoot.BackColor = $C.Panel
$pnlFoot.Dock     = 'Bottom'

$lblStatus        = New-Object Windows.Forms.Label
$lblStatus.Text   = 'Ready'
$lblStatus.Location = [Drawing.Point]::new(14, 16)
$lblStatus.Size   = [Drawing.Size]::new(500, 22)
$lblStatus.ForeColor = $C.Dim; $lblStatus.Font = $FONT
$pnlFoot.Controls.Add($lblStatus)

$btnDeploy        = New-Button 'Deploy' 680 10 150 34 $C.Blue
$btnDeploy.Font   = New-Object Drawing.Font('Segoe UI', 10, [Drawing.FontStyle]::Bold)
$btnDeploy.Anchor = 'Top,Right'
$pnlFoot.Controls.Add($btnDeploy)
$form.Controls.Add($pnlFoot)

# ── Layout helper: reposition panels below connection group ───────────────────
function Reflow-Panels {
    $grpFiles.Top  = $grpConn.Bottom + 8
    $pnlCode.Top   = $grpFiles.Bottom + 4
    $pnlCode.Left  = 10; $pnlCode.Width = $form.ClientSize.Width - 20
    $grpLog.Top    = $pnlCode.Bottom + (if ($pnlCode.Visible) { 4 } else { 0 })
    $grpLog.Height = $pnlFoot.Top - $grpLog.Top - 6
    $grpFiles.Width = $form.ClientSize.Width - 20
    $grpConn.Width  = $form.ClientSize.Width - 20
    $grpLog.Width   = $form.ClientSize.Width - 20
}

$form.Add_Resize({ Reflow-Panels })
$form.Add_Shown({ Reflow-Panels })

# ── Log append helper (GUI thread only) ───────────────────────────────────────
$TYPE_COLORS = @{
    ok     = $C.Green
    warn   = $C.Orange
    error  = $C.Red
    step   = $C.Text
    header = $C.Header
    gold   = $C.Gold
    cyan   = $C.Cyan
    info   = $C.Dim
    appid  = $C.Dim
    secret = $C.Dim
}

function Append-Log {
    param([string]$Type, [string]$Text)
    $color = if ($TYPE_COLORS.ContainsKey($Type)) { $TYPE_COLORS[$Type] } else { $C.Text }
    $prefix = switch ($Type) {
        'ok'     { '  OK ' }; 'warn'   { '  !! ' }; 'error'  { '  !! ' }
        'step'   { '  -> ' }; 'header' { ''       }; default  { '      ' }
    }
    $rtb.SelectionStart  = $rtb.TextLength
    $rtb.SelectionLength = 0
    $rtb.SelectionColor  = $color
    $rtb.AppendText("$prefix$Text`n")
    $rtb.ScrollToCaret()
}

# ── Poll timer ────────────────────────────────────────────────────────────────
$timer          = New-Object Windows.Forms.Timer
$timer.Interval = 400

$psInstance = $null
$asyncResult = $null

$timer.Add_Tick({
    # Drain output queue
    $line = ''
    while ($sync.OutputQueue.TryDequeue([ref]$line)) {
        if ($line -match '^(\w+)\t(.*)$') {
            $t = $Matches[1]; $msg = $Matches[2]
            if ($t -eq 'appid')  { $sync.AppId   = $msg; continue }
            if ($t -eq 'secret') { $sync.AppSecret = $msg; continue }
            Append-Log $t $msg
        }
    }

    # Show device-code banner
    if ($sync.DeviceCodeReady -and -not $pnlCode.Visible) {
        $lblCodeUrl.Text = $sync.DeviceCodeUrl
        $lblCode.Text    = "Code:  $($sync.DeviceCodeCode)"
        $pnlCode.Visible = $true
        Reflow-Panels
    }

    # Hide banner when auth done
    if ($sync.AuthDone -and $pnlCode.Visible) {
        $pnlCode.Visible   = $false
        $sync.AuthDone     = $false
        $btnCopyCode.Text  = 'Copy Code'
        Reflow-Panels
    }

    # Reset copy-code button label after delay
    if ($btnCopyCode.Text -eq 'Copied!') {
        $timer.Interval = 1500
    } else {
        $timer.Interval = 400
    }
    if ($timer.Interval -eq 1500 -and $btnCopyCode.Text -eq 'Copied!') {
        $btnCopyCode.Text = 'Copy Code'
        $timer.Interval   = 400
    }

    # Deployment finished
    if ($sync.Done) {
        $timer.Stop()
        $psInstance.EndInvoke($asyncResult) | Out-Null
        $psInstance.Dispose()

        if ($sync.ErrorMsg) {
            Append-Log 'error' "ERROR: $($sync.ErrorMsg)"
            $lblStatus.Text     = 'Failed — see log for details.'
            $lblStatus.ForeColor = $C.Red
        }
        else {
            if ($sync.AppId -and $sync.AppSecret) {
                Append-Log 'header' ''
                Append-Log 'gold'   "Tenant ID     : $($txtTenant.Text)"
                Append-Log 'gold'   "Client ID     : $($sync.AppId)"
                Append-Log 'gold'   "Client Secret : $($sync.AppSecret)"
                Append-Log 'header' '(Save the credentials above for future runs)'
            }
            $lblStatus.Text      = 'Deployment complete.'
            $lblStatus.ForeColor = $C.Green
        }

        $btnDeploy.Enabled  = $true
        $btnDeploy.BackColor = $C.Blue
        $sync.Done          = $false
        $sync.ErrorMsg      = ''
    }
})

# ── File management events ────────────────────────────────────────────────────
$btnAdd.Add_Click({
    $dlg = New-Object Windows.Forms.OpenFileDialog
    $dlg.Title       = 'Select Intune Baseline JSON files'
    $dlg.Filter      = 'JSON files (*.json)|*.json|All files (*.*)|*.*'
    $dlg.Multiselect = $true
    if ($dlg.ShowDialog($form) -eq [Windows.Forms.DialogResult]::OK) {
        foreach ($f in $dlg.FileNames) {
            if (-not $lstFiles.Items.Contains($f)) { $lstFiles.Items.Add($f) | Out-Null }
        }
    }
})

$btnRemove.Add_Click({
    $selected = @($lstFiles.SelectedItems)
    foreach ($item in $selected) { $lstFiles.Items.Remove($item) }
})

$btnClrFile.Add_Click({ $lstFiles.Items.Clear() })
$btnClrLog.Add_Click({ $rtb.Clear() })

# ── Deploy button ─────────────────────────────────────────────────────────────
$btnDeploy.Add_Click({
    # Validate
    if (-not $txtTenant.Text.Trim()) {
        [Windows.Forms.MessageBox]::Show('Please enter a Tenant ID.','Validation',[Windows.Forms.MessageBoxButtons]::OK,[Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
        return
    }
    if ($lstFiles.Items.Count -eq 0) {
        [Windows.Forms.MessageBox]::Show('Please add at least one JSON baseline file.','Validation',[Windows.Forms.MessageBoxButtons]::OK,[Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
        return
    }
    if ($rbExist.Checked -and (-not $txtClientId.Text.Trim() -or -not $txtSecret.Text.Trim())) {
        [Windows.Forms.MessageBox]::Show('Please enter a Client ID and Client Secret.','Validation',[Windows.Forms.MessageBoxButtons]::OK,[Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
        return
    }

    # Reset state
    $sync.Done          = $false
    $sync.ErrorMsg      = ''
    $sync.DeviceCodeReady = $false
    $sync.AuthDone      = $false
    $sync.AppId         = ''
    $sync.AppSecret     = ''
    $rtb.Clear()

    $deployParams = @{
        TenantId    = $txtTenant.Text.Trim()
        AppName     = $txtAppName.Text.Trim()
        UseExisting = $rbExist.Checked
        ClientId    = $txtClientId.Text.Trim()
        ClientSecret = $txtSecret.Text
        Files       = @($lstFiles.Items)
    }

    $btnDeploy.Enabled   = $false
    $btnDeploy.BackColor = $C.BlueDk
    $lblStatus.Text      = 'Running...'
    $lblStatus.ForeColor = $C.Cyan

    Append-Log 'header' '========================================='
    Append-Log 'header' '   Intune Baselines Deployer'
    Append-Log 'header' '========================================='

    # Start background runspace
    $pool = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspacePool(1, 1)
    $pool.Open()

    $script:psInstance   = [System.Management.Automation.PowerShell]::Create()
    $psInstance.RunspacePool = $pool
    $psInstance.AddScript($deployScript) | Out-Null
    $psInstance.AddArgument($sync)       | Out-Null
    $psInstance.AddArgument($deployParams) | Out-Null

    $script:asyncResult = $psInstance.BeginInvoke()
    $timer.Start()
})

# ── Launch ────────────────────────────────────────────────────────────────────
[Windows.Forms.Application]::Run($form)
