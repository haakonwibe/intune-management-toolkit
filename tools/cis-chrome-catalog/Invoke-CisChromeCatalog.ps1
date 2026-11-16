#requires -Version 7.0
<#
.SYNOPSIS
    Builds an Intune Settings Catalog policy for the CIS Google Chrome Benchmark (L1 by default)
    from the CIS Build Kit GPO backup and benchmark workbook, and optionally creates it or
    compares it with an existing policy.

.DESCRIPTION
    Pipeline:
      1. Parse the Build Kit registry.pol (PReg) and keep Software\Policies\Google\Chrome (+ list subkeys).
      2. Read the CIS workbook; keep recommendations whose Profile matches -ProfilePattern and
         join them to registry.pol on the registry value name from the audit text.
      3. Load chromeintune* setting definitions (Graph beta, or the -DefinitionsPath cache) and
         keep root, device-scope, non-'_recommended' definitions in -DefinitionNamespace.
      4. Map each value to the one definition whose id ends with '_<lowercase name>' and build the
         setting instance from the definition's structure. 0 or >1 matches are flagged, never guessed.
      5. Write policy.json and coverage.md (every in-profile recommendation, with status).
      6. -Create      POST the policy (windows10 / mdm, unassigned). Without it nothing is written to Graph.
      7. -CompareTo   GET an existing policy with settings and report Missing / WrongValue / Extra.

.PARAMETER GpoBackupPath
    The Build Kit GPO backup folder ({GUID}), or the registry.pol file itself
    ({GUID}\DomainSysvol\GPO\Machine\registry.pol).

.PARAMETER WorkbookPath
    CIS benchmark workbook (.xlsx). The sheet with a 'Profile' column is used unless -WorksheetName is given.

.PARAMETER DefinitionNamespace
    ADMX namespaces to match against. Default: 'chromeintunev1', 'chromeintunev141'. Older Chrome
    policies are published in chromeintunev1 and newer ones only in chromeintunev141; the two share
    no policy names. A policy found in more than one selected namespace is reported Ambiguous.
    NoDefinition rows in coverage.md name any matching definition outside the selection.

.PARAMETER DefinitionsPath
    JSON cache of definitions. Read when it exists (fully offline run); otherwise definitions are
    fetched from Graph and saved here. -RefreshDefinitions forces a fetch.

.PARAMETER Create
    Create the policy in Intune. Honors -WhatIf. Refuses if a policy with the same name exists
    unless -Force.

.PARAMETER UpdatePolicyId
    Replace the settings of an existing windows10/mdm Settings Catalog policy with the mapped set
    (PUT). Keeps the policy's name (unless -PolicyName is given), scope tags and assignments.
    Honors -WhatIf. Mutually exclusive with -Create.

.PARAMETER SupplementalValuesPath
    .psd1 hashtable of extra Chrome registry values the Build Kit does not set: newer workbook items
    or org-specific values. Policy name -> integer (REG_DWORD), string (REG_SZ) or string array
    (list policy). They go through the same definition matching and checks, and coverage.md notes
    the source. See supplemental.example.psd1.

.PARAMETER CompareTo
    Id of an existing Settings Catalog policy to diff against the expected settings.

.EXAMPLE
    # Dry run: writes policy.json + coverage.md, no changes in Intune
    .\Invoke-CisChromeCatalog.ps1 -GpoBackupPath '.\Build Kit_Level_1\{F953080B-...}' -WorkbookPath .\CIS_Google_Chrome_Group_Policy_Benchmark_v1.1.1.xlsx

.EXAMPLE
    # Cache definitions for offline reruns
    .\Invoke-CisChromeCatalog.ps1 -GpoBackupPath $gpo -WorkbookPath $xlsx -DefinitionsPath .\out\definitions.json

.EXAMPLE
    .\Invoke-CisChromeCatalog.ps1 -GpoBackupPath $gpo -WorkbookPath $xlsx -CompareTo 1a2b3c4d-...

.EXAMPLE
    .\Invoke-CisChromeCatalog.ps1 -GpoBackupPath $gpo -WorkbookPath $xlsx -Create -WhatIf

.EXAMPLE
    # Add values the Build Kit lacks and push the full set to the existing policy
    .\Invoke-CisChromeCatalog.ps1 -GpoBackupPath $gpo -WorkbookPath $xlsx -SupplementalValuesPath .\supplemental.psd1 -UpdatePolicyId 53ebccb7-...

