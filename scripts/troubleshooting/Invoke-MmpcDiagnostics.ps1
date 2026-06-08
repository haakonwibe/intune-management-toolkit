#Requires -Version 5.1
<#
.SYNOPSIS
    Diagnostics toolkit for the Intune MMP-C / "linked enrollment" (Declared Configuration / WinDC)
    channel that delivers Endpoint Privilege Management (EPM) and Device Inventory policies.

.DESCRIPTION
    Classic Intune config rides OMA-DM. EPM does NOT. EPM policies come down the MMP-C channel via a
    second ("linked" / dual) enrollment, processed locally by the Declared Configuration service.
    A healthy OMA-DM enrollment says nothing about MMP-C health, so a single setting like
    "Send elevation data for reporting" can error while every classic profile applies clean.

    This toolkit inspects, in one pass:
      - Both enrollments under HKLM\SOFTWARE\Microsoft\Enrollments and which is MMP-C
      - The LinkedEnrollment subkey (EnrollStatus / MMPCLocked / flag)
      - The dual-enrollment scheduled task (deviceenroller.exe /EnrollMmpc) - its lingering
        presence usually means the enrollment is stuck or never completed
      - The MMP-C device certificate referenced by SSLClientCertSearchCriteria
      - EPM agent service / folder and the DeviceHealthMonitoring policy keys
      - Recent failures in the DeviceManagement-Enterprise-Diagnostics-Provider/Admin log
      - Reachability of the MMP-C endpoints, AND whether an intercepting proxy /
        SSL inspection is rewriting the server certificate (the most common MMP-C break).
        Endpoints are DISCOVERED from the device (DiscoveryEndpoint reg value, DM diag log,
        and with -DiscoverEndpoints a live query of the discovery service) rather than
        hardcoded - only discovery.dm.microsoft.com is a fixed, documented host; the
        enrollment/policy/auth URLs are returned dynamically by the discovery service.

    Run elevated. Reads are admin-level; the optional re-enrollment trigger needs SYSTEM.

.NOTES
    Research basis: Rudy Ooms (call4cloud.nl) MMP-C / WinDC / dual-enrollment series, and
    Microsoft Learn "Windows declared configuration" docs.
    Registry paths and behaviors are discovered at runtime rather than hardcoded by GUID,
    so this stays accurate as enrollment IDs differ per device.
    Self-contained by design: NO dependency on the IntuneToolkit module or Microsoft.Graph,
    so it can run standalone on an endpoint (e.g. shipped as a remediation) without setup.

.EXAMPLE
    .\Invoke-MmpcDiagnostics.ps1
        Full read-only diagnostic with a PASS/WARN/FAIL summary.

.EXAMPLE
    .\Invoke-MmpcDiagnostics.ps1 -DiscoverEndpoints
        Actively queries the discovery service to surface the REAL enrollment/policy/auth
        URLs for this device/tenant, then TLS-probes every endpoint it uncovered.

.EXAMPLE
    .\Invoke-MmpcDiagnostics.ps1 -Json
        Also writes a timestamped JSON report (metadata + findings + endpoints) to %TEMP%.
        Use -JsonPath <dir-or-file> to control the location.

.EXAMPLE
    $r = .\Invoke-MmpcDiagnostics.ps1 -PassThru
        Returns the structured result object ($r.Findings/.Enrollments/.Linked/.Endpoints/
        .Summary) for further processing. Without -PassThru the console output ends cleanly
        at the summary.

.EXAMPLE
    .\Invoke-MmpcDiagnostics.ps1 -CollectCab
        Also drops an MdmDiagnosticsTool cab for deeper offline analysis.

.EXAMPLE
    .\Invoke-MmpcDiagnostics.ps1 -TriggerReEnrollment
        Re-fires the MMP-C enrollment (deviceenroller.exe /c /EnrollMmpc). Unsupported "Rudy method".
        Requires SYSTEM context. Prompts before acting.
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [switch]$CollectCab,
    [switch]$TriggerReEnrollment,
    [switch]$DiscoverEndpoints,
    [switch]$Json,
    [string]$JsonPath,
    [switch]$PassThru,
    [int]$EventLookbackHours = 24,
    [string]$CabOutputPath = "$env:TEMP\MdmLogs.cab"
)

$ErrorActionPreference = 'Stop'

# Collected findings, tallied into a PASS/WARN/FAIL summary at the end.
$script:Findings = [System.Collections.Generic.List[object]]::new()

# --- MMP-C / linked enrollment endpoints (NOT the *.manage.microsoft.com ones) ---
# Only the discovery host is a fixed, documented endpoint. The enrollment / policy /
# auth / check-in URLs are returned dynamically in the discovery service (DS) response
# (EnrollmentServiceUrl, EnrollmentPolicyServiceUrl, AuthenticationServiceUrl) and differ
# per device/tenant - so we DISCOVER them at runtime instead of hardcoding guesses.
# Ref: learn.microsoft.com/windows/client-management/declared-configuration-discovery
$MmpcDiscoveryHost = 'discovery.dm.microsoft.com'
$MmpcDiscoveryUrl  = 'https://discovery.dm.microsoft.com/EnrollmentConfiguration?api-version=1.0'

