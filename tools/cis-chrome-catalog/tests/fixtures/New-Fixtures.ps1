#requires -Version 7.0
<#
.SYNOPSIS
    Regenerates the binary test fixtures (registry.pol, workbook.xlsx) in this folder.

.DESCRIPTION
    The fixtures are committed; run this only after changing the specs below. Each row in the
    workbook targets one pipeline outcome (see the 'Expect' comments), and every row's registry
    value appears in registry.pol unless it is meant to be NotInGpo.

    definitions.json is not generated here: it holds trimmed real Graph definitions plus a few
    synthetic clones (marked with '_fixture'), built once from the public catalog.
#>
param([string]$OutDir = $PSScriptRoot)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'FixtureHelpers.ps1')

$C = 'Software\Policies\Google\Chrome'
$pol = @(
    @{ Key = $C; ValueName = 'SyncDisabled'; Type = 'REG_DWORD'; Value = 1 }                       # boolean Enabled
    @{ Key = $C; ValueName = 'RemoteDebuggingAllowed'; Type = 'REG_DWORD'; Value = 0 }             # boolean Disabled
    @{ Key = $C; ValueName = 'DiskCacheSize'; Type = 'REG_DWORD'; Value = 250609664 }              # integer child
    @{ Key = $C; ValueName = 'ProxySettings'; Type = 'REG_SZ'; Value = '{"ProxyMode": "system"}' } # string child
    @{ Key = $C; ValueName = 'DownloadRestrictions'; Type = 'REG_DWORD'; Value = 4 }               # enum child
    @{ Key = $C; ValueName = 'AmbigPolicy'; Type = 'REG_DWORD'; Value = 1 }                        # Ambiguous
    @{ Key = $C; ValueName = 'TranslatorAPIAllowed'; Type = 'REG_DWORD'; Value = 0 }               # v141 only
    @{ Key = $C; ValueName = 'NoSuchPolicy'; Type = 'REG_DWORD'; Value = 1 }                       # NoDefinition
    @{ Key = $C; ValueName = 'UnsupportedValuePolicy'; Type = 'REG_DWORD'; Value = 7 }             # UnsupportedShape
    @{ Key = $C; ValueName = 'ConflictPolicy'; Type = 'REG_DWORD'; Value = 1 }                     # Conflict
    @{ Key = $C; ValueName = 'OrphanValue'; Type = 'REG_DWORD'; Value = 1 }                        # not in workbook
    @{ Key = "$C\ExtensionInstallBlocklist"; ValueName = '**delvals.'; Type = 'REG_SZ'; Value = ' ' }
    @{ Key = "$C\ExtensionInstallBlocklist"; ValueName = '1'; Type = 'REG_SZ'; Value = '*' }       # list
    @{ Key = "$C\CertificateTransparencyEnforcementDisabledForCas"; ValueName = '**delvals.'; Type = 'REG_SZ'; Value = ' ' } # list Disabled
    @{ Key = "$C\NativeMessagingBlocklist"; ValueName = '**delvals.'; Type = 'REG_SZ'; Value = ' ' } # L2 in workbook
    @{ Key = "$C\Recommended"; ValueName = 'OriginKeyedProcessesEnabled'; Type = 'REG_DWORD'; Value = 1 } # Recommended
    @{ Key = 'Software\Policies\Google\Update'; ValueName = 'AutoUpdateCheckPeriodMinutes'; Type = 'REG_DWORD'; Value = 60 } # OutOfScope
)
Write-TestRegistryPol -Path (Join-Path $OutDir 'registry.pol') -Entries $pol

$L1 = 'Level 1 (L1) - Corporate/Enterprise Environment (general use)'
$L2 = 'Level 2 (L2) - High Security/Sensitive Data Environment (limited functionality)'
$hk = 'HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Google'
function Rem([string]$State) { "To establish the recommended configuration via Group Policy, set the following UI path to ``$State``:`n`nComputer Configuration\..." }
function Aud([string]$Path, [string]$Value) {
    $tail = if ($Value) { " which should be set to ``$Value``" } else { '' }
    "Navigate to the UI Path articulated in the Remediation section and confirm it is set as prescribed. This group policy setting is backed by the following registry location$tail`:`n`n``````n$Path`n``````"
}