.NOTES
    Author : Haakon Wibe
    Graph  : DeviceManagementConfiguration.Read.All (definitions, -CompareTo),
             DeviceManagementConfiguration.ReadWrite.All (-Create, -UpdatePolicyId)
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [string]$GpoBackupPath,

    [Parameter(Mandatory)]
    [string]$WorkbookPath,

    [string]$OutputPath = (Join-Path (Get-Location) 'cis-chrome-catalog-out'),

    [string]$WorksheetName,

    [string]$ProfilePattern = '^\s*Level 1\b',

    [string[]]$DefinitionNamespace = @('chromeintunev1', 'chromeintunev141'),

    [string]$DefinitionsPath,

    [switch]$RefreshDefinitions,

    [string]$BenchmarkVersion,

    [string]$PolicyName,

    [switch]$Create,

    [string]$CompareTo,

    [string]$UpdatePolicyId,

    [string]$SupplementalValuesPath,

    [switch]$Force
)

$ErrorActionPreference = 'Stop'
if ($Create -and $UpdatePolicyId) { throw '-Create and -UpdatePolicyId are mutually exclusive.' }
$needWrite = [bool]($Create -or $UpdatePolicyId)
Import-Module (Join-Path $PSScriptRoot 'CisChromeCatalog.psm1')
Import-Module (Join-Path $PSScriptRoot '..\..\modules\IntuneToolkit\IntuneToolkit.psd1') -DisableNameChecking

function Connect-CisGraph {
    param([switch]$Write)
    $scope = if ($Write) { 'DeviceManagementConfiguration.ReadWrite.All' } else { 'DeviceManagementConfiguration.Read.All' }
    $ctx = Get-MgContext -ErrorAction SilentlyContinue
    $ok = $ctx -and ($ctx.Scopes -contains $scope -or (-not $Write -and $ctx.Scopes -contains 'DeviceManagementConfiguration.ReadWrite.All'))
    if ($ok) { return }
    Connect-IntuneGraph -PermissionLevel Custom -AdditionalScopes $scope -NoWelcome -Quiet | Out-Null
}

# --- 1. registry.pol -----------------------------------------------------------------------
$gpoItem = Get-Item -LiteralPath $GpoBackupPath
$polPath = if ($gpoItem.PSIsContainer) { Join-Path $gpoItem.FullName 'DomainSysvol\GPO\Machine\registry.pol' } else { $gpoItem.FullName }
if (-not (Test-Path -LiteralPath $polPath)) { throw "registry.pol not found at '$polPath'" }
$buildKit = $null
$bkup = Join-Path (Split-Path (Split-Path (Split-Path (Split-Path $polPath)))) 'bkupInfo.xml'
if (Test-Path -LiteralPath $bkup) {
    try { $buildKit = ([xml](Get-Content -LiteralPath $bkup -Raw)).BackupInst.Comment.'#cdata-section' } catch { }
}

$entries = @(Read-RegistryPolFile -Path $polPath)
$gpo = @(ConvertTo-ChromeGpoPolicy -Entries $entries)
Write-IntuneLog "registry.pol: $($entries.Count) entries -> $(@($gpo | Where-Object Kind -ne 'OutOfScope').Count) Chrome policies, $(@($gpo | Where-Object Kind -eq 'OutOfScope').Count) outside Chrome"

$supplementalName = $null
if ($SupplementalValuesPath) {
    $supplementalName = Split-Path $SupplementalValuesPath -Leaf
    $supplemental = Import-PowerShellDataFile -LiteralPath $SupplementalValuesPath
    $gpo = @(Add-SupplementalGpoPolicy -GpoPolicies $gpo -Values $supplemental -SourceName $supplementalName)
    Write-IntuneLog "Supplemental values: $($supplemental.Count) from $supplementalName"
}

# --- 2. workbook ---------------------------------------------------------------------------
$recs = @(Import-CisBenchmarkWorkbook -Path $WorkbookPath -WorksheetName $WorksheetName -ProfilePattern $ProfilePattern)
$inProfile = @($recs | Where-Object InProfile)
if (-not $inProfile) { throw "No workbook recommendations match profile pattern '$ProfilePattern'." }
if (-not $BenchmarkVersion) { $BenchmarkVersion = Get-CisBenchmarkVersion -Path $WorkbookPath }
if (-not $BenchmarkVersion) { throw 'Benchmark version not found in the workbook; pass -BenchmarkVersion.' }
$profileShort = ($inProfile | ForEach-Object { if ($_.Profile -match '\((?<s>L\d)\)') { $Matches.s } } | Select-Object -Unique) -join '+'
if (-not $profileShort) { $profileShort = 'profile' }
Write-IntuneLog "Workbook: $($recs.Count) recommendations, $($inProfile.Count) in $profileShort (benchmark v$BenchmarkVersion)"