$EnrollmentsRoot = 'HKLM:\SOFTWARE\Microsoft\Enrollments'
$OmadmAccounts   = 'HKLM:\SOFTWARE\Microsoft\Provisioning\OMADM\Accounts'
$DhmPolicyKey    = 'HKLM:\SOFTWARE\Microsoft\PolicyManager\default\DeviceHealthMonitoring'
$DmDiagLog       = 'Microsoft-Windows-DeviceManagement-Enterprise-Diagnostics-Provider/Admin'

# ---------------------------------------------------------------------------
# small helpers
# ---------------------------------------------------------------------------
function Write-Result {
    param(
        [Parameter(Mandatory)][ValidateSet('PASS', 'WARN', 'FAIL', 'INFO')][string]$Status,
        [Parameter(Mandatory)][string]$Message
    )
    $color = switch ($Status) {
        'PASS' { 'Green' }
        'WARN' { 'Yellow' }
        'FAIL' { 'Red' }
        default { 'Gray' }
    }
    Write-Host ('[{0}] {1}' -f $Status, $Message) -ForegroundColor $color
    $obj = [pscustomobject]@{ Status = $Status; Message = $Message }
    $script:Findings.Add($obj)
    $obj
}

function Test-IsElevated {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p  = New-Object Security.Principal.WindowsPrincipal($id)
    $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-RegValuesSafe {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return $null }
    try { Get-ItemProperty -Path $Path -ErrorAction Stop } catch { return $null }
}

function ConvertTo-HostName {
    # accepts a bare host or a full URL, returns just the host (or $null)
    param([string]$UrlOrHost)
    if ([string]::IsNullOrWhiteSpace($UrlOrHost)) { return $null }
    $s = $UrlOrHost.Trim()
    if ($s -notmatch '^[A-Za-z][A-Za-z0-9+.-]*://') { $s = "https://$s" }
    try { return ([Uri]$s).Host } catch { return $null }
}

# ---------------------------------------------------------------------------
# 1. enrollments: identify Intune (OMA-DM) vs MMP-C (linked)
# ---------------------------------------------------------------------------
function Get-EnrollmentInventory {
    [CmdletBinding()] param()

    if (-not (Test-Path $EnrollmentsRoot)) {
        Write-Result FAIL "Enrollments root not found - device is not MDM enrolled at all." | Out-Null
        return @()
    }

    $results = foreach ($k in Get-ChildItem $EnrollmentsRoot -ErrorAction SilentlyContinue) {
        # enrollment GUID keys only
        if ($k.PSChildName -notmatch '^[0-9A-Fa-f-]{36}$') { continue }
        $p = Get-RegValuesSafe $k.PSPath
        if (-not $p) { continue }

        $disco = "$($p.DiscoveryServiceFullURL)"
        $type  = "$($p.EnrollmentType)"
        $isMmpc = ($disco -match 'dm\.microsoft\.com') -or ($type -match 'MMPC')

        [pscustomobject]@{
            EnrollmentId       = $k.PSChildName
            UPN                = $p.UPN
            ProviderID         = $p.ProviderID
            EnrollmentType     = $type
            EnrollmentState    = $p.EnrollmentState
            DiscoveryServiceUrl= $disco
            AADResourceID      = $p.AADResourceID
            Channel            = if ($isMmpc) { 'MMP-C' } elseif ($p.ProviderID -eq 'MS DM Server') { 'Intune (OMA-DM)' } else { 'Other/Unknown' }
            KeyPath            = $k.PSPath
        }
    }
    $results
}

# ---------------------------------------------------------------------------
# 2. LinkedEnrollment subkey under the Intune enrollment
# ---------------------------------------------------------------------------
function Get-LinkedEnrollmentState {
    [CmdletBinding()] param()

    $found = @()
    foreach ($k in Get-ChildItem $EnrollmentsRoot -ErrorAction SilentlyContinue) {
        if ($k.PSChildName -notmatch '^[0-9A-Fa-f-]{36}$') { continue }
        $linkPath = Join-Path $k.PSPath 'LinkedEnrollment'
        $p = Get-RegValuesSafe $linkPath
        if ($p) {
            $found += [pscustomobject]@{
                ParentEnrollment   = $k.PSChildName
                EnrollStatus       = $p.EnrollStatus
                LastError          = $p.LastError          # actual failure code; 0 = none
                MMPCLocked         = $p.MMPCLocked
                MmpcEnrollmentFlag = $p.MmpcEnrollmentFlag
                LinkedEnrollmentId = $p.LinkedEnrollmentID # NB: value name is LinkedEnrollmentID, not EnrollmentID
                DiscoveryEndpoint  = $p.DiscoveryEndpoint  # device-specific discovery URL (build 25977+)
                Raw                = $p
            }
        }
    }
    $found
}