$header = @('Section #', 'Recommendation #', 'Profile', 'Title', 'Remediation Procedure', 'Audit Procedure')
$rows = @(
    , $header
    , @('1', $null, $null, 'Google Chrome', $null, $null)    # section heading: skipped
    , @('1', '1.1', $L1, "(L1) Ensure 'Disable synchronization of data with Google' is set to 'Enabled'", (Rem 'Enabled'), (Aud "$hk\Chrome:SyncDisabled" '1'))
    , @('1', '1.2', $L1, "(L1) Ensure 'Enable remote debugging' Is Disabled", (Rem 'Disabled'), (Aud "$hk\Chrome:RemoteDebuggingAllowed" '0'))
    , @('1', '1.3', $L1, "(L1) Ensure 'Set disk cache size, in bytes' is set to 'Enabled: 250609664'", (Rem 'Enabled: 250609664'), (Aud "$hk\Chrome:DiskCacheSize" '250609664'))
    , @('1', '1.4', $L1, "(L1) Ensure 'Proxy settings' is set to 'Enabled: system'", (Rem 'Enabled: {"ProxyMode": "system"}'), (Aud "$hk\Chrome:ProxySettings" $null))
    , @('1', '1.5', $L1, "(L1) Ensure 'Allow download restrictions' is set to 'Enabled: Block malicious downloads'", (Rem 'Enabled: Block malicious downloads'), (Aud "$hk\Chrome:DownloadRestrictions" '4'))
    , @('1', '1.6', $L1, "(L1) Ensure 'Configure extension installation blocklist' is set to 'Enabled: *'", (Rem 'Enabled'), (Aud "$hk\Chrome\ExtensionInstallBlocklist:1" '*'))
    , @('1', '1.7', $L1, "(L1) Ensure 'Disable CT enforcement for a list of subjectPublicKeyInfo hashes' is set to 'Disabled'", (Rem 'Disabled'), (Aud "$hk\Chrome\CertificateTransparencyEnforcementDisabledForCas" $null))
    , @('1', '1.8', $L1, "(L1) Ensure 'Ambiguous policy' is set to 'Enabled'", (Rem 'Enabled'), (Aud "$hk\Chrome:AmbigPolicy" '1'))
    , @('1', '1.9', $L1, @{ Inline = "(L1) Ensure 'Allow Translator API' Is Disabled" }, (Rem 'Disabled'), (Aud "$hk\Chrome:TranslatorAPIAllowed" '0'))
    , @('1', '1.10', $L1, "(L1) Ensure 'No such policy' is set to 'Enabled'", (Rem 'Enabled'), (Aud "$hk\Chrome:NoSuchPolicy" '1'))
    , @('1', '1.11', $L1, "(L1) Ensure 'Unsupported value policy' is set to 'Enabled'", (Rem 'Enabled'), (Aud "$hk\Chrome:UnsupportedValuePolicy" '7'))
    , @('1', '1.12', $L1, "(L1) Ensure 'Enable saving passwords to the password manager' is Explicitly Configured", 'To establish the recommended configuration via Group Policy, configure the following setting to either `Enabled` or `Disabled`', (Aud "$hk\Chrome:PasswordManagerEnabled" $null))
    , @('1', '1.13', $L1, "(L1) Ensure 'Conflict policy' is set to 'Disabled'", (Rem 'Disabled'), (Aud "$hk\Chrome:ConflictPolicy" '0'))
    , @('1', '1.14', $L1, "(L1) Ensure 'Enables origin-keyed process isolation by default' Is Enabled", (Rem 'Enabled'), (Aud "$hk\Chrome\Recommended:OriginKeyedProcessesEnabled" '1'))
    , @('1', '1.15', $L1, "(L1) Ensure 'Some manual check' is reviewed", 'Review the setting manually.', 'Confirm with your administrator.')
    , @('2', '2.1', $L1, "(L1) Ensure 'Auto-update check period override' is set to 'Enabled: 60'", (Rem 'Enabled: 60'), (Aud "HKEY_LOCAL_MACHINE\Software\Policies\Google\Update:AutoUpdateCheckPeriodMinutes" '60'))
    , @('3', '3.1', $L2, "(L2) Ensure 'Configure native messaging blocklist' is set to 'Enabled: *'", (Rem 'Enabled: *'), (Aud "$hk\Chrome\NativeMessagingBlocklist:1" '*'))
)
$sheets = [ordered]@{
    'Overview'          = @(, @('Overview'), , @('This spreadsheet is an Excel representation of the following CIS Benchmark: CIS Google Chrome Group Policy Benchmark v9.8.7.'))
    'Combined Profiles' = $rows
}
New-TestXlsx -Path (Join-Path $OutDir 'workbook.xlsx') -Sheets $sheets
"Fixtures written to $OutDir"