# --- 3. definitions ------------------------------------------------------------------------
$source = $null
if ($DefinitionsPath -and (Test-Path -LiteralPath $DefinitionsPath) -and -not $RefreshDefinitions) {
    $definitions = @(Get-Content -LiteralPath $DefinitionsPath -Raw | ConvertFrom-Json -Depth 100)
    $source = "file $DefinitionsPath"
} else {
    Connect-CisGraph -Write:$needWrite
    Write-IntuneLog 'Fetching chromeintune* setting definitions from Graph...'
    try { $definitions = @(Get-ChromeSettingDefinitionFromGraph) }
    catch { throw "Failed to fetch setting definitions: $_" }
    $source = "Graph beta /deviceManagement/configurationSettings ($(Get-Date -Format 'yyyy-MM-dd HH:mm'))"
    if ($DefinitionsPath) {
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent ([IO.Path]::GetFullPath($DefinitionsPath))) -WhatIf:$false | Out-Null
        $definitions | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $DefinitionsPath -Encoding utf8 -WhatIf:$false
        Write-IntuneLog "Saved definitions cache to $DefinitionsPath"
    }
}
$index = New-ChromeDefinitionIndex -Definitions $definitions -Namespace $DefinitionNamespace
Write-IntuneLog "Definitions: $($definitions.Count) chromeintune*, $($index.Roots.Count) candidate roots in $($index.Namespaces -join ', ')"

# --- 4. map --------------------------------------------------------------------------------
$result = Invoke-CisChromeMapping -Recommendations $recs -GpoPolicies $gpo -Index $index
if (-not $PolicyName) { $PolicyName = "CIS Google Chrome Benchmark v$BenchmarkVersion - $profileShort" }
$counts = $result.Coverage | Group-Object Status | ForEach-Object { "$($_.Name)=$($_.Count)" }
$descriptionHeader = "CIS Google Chrome Benchmark v$BenchmarkVersion ($profileShort). Generated by tools/cis-chrome-catalog on $(Get-Date -Format 'yyyy-MM-dd')" +
    $(if ($buildKit) { " from '$buildKit'" } else { '' }) +
    $(if ($supplementalName) { " + supplemental values ($supplementalName)" } else { '' }) +
    ". $($result.Settings.Count) settings."
$description = New-CisChromePolicyDescription -Header $descriptionHeader -Coverage $result.Coverage
$body = New-CisChromePolicyBody -Name $PolicyName -Description $description -Settings $result.Settings

# --- 5. outputs ----------------------------------------------------------------------------
New-Item -ItemType Directory -Force -Path $OutputPath -WhatIf:$false | Out-Null
$policyFile = Join-Path $OutputPath 'policy.json'
$coverageFile = Join-Path $OutputPath 'coverage.md'
$body | ConvertTo-Json -Depth 50 | Set-Content -LiteralPath $policyFile -Encoding utf8 -WhatIf:$false
$meta = [ordered]@{
    Title                  = "$PolicyName - coverage"
    'Generated'            = (Get-Date -Format 'yyyy-MM-dd HH:mm')
    'Workbook'             = "$(Split-Path $WorkbookPath -Leaf) (benchmark v$BenchmarkVersion)"
    'Profile filter'       = "$ProfilePattern -> $($inProfile.Count) recommendations"
    'GPO backup'           = $(if ($buildKit) { "$buildKit ($polPath)" } else { $polPath })
    'Supplemental values'  = $(if ($SupplementalValuesPath) { [IO.Path]::GetFullPath($SupplementalValuesPath) } else { 'none' })
    'Definition source'    = "$source; $($definitions.Count) chromeintune* definitions"
    'Definition namespace' = ($index.Namespaces -join ', ')
}
ConvertTo-CoverageMarkdown -Result $result -Metadata $meta | Set-Content -LiteralPath $coverageFile -Encoding utf8 -WhatIf:$false
Write-IntuneLog "Coverage: $($counts -join ', ')" -Level $(if (@($result.Coverage | Where-Object Status -ne 'Mapped').Count) { 'Warning' } else { 'Success' })
Write-IntuneLog "Wrote $policyFile ($($result.Settings.Count) settings) and $coverageFile"

$elsewhere = @($result.Coverage | Where-Object { $_.Status -eq 'NoDefinition' -and ($_.Notes -match "namespace '.+' not selected") })
if ($elsewhere) {
    $ns = $elsewhere.Notes | Select-String -Pattern "namespace '([^']+)' not selected" -AllMatches | ForEach-Object { $_.Matches.Groups[1].Value } | Sort-Object -Unique
    Write-IntuneLog "$($elsewhere.Count) NoDefinition item(s) exist in namespace(s) $($ns -join ', '). Add them with -DefinitionNamespace $((@($index.Namespaces) + $ns | Select-Object -Unique) -join ',')" -Level Warning
}

$output = [ordered]@{
    PolicyName      = $PolicyName
    SettingCount    = $result.Settings.Count
    Coverage        = $result.Coverage
    UnmatchedGpo    = $result.UnmatchedGpo
    PolicyFile      = $policyFile
    CoverageFile    = $coverageFile
    CreatedPolicyId = $null
    UpdatedPolicyId = $null
    Diff            = $null
    CompareFile     = $null
}