# ---------------------------------------------------------------------------
# 3. dual-enrollment scheduled task (deviceenroller.exe /EnrollMmpc)
#    a lingering task = enrollment never finished; it self-deletes on success
# ---------------------------------------------------------------------------
function Get-MmpcEnrollmentTask {
    [CmdletBinding()] param()
    try {
        $tasks = Get-ScheduledTask -ErrorAction Stop |
            Where-Object {
                ($_.TaskPath -like '*EnterpriseMgmt*') -and
                (
                    ($_.TaskName -like '*dual enrollment*') -or
                    # Match ONLY the MMP-C-specific argument. Nearly every enrollment-client
                    # task invokes deviceenroller.exe, so matching the exe name caught them all.
                    ($_.Actions | Where-Object { "$($_.Execute) $($_.Arguments)" -match 'EnrollMmpc' })
                )
            }
        foreach ($t in $tasks) {
            $info = $t | Get-ScheduledTaskInfo -ErrorAction SilentlyContinue
            [pscustomobject]@{
                TaskName     = $t.TaskName
                TaskPath     = $t.TaskPath
                State        = $t.State
                LastRunTime  = $info.LastRunTime
                LastResult   = $info.LastTaskResult
                Action       = ($t.Actions | ForEach-Object { "$($_.Execute) $($_.Arguments)" }) -join ' ; '
            }
        }
    }
    catch {
        Write-Verbose "Scheduled task query failed: $_"
    }
}

# ---------------------------------------------------------------------------
# 4. MMP-C device certificate via SSLClientCertSearchCriteria
# ---------------------------------------------------------------------------
function Get-MmpcCertificate {
    [CmdletBinding()] param()

    if (-not (Test-Path $OmadmAccounts)) { return }
    foreach ($acct in Get-ChildItem $OmadmAccounts -ErrorAction SilentlyContinue) {
        $p = Get-RegValuesSafe $acct.PSPath
        $criteria = "$($p.SSLClientCertSearchCriteria)"
        if (-not $criteria) { continue }

        # criteria looks like: Subject=CN%3D<guid>&Stores=MY%5CSystem  (sometimes a thumbprint)
        $decoded = [Uri]::UnescapeDataString($criteria)
        $thumb = $null
        if ($decoded -match 'Hash=([0-9A-Fa-f]{40})') { $thumb = $Matches[1] }
        $subjectGuid = $null
        if ($decoded -match 'CN=([0-9A-Fa-f-]{36})') { $subjectGuid = $Matches[1] }

        $cert = $null
        $store = Get-ChildItem Cert:\LocalMachine\My -ErrorAction SilentlyContinue
        if ($thumb) {
            $cert = $store | Where-Object Thumbprint -eq $thumb
        }
        elseif ($subjectGuid) {
            $cert = $store | Where-Object { $_.Subject -match $subjectGuid }
        }

        [pscustomobject]@{
            Account        = $acct.PSChildName
            SearchCriteria = $decoded
            CertFound      = [bool]$cert
            Thumbprint     = $cert.Thumbprint
            Subject        = $cert.Subject
            Issuer         = $cert.Issuer
            NotAfter       = $cert.NotAfter
            Expired        = if ($cert) { $cert.NotAfter -lt (Get-Date) } else { $null }
        }
    }
}

# ---------------------------------------------------------------------------
# 5. EPM agent + DeviceHealthMonitoring policy keys
# ---------------------------------------------------------------------------
function Get-EpmAgentState {
    [CmdletBinding()] param()

    # Win32_Service (not Get-Service) so we can show the DisplayName and binary PathName -
    # makes the match self-evidencing rather than trusting a fuzzy '*EPM*' name match.
    $agentFolder = 'C:\Program Files\Microsoft EPM Agent'
    $svc = Get-CimInstance Win32_Service -ErrorAction SilentlyContinue |
           Where-Object { $_.Name -like '*EPM*' -or $_.DisplayName -like '*EPM*' } |
           Select-Object -First 1
    $folder = Test-Path $agentFolder
    # confirm the folder actually holds the agent binary, not just an empty leftover dir
    $binaryPresent = $folder -and [bool](Get-ChildItem $agentFolder -Filter '*.exe' -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1)
    $dhm    = Get-RegValuesSafe (Join-Path $DhmPolicyKey '')
    $dhmInstance = $null
    if ($dhm) { $dhmInstance = $dhm.ConfigDeviceHealthMonitoringServiceInstance }

    [pscustomobject]@{
        AgentServiceName    = $svc.Name
        AgentServiceDisplay = $svc.DisplayName
        AgentServiceStatus  = $svc.State
        AgentServicePath    = $svc.PathName
        AgentFolderPresent  = $folder
        AgentBinaryPresent  = $binaryPresent
        DhmPolicyPresent    = [bool]$dhm
        DhmServiceInstance  = $dhmInstance
    }
}

# ---------------------------------------------------------------------------
# 6. recent failures in the DM diagnostics provider log
# ---------------------------------------------------------------------------
function Get-DmDiagErrors {
    [CmdletBinding()] param([int]$Hours = 24)
    $since = (Get-Date).AddHours(-$Hours)
    try {
        Get-WinEvent -FilterHashtable @{ LogName = $DmDiagLog; StartTime = $since } -ErrorAction Stop |
            Where-Object { $_.LevelDisplayName -in @('Error', 'Warning') } |
            Select-Object TimeCreated, Id, LevelDisplayName,
                @{ n = 'Message'; e = { ($_.Message -replace '\s+', ' ').Trim() } } |
            Sort-Object TimeCreated -Descending
    }
    catch {
        Write-Verbose "Could not read $DmDiagLog : $_"
    }
}

# ---------------------------------------------------------------------------
# 7. endpoint reachability + SSL-inspection detection
#    the killer failure: a proxy / inspection appliance re-signs the cert,
#    deviceenroller rejects the chain, MMP-C never enrolls.
# ---------------------------------------------------------------------------
function Test-MmpcEndpoint {
    [CmdletBinding()] param([Parameter(Mandatory)][string]$HostName, [int]$Port = 443)

    $result = [ordered]@{
        Host          = $HostName
        TcpReachable  = $false
        ServerCertCN  = $null
        ServerCertIssuer = $null
        LikelyInspected = $null
    }

    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $iar = $client.BeginConnect($HostName, $Port, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne(5000)) { throw "TCP connect timeout" }
        $client.EndConnect($iar)
        $result.TcpReachable = $true

        $captured = $null
        $cb = [System.Net.Security.RemoteCertificateValidationCallback] {
            param($snd, $cert, $chain, $errors)
            $script:__capturedCert = $cert
            return $true   # accept so we can inspect; we are not trusting it for real traffic
        }
        $ssl = New-Object System.Net.Security.SslStream($client.GetStream(), $false, $cb)
        $ssl.AuthenticateAsClient($HostName)
        $captured = $script:__capturedCert
        if ($captured) {
            $x = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($captured)
            $result.ServerCertCN     = $x.Subject
            $result.ServerCertIssuer = $x.Issuer
            # Microsoft endpoints chain to a Microsoft/public CA. An internal CN in the issuer
            # is a strong signal of TLS interception.
            $result.LikelyInspected  = ($x.Issuer -notmatch 'Microsoft|DigiCert|Baltimore|GlobalSign|Entrust|GTS|Sectigo|Amazon')
        }
        $ssl.Dispose()
    }
    catch {
        $result.Error = "$_"
    }
    finally {
        $client.Dispose()
        Remove-Variable __capturedCert -Scope Script -ErrorAction SilentlyContinue
    }
    [pscustomobject]$result
}