# --- 6. compare ----------------------------------------------------------------------------
if ($CompareTo) {
    Connect-CisGraph -Write:$needWrite
    try { $existing = Get-CisConfigurationPolicy -PolicyId $CompareTo }
    catch { throw "Failed to read policy '$CompareTo': $_" }
    $diff = @(Compare-CisChromePolicy -ExpectedSettings $result.Settings -Policy $existing -Coverage $result.Coverage -Namespace $index.Namespaces)
    $compareFile = Join-Path $OutputPath "compare-$CompareTo.md"
    ConvertTo-CompareMarkdown -Diff $diff -Metadata ([ordered]@{
            Title     = "Compare: '$($existing.name)' vs $PolicyName"
            Policy    = "$($existing.name) ($CompareTo)"
            Generated = (Get-Date -Format 'yyyy-MM-dd HH:mm')
        }) | Set-Content -LiteralPath $compareFile -Encoding utf8 -WhatIf:$false
    $dc = foreach ($r in 'Missing', 'WrongValue', 'Extra', 'Match') { "$r=$(@($diff | Where-Object Result -eq $r).Count)" }
    Write-IntuneLog "Compare '$($existing.name)': $($dc -join ', ') -> $compareFile" -Level $(if (@($diff | Where-Object Result -ne 'Match').Count) { 'Warning' } else { 'Success' })
    $output.Diff = $diff
    $output.CompareFile = $compareFile
}

# --- 7. create -----------------------------------------------------------------------------
if ($Create) {
    if ($result.Settings.Count -eq 0) { throw 'No mapped settings; refusing to create an empty policy.' }
    if ($PSCmdlet.ShouldProcess("Intune (Graph beta)", "Create Settings Catalog policy '$PolicyName' with $($result.Settings.Count) settings")) {
        Connect-CisGraph -Write
        $nameFilter = { param($p) $p.name -eq $PolicyName }
        $dupes = @(Get-CisGraphCollection -Uri "https://graph.microsoft.com/beta/deviceManagement/configurationPolicies?`$select=id,name" -Where $nameFilter)
        if ($dupes -and -not $Force) {
            throw "A policy named '$PolicyName' already exists ($($dupes.id -join ', ')). Use -CompareTo, -PolicyName, or -Force."
        }
        try { $created = Invoke-CisGraphRequest -Method POST -Uri 'https://graph.microsoft.com/beta/deviceManagement/configurationPolicies' -Body $body }
        catch { throw "Policy creation failed: $_" }
        Write-IntuneLog "Created '$($created.name)' ($($created.id)) - unassigned." -Level Success
        $output.CreatedPolicyId = $created.id
    }
} elseif ($UpdatePolicyId) {
    if ($result.Settings.Count -eq 0) { throw 'No mapped settings; refusing to empty an existing policy.' }
    Connect-CisGraph -Write
    try {
        $target = Invoke-CisGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/deviceManagement/configurationPolicies('$UpdatePolicyId')?`$select=id,name,platforms,technologies,roleScopeTagIds,settingCount,templateReference"
    } catch { throw "Failed to read policy '$UpdatePolicyId': $_" }
    if ($target.platforms -ne 'windows10' -or $target.technologies -notmatch '\bmdm\b') {
        throw "Policy '$($target.name)' is $($target.platforms)/$($target.technologies), not a windows10/mdm Settings Catalog policy."
    }
    $templateId = if ($target.psobject.Properties.Name -contains 'templateReference' -and $target.templateReference) { $target.templateReference.templateId }
    if ($templateId) { throw "Policy '$($target.name)' was created from template $templateId; refusing to replace its settings." }
    $updateName = if ($PSBoundParameters.ContainsKey('PolicyName')) { $PolicyName } else { $target.name }
    $putBody = New-CisChromePolicyBody -Name $updateName -Description $description -Settings $result.Settings
    $putBody.roleScopeTagIds = @($target.roleScopeTagIds)
    if ($PSCmdlet.ShouldProcess("'$($target.name)' ($UpdatePolicyId)", "Replace its $($target.settingCount) settings with $($result.Settings.Count) mapped settings")) {
        try { $null = Invoke-CisGraphRequest -Method PUT -Uri "https://graph.microsoft.com/beta/deviceManagement/configurationPolicies('$UpdatePolicyId')" -Body $putBody }
        catch { throw "Policy update failed: $_" }
        Write-IntuneLog "Updated '$updateName' ($UpdatePolicyId): $($target.settingCount) -> $($result.Settings.Count) settings." -Level Success
        $output.UpdatedPolicyId = $UpdatePolicyId
    }
} else {
    Write-IntuneLog 'Dry run: nothing was written to Intune (use -Create or -UpdatePolicyId).'
}

[pscustomobject]$output