# ---------------------------------------------------------------------------
# 7b. live discovery probe: POST the documented discovery endpoint and read back
#     the REAL service URLs. Unauthenticated - the goal is to surface the actual
#     EnrollmentServiceUrl/PolicyServiceUrl/AuthServiceUrl (or a meaningful
#     errorCode/HTTP status), not to enroll. Even a 401 proves reachability + TLS.
# ---------------------------------------------------------------------------
function Invoke-MmpcDiscoveryProbe {
    [CmdletBinding()] param([object[]]$Enrollments)

    # derive identity from the existing OMA-DM enrollment (no extra Write-Result noise)
    $intune = @($Enrollments) | Where-Object Channel -eq 'Intune (OMA-DM)' | Select-Object -First 1
    $upn        = $intune.UPN
    $userDomain = if ($upn -match '@') { ($upn -split '@')[-1] } else { $null }
    $tenantId   = $null
    try {
        $tenantId = (& "$env:WINDIR\System32\dsregcmd.exe" /status |
            Select-String 'TenantId\s*:\s*([0-9A-Fa-f-]{36})').Matches.Groups[1].Value
    } catch { Write-Verbose "dsregcmd tenant lookup failed: $_" }

    $body = @{
        userDomain     = $userDomain
        upn            = $upn
        tenantId       = $tenantId
        enrollmentType = 'Device'
        osVersion      = [string][System.Environment]::OSVersion.Version
    } | ConvertTo-Json

    $out = [ordered]@{
        Url                        = $MmpcDiscoveryUrl
        HttpStatus                 = $null
        EnrollmentServiceUrl       = $null
        EnrollmentPolicyServiceUrl = $null
        AuthenticationServiceUrl   = $null
        ManagementResource         = $null
        ErrorCode                  = $null
        Message                    = $null
        Error                      = $null
    }
    try {
        $resp = Invoke-RestMethod -Method Post -Uri $MmpcDiscoveryUrl -Body $body `
                    -ContentType 'application/json' -TimeoutSec 15 -ErrorAction Stop
        $out.HttpStatus                 = 200
        $out.EnrollmentServiceUrl       = $resp.EnrollmentServiceUrl
        $out.EnrollmentPolicyServiceUrl = $resp.EnrollmentPolicyServiceUrl
        $out.AuthenticationServiceUrl   = $resp.AuthenticationServiceUrl
        $out.ManagementResource         = $resp.ManagementResource
        $out.ErrorCode                  = $resp.errorCode
        $out.Message                    = $resp.message
    }
    catch {
        $out.Error = "$_"
        if ($_.Exception.Response) {
            try { $out.HttpStatus = [int]$_.Exception.Response.StatusCode } catch { Write-Verbose "status extract failed: $_" }
        }
    }
    [pscustomobject]$out
}

# ---------------------------------------------------------------------------
# 7c. build the endpoint list FROM THE DEVICE rather than hardcoding guesses:
#     documented discovery host + per-device DiscoveryEndpoint reg value +
#     any *.dm.microsoft.com seen in the DM diag log + (-Live) discovery response.
# ---------------------------------------------------------------------------
function Get-MmpcEndpointMap {
    [CmdletBinding()] param(
        [object[]]$Linked,
        [object[]]$Enrollments,
        [int]$Hours = 24,
        [switch]$Live
    )

    $candidates = [System.Collections.Generic.List[object]]::new()
    $note = {
        param($Value, $Source)
        $h = ConvertTo-HostName $Value
        if ($h -and ($h -like '*.dm.microsoft.com')) {
            $candidates.Add([pscustomobject]@{ Host = $h; Source = $Source })
        }
    }

    # 1) the one documented fixed host
    & $note $MmpcDiscoveryHost 'documented (fixed discovery host)'

    # 2) DiscoveryEndpoint value from each LinkedEnrollment key (authoritative, per-device)
    foreach ($l in @($Linked)) {
        if ($l.DiscoveryEndpoint) {
            & $note $l.DiscoveryEndpoint "registry: LinkedEnrollment\DiscoveryEndpoint ($($l.ParentEnrollment))"
        }
    }

    # 3) any *.dm.microsoft.com URL mentioned in the DM diagnostics log
    try {
        $since = (Get-Date).AddHours(-$Hours)
        Get-WinEvent -FilterHashtable @{ LogName = $DmDiagLog; StartTime = $since } -ErrorAction Stop |
            ForEach-Object {
                foreach ($m in [regex]::Matches("$($_.Message)", '[A-Za-z0-9.-]+\.dm\.microsoft\.com')) {
                    & $note $m.Value "eventlog: DM diag ($($_.Id))"
                }
            }
    } catch { Write-Verbose "endpoint harvest from event log failed: $_" }

    # 4) live discovery: surface the real enrollment/policy/auth URLs
    #    NB: use a distinct name from the [switch]$Live param - PowerShell variable
    #    names are case-insensitive, so a local $live would overwrite $Live.
    $discovery = $null
    if ($Live) {
        $discovery = Invoke-MmpcDiscoveryProbe -Enrollments $Enrollments
        foreach ($u in @($discovery.EnrollmentServiceUrl, $discovery.EnrollmentPolicyServiceUrl,
                          $discovery.AuthenticationServiceUrl, $discovery.ManagementResource)) {
            & $note $u 'live discovery response'
        }
    }

    $map = $candidates.Host | Sort-Object -Unique | ForEach-Object {
        $h = $_
        $srcs = ($candidates | Where-Object Host -eq $h | Select-Object -ExpandProperty Source -Unique) -join '; '
        [pscustomobject]@{ Host = $h; Sources = $srcs }
    }
    [pscustomobject]@{ Hosts = $map; Live = $discovery }
}

# ---------------------------------------------------------------------------
# optional: JSON export (metadata + timestamp, mirrors Export-IntuneReport's
# JSON shape but written inline so the script stays module-free)
# ---------------------------------------------------------------------------
function Export-MmpcDiagnosticsJson {
    [CmdletBinding()] param(
        [Parameter(Mandatory)]$Diagnostics,
        [string]$Path
    )
    $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
    $fileName = 'MmpcDiagnostics_{0}_{1}.json' -f $env:COMPUTERNAME, $stamp

    if (-not $Path) {
        $Path = Join-Path $env:TEMP $fileName                 # no path given -> temp + timestamped name
    }
    elseif ((Test-Path $Path -PathType Container) -or $Path -notmatch '\.json$') {
        $Path = Join-Path $Path $fileName                     # a directory was given -> drop timestamped file in it
    }

    # drop the noisy raw registry blob before serializing
    $linkedClean = foreach ($l in @($Diagnostics.Linked)) { $l | Select-Object -Property * -ExcludeProperty Raw }

    $payload = [ordered]@{
        Metadata = [ordered]@{
            Tool         = 'Invoke-MmpcDiagnostics.ps1'
            GeneratedAt  = (Get-Date).ToString('o')
            ComputerName = $env:COMPUTERNAME
            OSVersion    = [string][System.Environment]::OSVersion.Version
            RanAsSystem  = [bool]((whoami.exe) -match 'system')
        }
        Summary     = $Diagnostics.Summary
        Findings    = $Diagnostics.Findings
        Enrollments = $Diagnostics.Enrollments
        Linked      = $linkedClean
        Endpoints   = $Diagnostics.Endpoints
    }

    try {
        $dir = Split-Path -Parent $Path
        if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $payload | ConvertTo-Json -Depth 8 | Set-Content -Path $Path -Encoding UTF8
        Write-Host "[PASS] JSON report written: $Path" -ForegroundColor Green
    }
    catch {
        Write-Host "[WARN] Failed to write JSON report to ${Path}: $_" -ForegroundColor Yellow
    }
    $Path
}

# ---------------------------------------------------------------------------
# optional: MdmDiagnosticsTool cab
# ---------------------------------------------------------------------------
function Invoke-MdmDiagCab {
    [CmdletBinding()] param([string]$OutputPath)
    $exe = Join-Path $env:WINDIR 'System32\MdmDiagnosticsTool.exe'
    if (-not (Test-Path $exe)) { Write-Result WARN "MdmDiagnosticsTool.exe not found." | Out-Null; return }
    & $exe -area 'DeviceEnrollment;DeviceProvisioning;Autopilot;TPM' -cab $OutputPath | Out-Null
    if (Test-Path $OutputPath) { Write-Result PASS "MDM diagnostic cab written: $OutputPath" | Out-Null }
}

# ---------------------------------------------------------------------------
# optional: re-fire MMP-C enrollment (unsupported, SYSTEM context required)
# ---------------------------------------------------------------------------
function Invoke-MmpcReEnrollment {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')] param()
    $whoami = whoami.exe
    if ($whoami -notmatch 'system') {
        Write-Result WARN "Not running as SYSTEM (current: $whoami). deviceenroller /EnrollMmpc needs SYSTEM. Use PsExec -s or a SYSTEM task." | Out-Null
        return
    }
    $exe = Join-Path $env:WINDIR 'System32\deviceenroller.exe'
    if ($PSCmdlet.ShouldProcess('this device', 'Trigger MMP-C linked enrollment via deviceenroller.exe /c /EnrollMmpc')) {
        & $exe /c /EnrollMmpc
        Write-Result INFO "deviceenroller.exe /c /EnrollMmpc invoked. Watch $DmDiagLog and the LinkedEnrollment key." | Out-Null
    }
}

# ===========================================================================
# orchestrator
# ===========================================================================
function Invoke-MmpcDiagnostics {
    [CmdletBinding()] param([int]$Hours = 24, [switch]$Live)

    Write-Host "`n==== MMP-C / Linked Enrollment Diagnostics ====`n" -ForegroundColor Cyan

    if (-not (Test-IsElevated)) {
        Write-Result FAIL "Run this elevated. Most enrollment reads need admin." | Out-Null
        return
    }

    # 1. enrollments
    Write-Host "`n-- Enrollments --" -ForegroundColor Cyan
    $enrollments = Get-EnrollmentInventory
    $enrollments | Format-Table EnrollmentId, Channel, ProviderID, EnrollmentType, EnrollmentState -AutoSize | Out-Host
    $mmpc = $enrollments | Where-Object Channel -eq 'MMP-C'
    if ($mmpc) { Write-Result PASS "MMP-C enrollment present (type: $($mmpc.EnrollmentType))." | Out-Null }
    else       { Write-Result FAIL "No MMP-C enrollment found. EPM cannot apply. This is the likely root cause." | Out-Null }

    # 2. linked enrollment
    Write-Host "`n-- LinkedEnrollment --" -ForegroundColor Cyan
    $linked = Get-LinkedEnrollmentState
    if ($linked) {
        $linked | Format-Table ParentEnrollment, EnrollStatus, LastError, MMPCLocked, MmpcEnrollmentFlag, DiscoveryEndpoint -AutoSize | Out-Host

        foreach ($l in $linked) {
            # The decisive health signal is the link itself: a real MMP-C enrollment exists,
            # the LinkedEnrollmentId resolves to it, MMPCLocked=1, and LastError=0. The
            # MmpcEnrollmentFlag and exact EnrollStatus values vary by Windows build and are
            # often absent on perfectly healthy devices, so they corroborate rather than decide.
            $linkTarget = $enrollments | Where-Object { $_.EnrollmentId -eq $l.LinkedEnrollmentId -and $_.Channel -eq 'MMP-C' }
            $locked     = ("$($l.MMPCLocked)" -eq '1')
            $noError    = (-not $l.LastError -or $l.LastError -eq 0)

            if ($linkTarget -and $locked -and $noError) {
                Write-Result PASS "Linked enrollment established -> MMP-C enrollment $($l.LinkedEnrollmentId) (MMPCLocked=1, LastError=0)." | Out-Null
            }
            elseif (-not $linkTarget) {
                Write-Result FAIL "LinkedEnrollmentId '$($l.LinkedEnrollmentId)' does not resolve to a present MMP-C enrollment - the link is dangling." | Out-Null
            }
            elseif (-not $locked) {
                Write-Result WARN "MMPCLocked is not 1 on $($l.ParentEnrollment) - linked enrollment not yet locked in / still in progress." | Out-Null
            }

            if ($l.LastError -and $l.LastError -ne 0) {
                Write-Result WARN ("LinkedEnrollment LastError = {0} (0x{1:X8}) on {2}." -f $l.LastError, ([int64]$l.LastError -band 0xFFFFFFFF), $l.ParentEnrollment) | Out-Null
            }

            # secondary, non-blocking corroboration - never the sole basis for a verdict
            switch -regex ("$($l.MmpcEnrollmentFlag)") {
                '^2$'   { Write-Result PASS "MmpcEnrollmentFlag = 2 (enrolled)." | Out-Null; break }
                '^\s*$' { Write-Result INFO "MmpcEnrollmentFlag not present - inconclusive on its own; health taken from the link state above." | Out-Null; break }
                default { Write-Result WARN "MmpcEnrollmentFlag = $($l.MmpcEnrollmentFlag) (expected 2 when fully enrolled)." | Out-Null }
            }
        }
    }
    else {
        Write-Result FAIL "No LinkedEnrollment subkey. The link to MMP-C was never established." | Out-Null
    }

    # 3. enrollment task
    Write-Host "`n-- Dual-enrollment task --" -ForegroundColor Cyan
    $task = Get-MmpcEnrollmentTask
    if ($task) {
        $task | Format-Table TaskName, State, LastRunTime, LastResult -AutoSize | Out-Host
        Write-Result WARN "Enrollment task still present. It self-deletes on success, so it's stuck or retrying. LastResult is the code to chase (0 = ok)." | Out-Null
    }
    else {
        Write-Result INFO "No lingering deviceenroller /EnrollMmpc task (expected once enrollment has completed, OR it never got created)." | Out-Null
    }

    # 4. certificate
    Write-Host "`n-- MMP-C device certificate --" -ForegroundColor Cyan
    $certs = Get-MmpcCertificate
    if ($certs) {
        $certs | Format-Table Account, CertFound, Expired, NotAfter, Issuer -AutoSize | Out-Host
        foreach ($c in $certs) {
            if (-not $c.CertFound) { Write-Result FAIL "Cert referenced by SSLClientCertSearchCriteria is missing. MMP-C comms will fail." | Out-Null }
            elseif ($c.Expired)    { Write-Result FAIL "MMP-C device cert expired ($($c.NotAfter))." | Out-Null }
        }
    }
    else { Write-Result INFO "No OMADM SSLClientCertSearchCriteria found to resolve a cert from." | Out-Null }

    # 5. EPM agent
    Write-Host "`n-- EPM agent / DeviceHealthMonitoring --" -ForegroundColor Cyan
    $epm = Get-EpmAgentState
    $epm | Format-List | Out-Host
    if (-not $epm.AgentBinaryPresent) {
        Write-Result WARN "EPM agent binary not found under 'C:\Program Files\Microsoft EPM Agent' - agent not installed (downstream of the enrollment, not the cause)." | Out-Null
    }
    elseif ("$($epm.AgentServiceStatus)" -ne 'Running') {
        Write-Result WARN "EPM agent installed but service '$($epm.AgentServiceName)' is '$($epm.AgentServiceStatus)' (expected Running)." | Out-Null
    }
    else {
        Write-Result PASS "EPM agent installed and running ($($epm.AgentServiceDisplay))." | Out-Null
    }
    if (-not $epm.DhmPolicyPresent)   { Write-Result WARN "DeviceHealthMonitoring policy keys absent. Known 404 trigger in the DM diag log." | Out-Null }

    # 6. event log
    Write-Host "`n-- DM diagnostics errors (last $Hours h) --" -ForegroundColor Cyan
    $errs = Get-DmDiagErrors -Hours $Hours
    if ($errs) { $errs | Select-Object -First 15 | Format-Table TimeCreated, Id, LevelDisplayName -AutoSize | Out-Host
                 $errs | Select-Object -First 5 | ForEach-Object { Write-Host ("  {0} [{1}] {2}" -f $_.TimeCreated, $_.Id, $_.Message.Substring(0, [Math]::Min(180, $_.Message.Length))) -ForegroundColor DarkGray } }
    else { Write-Result PASS "No errors/warnings in the DM diag log in the window." | Out-Null }

    # 7. connectivity + inspection - endpoints DISCOVERED from this device, not hardcoded
    Write-Host "`n-- MMP-C endpoints (discovered) / TLS inspection --" -ForegroundColor Cyan
    $epMap = Get-MmpcEndpointMap -Linked $linked -Enrollments $enrollments -Hours $Hours -Live:$Live
    $epMap.Hosts | Format-Table Host, Sources -AutoSize | Out-Host

    if ($epMap.Live) {
        Write-Host "  Live discovery probe -> $MmpcDiscoveryUrl" -ForegroundColor DarkGray
        $epMap.Live | Format-List Url, HttpStatus, ErrorCode, Message, EnrollmentServiceUrl, EnrollmentPolicyServiceUrl, AuthenticationServiceUrl, Error | Out-Host
        if ($epMap.Live.EnrollmentServiceUrl) {
            Write-Result PASS "Discovery service returned live enrollment URLs (captured above)." | Out-Null
        }
        elseif ($epMap.Live.HttpStatus) {
            Write-Result INFO "Discovery endpoint reachable (HTTP $($epMap.Live.HttpStatus)); no service URLs without device auth - reachability/TLS still validated below." | Out-Null
        }
        else {
            Write-Result WARN "Discovery probe got no HTTP response ($($epMap.Live.Error)). Could be egress/proxy block - see TLS check below." | Out-Null
        }
    }

    foreach ($h in @($epMap.Hosts.Host)) {
        $t = Test-MmpcEndpoint -HostName $h
        $t | Format-List Host, TcpReachable, ServerCertIssuer, LikelyInspected, Error | Out-Host
        if (-not $t.TcpReachable)     { Write-Result FAIL "$h unreachable. Firewall/proxy egress problem." | Out-Null }
        elseif ($t.LikelyInspected)   { Write-Result FAIL "$h server cert issued by '$($t.ServerCertIssuer)' - looks like SSL inspection. This breaks MMP-C enrollment with a cert chain error. Exclude *.dm.microsoft.com from interception." | Out-Null }
        else                          { Write-Result PASS "$h reachable, cert chain looks genuine." | Out-Null }
    }
    if (-not $Live) {
        Write-Result INFO "Re-run with -DiscoverEndpoints to actively query the discovery service and surface the real enrollment/policy/auth URLs." | Out-Null
    }

    # ---- summary tally (the PASS/WARN/FAIL roll-up promised in .SYNOPSIS) ----
    Write-Host "`n-- Summary --" -ForegroundColor Cyan
    $byStatus = $script:Findings | Group-Object Status -AsHashTable -AsString
    foreach ($s in 'FAIL', 'WARN', 'PASS', 'INFO') {
        $n = if ($byStatus.ContainsKey($s)) { @($byStatus[$s]).Count } else { 0 }
        $c = switch ($s) { 'PASS' { 'Green' } 'WARN' { 'Yellow' } 'FAIL' { 'Red' } default { 'Gray' } }
        Write-Host ('  {0,-5} {1}' -f $s, $n) -ForegroundColor $c
    }
    $fails = @($script:Findings | Where-Object Status -eq 'FAIL')
    $warns = @($script:Findings | Where-Object Status -eq 'WARN')
    Write-Host ''
    if ($fails.Count) {
        Write-Host '  Issues to fix:' -ForegroundColor Red
        $fails | ForEach-Object { Write-Host "   - $($_.Message)" -ForegroundColor Red }
    }
    elseif ($warns.Count) {
        Write-Host '  No hard failures; review the warnings above.' -ForegroundColor Yellow
    }
    else {
        Write-Host '  MMP-C dual enrollment looks healthy.' -ForegroundColor Green
    }

    Write-Host "`n==== End ====`n" -ForegroundColor Cyan

    # return the findings to the pipeline so callers can capture/export them
    [pscustomobject]@{
        Findings    = $script:Findings
        Enrollments = $enrollments
        Linked      = $linked
        Endpoints   = $epMap
        Summary     = @{ Fail = $fails.Count; Warn = $warns.Count
                         Pass = @($script:Findings | Where-Object Status -eq 'PASS').Count }
    }
}

# ===========================================================================
# entry point
# ===========================================================================
$diag = Invoke-MmpcDiagnostics -Hours $EventLookbackHours -Live:$DiscoverEndpoints

if ($CollectCab)          { Invoke-MdmDiagCab -OutputPath $CabOutputPath }
if ($TriggerReEnrollment) { Invoke-MmpcReEnrollment }
if ($Json)                { Export-MmpcDiagnosticsJson -Diagnostics $diag -Path $JsonPath | Out-Null }

# Return the structured result only when asked, so an interactive run ends cleanly
# at the summary instead of dumping a half-rendered object:
#   $r = .\Invoke-MmpcDiagnostics.ps1 -PassThru
if ($PassThru) { $diag }