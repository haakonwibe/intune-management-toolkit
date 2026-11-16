#requires -Version 7.0
<#
.SYNOPSIS
    Library for building an Intune Settings Catalog policy from the CIS Google Chrome Benchmark.

.DESCRIPTION
    Pure functions (no Graph calls except the thin wrappers in the Graph region) so every stage of
    the pipeline can be exercised by Pester against fixtures:

        registry.pol (PReg)  ->  Chrome policy values
        CIS workbook (.xlsx) ->  L1 recommendations (CIS ID, title, profile, registry value name)
        Graph definitions    ->  chromeintunev1~ definitions (recommended variants excluded)
        join + map           ->  Settings Catalog setting instances + coverage rows
        policy               ->  diff (Missing / WrongValue / Extra)

.NOTES
    Author  : Haakon Wibe
    License : MIT
#>

Set-StrictMode -Version Latest

$script:ChromePolicyRoot = 'Software\Policies\Google\Chrome'
$script:DefinitionPrefix = 'chromeintunev1~'
$script:XlsxNs = 'http://schemas.openxmlformats.org/spreadsheetml/2006/main'
$script:XlsxRelNs = 'http://schemas.openxmlformats.org/officeDocument/2006/relationships'
$script:PkgRelNs = 'http://schemas.openxmlformats.org/package/2006/relationships'

#region registry.pol (PReg) parsing

$script:RegTypeNames = @{
    0  = 'REG_NONE'
    1  = 'REG_SZ'
    2  = 'REG_EXPAND_SZ'
    3  = 'REG_BINARY'
    4  = 'REG_DWORD'
    5  = 'REG_DWORD_BIG_ENDIAN'
    7  = 'REG_MULTI_SZ'
    11 = 'REG_QWORD'
}

function Read-RegistryPolFile {
    <#
    .SYNOPSIS
        Parses a Group Policy registry.pol (PReg v1) file into one object per entry.

    .DESCRIPTION
        Format: 'PReg' signature + uint32 version (1), then repeated entries of
            [key;valueName;type;size;data]
        where the brackets/semicolons are UTF-16LE characters, key and valueName are
        null-terminated UTF-16LE strings and type/size are little-endian uint32.

    .OUTPUTS
        PSCustomObject: Key, ValueName, Type, TypeName, Size, Value
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $bytes = [System.IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $Path).ProviderPath)
    if ($bytes.Length -lt 8 -or [System.Text.Encoding]::ASCII.GetString($bytes, 0, 4) -ne 'PReg') {
        throw "Not a registry.pol file (missing 'PReg' signature): $Path"
    }
    $version = [BitConverter]::ToUInt32($bytes, 4)
    if ($version -ne 1) { throw "Unsupported registry.pol version $version in $Path" }

    $pos = 8
    while ($pos -lt $bytes.Length) {
        # Tolerate trailing padding
        if ($pos + 1 -ge $bytes.Length) { break }
        $open = [char][BitConverter]::ToUInt16($bytes, $pos)
        if ($open -eq [char]0) { break }
        if ($open -ne '[') { throw "Malformed registry.pol: expected '[' at offset $pos, found 0x{0:X4}" -f [int]$open }
        $pos += 2

        $key = Read-PolString -Bytes $bytes -Position ([ref]$pos)
        Assert-PolChar -Bytes $bytes -Position ([ref]$pos) -Expected ';'
        $valueName = Read-PolString -Bytes $bytes -Position ([ref]$pos)
        Assert-PolChar -Bytes $bytes -Position ([ref]$pos) -Expected ';'
        $type = [BitConverter]::ToUInt32($bytes, $pos); $pos += 4
        Assert-PolChar -Bytes $bytes -Position ([ref]$pos) -Expected ';'
        $size = [BitConverter]::ToUInt32($bytes, $pos); $pos += 4
        Assert-PolChar -Bytes $bytes -Position ([ref]$pos) -Expected ';'
        if ($pos + $size -gt $bytes.Length) { throw "Malformed registry.pol: data for '$key\$valueName' runs past end of file" }
        $data = [byte[]]::new($size)
        if ($size -gt 0) { [Array]::Copy($bytes, $pos, $data, 0, $size) }
        $pos += $size
        Assert-PolChar -Bytes $bytes -Position ([ref]$pos) -Expected ']'

        [pscustomobject]@{
            Key       = $key
            ValueName = $valueName
            Type      = [int]$type
            TypeName  = $script:RegTypeNames[[int]$type] ?? "REG_TYPE_$type"
            Size      = [int]$size
            Value     = ConvertFrom-PolData -Type $type -Data $data
        }
    }
}

function Read-PolString {
    # Reads a UTF-16LE string up to (and consuming) its null terminator. Stops without consuming
    # at ';' to tolerate writers that omit the terminator.
    param([byte[]]$Bytes, [ref]$Position)
    $sb = [System.Text.StringBuilder]::new()
    while ($true) {
        if ($Position.Value + 1 -ge $Bytes.Length) { throw "Malformed registry.pol: unterminated string at offset $($Position.Value)" }
        $c = [char][BitConverter]::ToUInt16($Bytes, $Position.Value)
        if ($c -eq [char]0) { $Position.Value += 2; break }
        if ($c -eq ';') { break }
        [void]$sb.Append($c)
        $Position.Value += 2
    }
    $sb.ToString()
}

function Assert-PolChar {
    param([byte[]]$Bytes, [ref]$Position, [char]$Expected)
    if ($Position.Value + 1 -ge $Bytes.Length) { throw "Malformed registry.pol: expected '$Expected' at end of file" }
    $c = [char][BitConverter]::ToUInt16($Bytes, $Position.Value)
    if ($c -ne $Expected) { throw ("Malformed registry.pol: expected '{0}' at offset {1}, found 0x{2:X4}" -f $Expected, $Position.Value, [int]$c) }
    $Position.Value += 2
}

function ConvertFrom-PolData {
    param([uint32]$Type, [byte[]]$Data)
    switch ($Type) {
        { $_ -in 1, 2 } { return [System.Text.Encoding]::Unicode.GetString($Data).TrimEnd([char]0) }
        4 { if ($Data.Length -ge 4) { return [BitConverter]::ToUInt32($Data, 0) } else { return $null } }
        5 { if ($Data.Length -ge 4) { $r = $Data[0..3]; [Array]::Reverse($r); return [BitConverter]::ToUInt32([byte[]]$r, 0) } else { return $null } }
        7 { return , @([System.Text.Encoding]::Unicode.GetString($Data).TrimEnd([char]0).Split([char]0)) }
        11 { if ($Data.Length -ge 8) { return [BitConverter]::ToUInt64($Data, 0) } else { return $null } }
        default { return , $Data }
    }
}

function ConvertTo-ChromeGpoPolicy {
    <#
    .SYNOPSIS
        Groups registry.pol entries under Software\Policies\Google\Chrome into one object per policy.

    .DESCRIPTION
        Kinds:
          Scalar    value directly under Chrome (or Chrome\Recommended)
          List      Chrome\<Policy> subkey whose values are named 1..N (Chrome list policies)
          Disabled  Chrome\<Policy> subkey holding only '**delvals.' (GPO 'Disabled' for a list
                    policy), or '**del.<Policy>' under Chrome (GPO 'Disabled' with elements)
          Unsupported anything else (nested subkeys, non-numeric value names in a list key, ...)

        Entries outside the Chrome root are returned with Kind 'OutOfScope' so callers can report
        them instead of silently dropping them.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Entries
    )

    $root = $script:ChromePolicyRoot
    $policies = [ordered]@{}
    $add = {
        param($Name, $Kind, $Recommended, $Key, $Entry)
        $id = if ($Recommended) { "Recommended\$Name" } else { $Name }
        if (-not $policies.Contains($id)) {
            $policies[$id] = [pscustomobject]@{
                PolicyName  = $Name
                Kind        = $Kind
                Recommended = [bool]$Recommended
                RegistryKey = $Key
                ValueType   = $null
                Value       = $null
                Entries     = [System.Collections.Generic.List[object]]::new()
                Notes       = [System.Collections.Generic.List[string]]::new()
            }
        }
        $policies[$id].Entries.Add($Entry)
        $policies[$id]
    }

    foreach ($e in $Entries) {
        $key = $e.Key.TrimEnd('\')
        if (-not ($key -ieq $root -or $key.StartsWith("$root\", [StringComparison]::OrdinalIgnoreCase))) {
            $p = & $add $e.ValueName 'OutOfScope' $false $key $e
            $p.ValueType = $e.TypeName; $p.Value = $e.Value
            continue
        }

        $rel = if ($key.Length -gt $root.Length) { $key.Substring($root.Length + 1) } else { '' }
        $recommended = $false
        if ($rel -ieq 'Recommended' -or $rel -like 'Recommended\*') {
            $recommended = $true
            $rel = if ($rel.Length -gt 'Recommended'.Length) { $rel.Substring('Recommended'.Length + 1) } else { '' }
        }

        if ($rel -eq '') {
            # Value directly under the Chrome (or Recommended) key
            if ($e.ValueName -like '`*`*del.*') {
                $name = $e.ValueName.Substring(6)
                $p = & $add $name 'Disabled' $recommended $key $e
                $p.Notes.Add("GPO deletes the value ('**del.$name'): policy Disabled")
            } elseif ($e.ValueName.StartsWith('**')) {
                $p = & $add $e.ValueName 'Unsupported' $recommended $key $e
                $p.Notes.Add("Unhandled registry.pol directive '$($e.ValueName)' on the Chrome key")
            } else {
                $p = & $add $e.ValueName 'Scalar' $recommended $key $e
                $p.ValueType = $e.TypeName; $p.Value = $e.Value
            }
            continue
        }

        $segments = $rel.Split('\')
        $name = $segments[0]
        $p = & $add $name 'List' $recommended "$root\$(if ($recommended) { 'Recommended\' })$name" $e
        if ($segments.Count -gt 1) {
            $p.Kind = 'Unsupported'
            $p.Notes.Add("Nested subkey '$rel' is not a Chrome list policy")
        }
    }

    foreach ($p in $policies.Values) {
        if ($p.Kind -ne 'List') { continue }
        $directives = @($p.Entries | Where-Object { $_.ValueName.StartsWith('**') })
        $items = @($p.Entries | Where-Object { -not $_.ValueName.StartsWith('**') })
        $unknownDirectives = @($directives | Where-Object { $_.ValueName -ne '**delvals.' })
        if ($unknownDirectives) {
            $p.Kind = 'Unsupported'
            $p.Notes.Add("Unhandled directive(s): $(($unknownDirectives.ValueName | Sort-Object -Unique) -join ', ')")
            continue
        }
        if (-not $items) {
            $p.Kind = 'Disabled'
            $p.Notes.Add("List key holds only '**delvals.': policy Disabled")
            continue
        }
        $nonNumeric = @($items | Where-Object { $_.ValueName -notmatch '^\d+$' })
        $nonString = @($items | Where-Object { $_.TypeName -notin 'REG_SZ', 'REG_EXPAND_SZ' })
        if ($nonNumeric -or $nonString) {
            $p.Kind = 'Unsupported'
            if ($nonNumeric) { $p.Notes.Add("Subkey has non-numeric value names ($(($nonNumeric.ValueName) -join ', ')); not a list policy") }
            if ($nonString) { $p.Notes.Add("List entries must be REG_SZ; found $(($nonString.TypeName | Sort-Object -Unique) -join ', ')") }
            continue
        }
        $p.ValueType = 'REG_SZ'
        $p.Value = [string[]]@($items | Sort-Object { [long]$_.ValueName } | ForEach-Object { [string]$_.Value })
    }

    foreach ($p in $policies.Values) {
        if ($p.Kind -eq 'Scalar' -and $p.Entries.Count -gt 1) {
            $p.Kind = 'Unsupported'
            $p.Notes.Add('Value appears more than once in registry.pol')
        }
        if ($p.Kind -eq 'Scalar' -and $p.ValueType -notin 'REG_DWORD', 'REG_SZ', 'REG_EXPAND_SZ', 'REG_QWORD') {
            $p.Kind = 'Unsupported'
            $p.Notes.Add("Registry type $($p.ValueType) is not supported")
        }
        $p | Add-Member -NotePropertyName Display -NotePropertyValue (Format-GpoPolicyValue -Policy $p) -Force
        # 'Chrome:SyncDisabled', 'Chrome\ExtensionInstallBlocklist', 'Update:AutoUpdateCheckPeriodMinutes'
        $isKeyPolicy = $p.RegistryKey.EndsWith("\$($p.PolicyName)", [StringComparison]::OrdinalIgnoreCase)
        $ref = Format-RegistryReference -Path "HKLM\$($p.RegistryKey)" -ValueName $(if ($isKeyPolicy) { $null } else { $p.PolicyName })
        $p | Add-Member -NotePropertyName RegistryRef -NotePropertyValue $ref -Force
    }

    $policies.Values
}

function Format-GpoPolicyValue {
    param($Policy)
    switch ($Policy.Kind) {
        'Scalar' {
            if ($Policy.ValueType -in 'REG_SZ', 'REG_EXPAND_SZ') { return "`"$($Policy.Value)`" ($($Policy.ValueType))" }
            return "$($Policy.Value) ($($Policy.ValueType))"
        }
        'List' { return "[$($Policy.Value -join ', ')] (list)" }
        'Disabled' { return 'Disabled' }
        'OutOfScope' { return "$($Policy.Value) ($($Policy.ValueType))" }
        default { return '(unsupported)' }
    }
}

#endregion

#region CIS workbook

function Import-CisBenchmarkWorkbook {
    <#
    .SYNOPSIS
        Reads CIS recommendations from the benchmark workbook, flagging the ones in the profile.

    .DESCRIPTION
        Uses the worksheet that has a Profile column ('Combined Profiles' in CIS exports) unless
        -WorksheetName is given. Section-heading rows (no recommendation number) are skipped.
        Every recommendation is returned; InProfile marks the ones matching -ProfilePattern, so
        callers can explain GPO values that belong to another profile.

        The registry location is extracted from the audit text, accepting every form CIS uses:
            HKLM\SOFTWARE\Policies\Google\Chrome:ValueName
            HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Google\Chrome\ValueName
            HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Google\Chrome\ListPolicy\<number>
            HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Google\Chrome\ListPolicy:1
            HKEY_LOCAL_MACHINE\Software\Policies\Google\Chrome\Recommended:ValueName
        Each reduces to a single PolicyName, the join key against registry.pol.

    .OUTPUTS
        PSCustomObject: CisId, Title, Profile, InProfile, ExpectedState, RemediationText,
                        AuditValue, RegistryPath, PolicyName, Recommended,
                        Scope ('Chrome' | 'OutOfScope' | 'None'), Notes
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [string]$WorksheetName,

        # Regex matched against the Profile column. Default keeps Level 1 rows.
        [string]$ProfilePattern = '^\s*Level 1\b',

        [string]$IdColumn = 'Recommendation #',
        [string]$TitleColumn = 'Title',
        [string]$ProfileColumn = 'Profile',
        [string]$AuditColumn = 'Audit Procedure',
        # Optional: used for the expected Enabled/Disabled state cross-check.
        [string]$RemediationColumn = 'Remediation Procedure'
    )

    if (-not $WorksheetName) {
        foreach ($name in (Read-XlsxWorksheet -Path $Path -ListWorksheets)) {
            $first = Read-XlsxWorksheet -Path $Path -WorksheetName $name | Select-Object -First 1
            if ($first -and $first.psobject.Properties.Name -contains $ProfileColumn) { $WorksheetName = $name; break }
        }
        if (-not $WorksheetName) {
            throw "No worksheet in '$Path' has a '$ProfileColumn' column. Pass -WorksheetName and/or -ProfileColumn."
        }
    }

    $rows = @(Read-XlsxWorksheet -Path $Path -WorksheetName $WorksheetName)
    if (-not $rows) { throw "Worksheet '$WorksheetName' is empty." }
    $headers = $rows[0].psobject.Properties.Name
    foreach ($col in $IdColumn, $TitleColumn, $ProfileColumn, $AuditColumn) {
        if ($headers -notcontains $col) { throw "Worksheet '$WorksheetName' has no '$col' column. Columns: $($headers -join ', ')" }
    }

    $cell = { param($Row, $Column) $v = $Row.$Column; if ($null -eq $v) { '' } else { "$v".Trim() } }
    foreach ($row in $rows) {
        $id = & $cell $row $IdColumn
        if (-not $id) { continue }
        $profileName = & $cell $row $ProfileColumn

        $title = & $cell $row $TitleColumn
        $audit = & $cell $row $AuditColumn
        $reg = Get-CisRegistryReference -AuditText $audit
        $notes = $reg.Notes

        # Expected GPO state: the remediation text is authoritative (CIS titles are sometimes
        # wrong, e.g. a title saying 'Disabled' while remediation says 'Enabled: Do not ...').
        $remediationState = if ($RemediationColumn -and $headers -contains $RemediationColumn) {
            Get-CisRemediationState -Text (& $cell $row $RemediationColumn)
        }
        $titleState = Get-CisTitleState -Title $title
        $expectedState = if ($remediationState) { $remediationState.State } else { $titleState }
        if ($remediationState -and $titleState -and $titleState -ne $remediationState.State) {
            $notes.Add("CIS title says '$titleState' but remediation says '$($remediationState.Text)'; remediation used")
        }
        if ($remediationState -and $remediationState.Either) { $notes.Add('CIS accepts either Enabled or Disabled') }

        $auditValue = if ($audit -match '(?is)should be set to\s+`(?<v>[^`]*)`') { $Matches.v }

        [pscustomobject]@{
            CisId           = $id
            Title           = $title
            Profile         = $profileName
            InProfile       = $profileName -match $ProfilePattern
            ExpectedState   = $expectedState
            RemediationText = if ($remediationState) { $remediationState.Text } else { $null }
            AuditValue      = $auditValue
            RegistryPath    = $reg.RegistryPath
            PolicyName      = $reg.PolicyName
            Recommended     = $reg.Recommended
            Scope           = $reg.Scope
            Notes           = $notes
        }
    }
}

function Get-CisRemediationState {
    # "...set the following UI path to `Enabled: Foo`" -> State 'Enabled', Text 'Enabled: Foo'
    param([AllowEmptyString()][string]$Text)
    $m = [regex]::Match($Text, '(?is)(?:UI path|setting)\s+(?:is\s+set\s+)?to\s+(?<either>either\s+)?[`''](?<s>(?:Enabled|Disabled)[^`'']*)[`'']')
    if (-not $m.Success) { return $null }
    $s = $m.Groups['s'].Value.Trim()
    $either = $m.Groups['either'].Success
    [pscustomobject]@{
        State  = if ($either) { $null } elseif ($s -match '^(?i)enabled') { 'Enabled' } else { 'Disabled' }
        Text   = if ($either) { 'Enabled or Disabled' } else { $s }
        Either = $either
    }
}

function Get-CisRegistryReference {
    <#
    .SYNOPSIS
        Extracts the Google policy registry reference from CIS audit text.
    #>
    [CmdletBinding()]
    param([AllowEmptyString()][string]$AuditText)

    $rx = '(?i)(?:HKLM|HKEY_LOCAL_MACHINE)\\SOFTWARE\\Policies\\Google(?<rest>(?:\\[\w{}<>\-]*)*)(?::(?<value>[\w{}\-]+))?'
    $found = [regex]::Matches($AuditText, $rx)
    $notes = [System.Collections.Generic.List[string]]::new()
    if ($found.Count -eq 0) {
        return [pscustomobject]@{ RegistryPath = $null; PolicyName = $null; Recommended = $false; Scope = 'None'; Notes = $notes }
    }

    $parsed = foreach ($m in $found) {
        $segments = @($m.Groups['rest'].Value.Split('\', [StringSplitOptions]::RemoveEmptyEntries))
        $value = $m.Groups['value'].Value
        $scope = if ($segments.Count -gt 0 -and $segments[0] -ieq 'Chrome') { 'Chrome' } else { 'OutOfScope' }
        $recommended = $false
        $rest = @($segments | Select-Object -Skip 1)
        if ($scope -eq 'Chrome' -and $rest.Count -gt 0 -and $rest[0] -ieq 'Recommended') {
            $recommended = $true
            $rest = @($rest | Select-Object -Skip 1)
        }
        # Policy name: list subkey if there is one, otherwise the value name.
        $name = if ($scope -eq 'OutOfScope') {
            if ($value) { $value } else { $segments[-1] }
        } elseif ($rest.Count -gt 0) { $rest[0] } else { $value }
        [pscustomobject]@{ Path = $m.Value.TrimEnd('\'); Name = $name; Scope = $scope; Recommended = $recommended }
    }

    $primary = $parsed[0]
    $others = @($parsed | Select-Object -Skip 1 | Where-Object { $_.Name -ne $primary.Name } | ForEach-Object Path | Select-Object -Unique)
    if ($others) { $notes.Add("Audit text also mentions: $($others -join '; ') (first path used)") }
    if (-not $primary.Name) { $notes.Add('Registry path found but no value name could be derived') }

    [pscustomobject]@{
        RegistryPath = $primary.Path
        PolicyName   = $primary.Name
        Recommended  = $primary.Recommended
        Scope        = if ($primary.Name) { $primary.Scope } else { 'None' }
        Notes        = $notes
    }
}

function Get-CisTitleState {
    # "Ensure 'X' is set to 'Enabled: Foo'" / "Ensure 'X' Is Disabled" -> 'Enabled' / 'Disabled'.
    # Only the text after the quoted display name is inspected. $null when no state is stated.
    param([AllowEmptyString()][string]$Title)
    if ($Title -match "(?i)'\s+(?:is|are)\b(?<rest>.*)$" -and $Matches.rest -match '(?i)\b(?<s>Enabled|Disabled)\b') {
        return $(if ($Matches.s -match '^(?i)enabled') { 'Enabled' } else { 'Disabled' })
    }
    $null
}

function Get-CisBenchmarkVersion {
    <#
    .SYNOPSIS
        Finds the benchmark version ('1.1.1') in the workbook Overview sheet, else the file name.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    foreach ($name in (Read-XlsxWorksheet -Path $Path -ListWorksheets)) {
        foreach ($row in (Read-XlsxWorksheet -Path $Path -WorksheetName $name | Select-Object -First 25)) {
            foreach ($v in $row.psobject.Properties.Value) {
                if ("$v" -match '(?i)Benchmark\s+v(?<v>\d+(?:\.\d+){1,3})') { return $Matches.v }
            }
        }
        break   # only the first sheet (Overview) is worth scanning
    }
    if ((Split-Path $Path -Leaf) -match '(?i)v(?<v>\d+(?:[._]\d+){1,3})') { return ($Matches.v -replace '_', '.') }
    $null
}

#endregion

#region Setting definitions

function Get-Prop {
    # Strict-mode-safe property read: $null when the object or the property is absent.
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Collections.IDictionary]) { return $Object[$Name] }
    $p = $Object.psobject.Properties[$Name]
    if ($p) { $p.Value } else { $null }
}

$script:DeviceIdPrefix = 'device_vendor_msft_policy_config_'
$script:OdataSetting = '#microsoft.graph.deviceManagementConfigurationSetting'
$script:OdataChoiceDef = '#microsoft.graph.deviceManagementConfigurationChoiceSettingDefinition'
$script:OdataSimpleDef = '#microsoft.graph.deviceManagementConfigurationSimpleSettingDefinition'
$script:OdataSimpleCollectionDef = '#microsoft.graph.deviceManagementConfigurationSimpleSettingCollectionDefinition'

function Get-DefinitionNamespace {
    <#
    .SYNOPSIS
        Returns the ADMX namespace of a Chrome definition id ('chromeintunev1'), or $null.

    .DESCRIPTION
        Real Settings Catalog ids carry a scope prefix:
            device_vendor_msft_policy_config_chromeintunev1~policy~googlechrome_syncdisabled
            user_vendor_msft_policy_config_chromeintunev1~policy~googlechrome_syncdisabled
        The bare 'chromeintunev1~...' form is accepted too. User-scope ids return $null:
        CIS Chrome settings are HKLM (device) settings.
    #>
    param([string]$Id)
    $rel = if ($Id.StartsWith($script:DeviceIdPrefix, [StringComparison]::OrdinalIgnoreCase)) { $Id.Substring($script:DeviceIdPrefix.Length) } else { $Id }
    if ($rel -match '^(?<ns>chromeintunev\d+)~') { return $Matches.ns.ToLowerInvariant() }
    $null
}

function New-ChromeDefinitionIndex {
    <#
    .SYNOPSIS
        Indexes Chrome setting definitions for name matching.

    .DESCRIPTION
        Roots     : root definitions (rootDefinitionId == id) in the selected namespaces,
                    device scope, excluding '_recommended' variants. These are match candidates.
        OtherRoots: every other Chrome root definition (other namespaces, recommended variants,
                    user scope). Never matched; used only to explain NoDefinition results.
        ById      : all definitions (children included) for child lookup.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Definitions,

        [string[]]$Namespace = @('chromeintunev1', 'chromeintunev141')
    )

    $selected = @($Namespace | ForEach-Object { $_.ToLowerInvariant().TrimEnd('~') })
    $byId = @{}
    $roots = [System.Collections.Generic.List[object]]::new()
    $other = [System.Collections.Generic.List[object]]::new()
    foreach ($d in $Definitions) {
        if (-not $d.id) { continue }
        $byId[$d.id] = $d
        $rootId = if ($d.psobject.Properties.Name -contains 'rootDefinitionId' -and $d.rootDefinitionId) { $d.rootDefinitionId } else { $d.id }
        if ($rootId -ne $d.id) { continue }
        $ns = Get-DefinitionNamespace -Id $d.id
        $isDevice = -not ($d.id -like 'user_*')
        if ($ns -and $ns -in $selected -and $isDevice -and $d.id -notmatch '_recommended') { $roots.Add($d) }
        elseif ($d.id -match 'chromeintunev\d+~') { $other.Add($d) }
    }
    [pscustomobject]@{
        Namespaces = $selected
        ById       = $byId
        Roots      = $roots
        OtherRoots = $other
    }
}

function Find-ChromeSettingDefinition {
    <#
    .SYNOPSIS
        Maps a Chrome policy (registry value / list key) name to its root definition.

    .DESCRIPTION
        Candidate = selected root definition whose id ends with '_' + lowercase policy name.
        Exactly one candidate -> Found. Zero -> NoDefinition, >1 -> Ambiguous. Never guesses.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PolicyName,
        [Parameter(Mandatory)]$Index
    )

    $suffix = '_' + $PolicyName.ToLowerInvariant()
    $hits = @($Index.Roots | Where-Object { $_.id.ToLowerInvariant().EndsWith($suffix) })
    $notes = [System.Collections.Generic.List[string]]::new()

    if ($hits.Count -eq 1) {
        $d = $hits[0]
        if ($d.psobject.Properties.Name -contains 'name' -and $d.name -and $d.name -ne $PolicyName) {
            $notes.Add("Definition name is '$($d.name)'")
        }
        return [pscustomobject]@{ Status = 'Found'; Definition = $d; Candidates = $hits.id; Notes = $notes }
    }
    if ($hits.Count -gt 1) {
        $notes.Add("Candidates: $(($hits.id | Sort-Object) -join ', ')")
        return [pscustomobject]@{ Status = 'Ambiguous'; Definition = $null; Candidates = $hits.id; Notes = $notes }
    }

    # Explain the miss: is it only available outside the selection?
    $recSuffix = $suffix + '_recommended'
    $elsewhere = @($Index.OtherRoots | Where-Object { $l = $_.id.ToLowerInvariant(); $l.EndsWith($suffix) -or $l.EndsWith($recSuffix) })
    foreach ($e in $elsewhere) {
        $why = if ($e.id -like 'user_*') { 'user scope' }
        elseif ($e.id -match '_recommended') { 'recommended variant, excluded by design' }
        else { "namespace '$(Get-DefinitionNamespace -Id $e.id)' not selected" }
        $notes.Add("Exists as $($e.id) ($why)")
    }
    [pscustomobject]@{ Status = 'NoDefinition'; Definition = $null; Candidates = @(); Notes = $notes }
}

function New-ChromeSettingInstance {
    <#
    .SYNOPSIS
        Builds the Settings Catalog setting for one GPO policy from its definition's structure.

    .DESCRIPTION
        The ADMX root definition is a choice with '<id>_0' (Disabled) and '<id>_1' (Enabled).
        Children are the definitions listed in the '<id>_1' option's dependedOnBy:
          no child                          boolean   -> _1 / _0 from the DWORD 1 / 0
          child choice definition           enum      -> _1 + child option whose optionValue
                                                         equals the registry value
          child simple integer definition   integer   -> _1 + IntegerSettingValue (range-checked)
          child simple string definition    string    -> _1 + StringSettingValue
          child simple collection           list      -> _1 + collection of StringSettingValue
        GPO 'Disabled' (list '**delvals.' only, or '**del.') -> _0 with no children.
        Anything else is UnsupportedShape with a reason; nothing is coerced.

    .OUTPUTS
        PSCustomObject: Status ('Mapped' | 'UnsupportedShape'), Setting, State, Expected, Notes
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Policy,
        [Parameter(Mandatory)]$Definition,
        [Parameter(Mandatory)]$Index
    )

    $notes = [System.Collections.Generic.List[string]]::new()
    $fail = { param($Reason) $notes.Add($Reason); [pscustomobject]@{ Status = 'UnsupportedShape'; Setting = $null; State = $null; Expected = $null; Notes = $notes } }

    $id = $Definition.id
    if ($Definition.'@odata.type' -ne $script:OdataChoiceDef) { return & $fail "Root definition is $($Definition.'@odata.type'), expected an ADMX choice" }
    $options = @(Get-Prop $Definition 'options')
    $optEnabled = $options | Where-Object itemId -eq "${id}_1"
    $optDisabled = $options | Where-Object itemId -eq "${id}_0"
    if (-not $optEnabled -or -not $optDisabled) { return & $fail "Definition lacks the '_0'/'_1' ADMX options (options: $(($options.itemId) -join ', '))" }

    $childIds = @(Get-Prop $optEnabled 'dependedOnBy' | Where-Object { $_ } | ForEach-Object { Get-Prop $_ 'dependedOnBy' } | Where-Object { $_ })
    $children = foreach ($cid in $childIds) {
        $c = $Index.ById[$cid]
        if (-not $c) { return & $fail "Child definition '$cid' is not in the definition set" }
        $c
    }
    $children = @($children)

    $root = { param([string]$Value, [object[]]$Kids)
        [ordered]@{
            '@odata.type'   = $script:OdataSetting
            settingInstance = [ordered]@{
                '@odata.type'       = '#microsoft.graph.deviceManagementConfigurationChoiceSettingInstance'
                settingDefinitionId = $id
                choiceSettingValue  = [ordered]@{
                    '@odata.type' = '#microsoft.graph.deviceManagementConfigurationChoiceSettingValue'
                    value         = $Value
                    children      = @($Kids)
                }
            }
        }
    }
    $ok = { param($Setting, $State, $Expected) [pscustomobject]@{ Status = 'Mapped'; Setting = $Setting; State = $State; Expected = $Expected; Notes = $notes } }

    switch ($Policy.Kind) {
        'Disabled' {
            return & $ok (& $root "${id}_0" @()) 'Disabled' 'Disabled'
        }
        'Scalar' {
            if ($children.Count -eq 0) {
                if ($Policy.ValueType -ne 'REG_DWORD' -or $Policy.Value -notin 0, 1) {
                    return & $fail "Boolean definition but registry.pol has $($Policy.Display)"
                }
                $state = if ($Policy.Value -eq 1) { 'Enabled' } else { 'Disabled' }
                return & $ok (& $root "${id}_$($Policy.Value)" @()) $state "$state ($($Policy.Value))"
            }
            if ($children.Count -gt 1) { return & $fail "Definition has $($children.Count) child settings ($($childIds -join ', ')); registry.pol supplies one value" }
            $child = $children[0]
            switch ($child.'@odata.type') {
                $script:OdataChoiceDef {
                    $match = @(Get-Prop $child 'options' | Where-Object { $ov = Get-Prop $_ 'optionValue'; $null -ne $ov -and [string](Get-Prop $ov 'value') -eq [string]$Policy.Value })
                    if ($match.Count -ne 1) {
                        $avail = (Get-Prop $child 'options' | ForEach-Object { "$(Get-Prop (Get-Prop $_ 'optionValue') 'value')=$(Get-Prop $_ 'displayName')" }) -join '; '
                        return & $fail "$($match.Count) enum options match registry value '$($Policy.Value)' (options: $avail)"
                    }
                    $opt = $match[0]
                    if (@(Get-Prop $opt 'dependedOnBy' | Where-Object { $_ }).Count -gt 0) { return & $fail "Enum option '$($opt.itemId)' has nested child settings" }
                    $inst = [ordered]@{
                        '@odata.type'       = '#microsoft.graph.deviceManagementConfigurationChoiceSettingInstance'
                        settingDefinitionId = $child.id
                        choiceSettingValue  = [ordered]@{
                            '@odata.type' = '#microsoft.graph.deviceManagementConfigurationChoiceSettingValue'
                            value         = $opt.itemId
                            children      = @()
                        }
                    }
                    return & $ok (& $root "${id}_1" @($inst)) 'Enabled' "Enabled: $($opt.displayName) ($($Policy.Value))"
                }
                $script:OdataSimpleDef {
                    $vd = Get-Prop $child 'valueDefinition'
                    $vdType = [string](Get-Prop $vd '@odata.type')
                    if ($vdType -like '*IntegerSettingValueDefinition') {
                        if ($Policy.ValueType -notin 'REG_DWORD', 'REG_QWORD') { return & $fail "Integer child but registry.pol has $($Policy.Display)" }
                        $n = [long]$Policy.Value
                        $min = Get-Prop $vd 'minimumValue'; $max = Get-Prop $vd 'maximumValue'
                        if (($null -ne $min -and $n -lt $min) -or ($null -ne $max -and $n -gt $max)) { return & $fail "Value $n outside definition range [$min, $max]" }
                        $valueObj = [ordered]@{ '@odata.type' = '#microsoft.graph.deviceManagementConfigurationIntegerSettingValue'; value = $n }
                        $shown = "$n"
                    } elseif ($vdType -like '*StringSettingValueDefinition') {
                        if ($Policy.ValueType -notin 'REG_SZ', 'REG_EXPAND_SZ') { return & $fail "String child but registry.pol has $($Policy.Display)" }
                        $s = [string]$Policy.Value
                        if ($vd.psobject.Properties.Name -contains 'maximumLength' -and $vd.maximumLength -and $s.Length -gt $vd.maximumLength) { return & $fail "String longer than definition maximumLength $($vd.maximumLength)" }
                        $valueObj = [ordered]@{ '@odata.type' = '#microsoft.graph.deviceManagementConfigurationStringSettingValue'; value = $s }
                        $shown = "`"$s`""
                    } else {
                        return & $fail "Unsupported child value definition '$vdType' on $($child.id)"
                    }
                    $inst = [ordered]@{
                        '@odata.type'       = '#microsoft.graph.deviceManagementConfigurationSimpleSettingInstance'
                        settingDefinitionId = $child.id
                        simpleSettingValue  = $valueObj
                    }
                    return & $ok (& $root "${id}_1" @($inst)) 'Enabled' "Enabled: $shown"
                }
                default { return & $fail "Scalar registry value but child '$($child.id)' is $($child.'@odata.type')" }
            }
        }
        'List' {
            if ($children.Count -ne 1 -or $children[0].'@odata.type' -ne $script:OdataSimpleCollectionDef) {
                return & $fail "List in registry.pol but definition children are: $(if ($children) { ($children | ForEach-Object { "$($_.id) [$($_.'@odata.type')]" }) -join ', ' } else { 'none' })"
            }
            $child = $children[0]
            $vd = Get-Prop $child 'valueDefinition'; $vdType = [string](Get-Prop $vd '@odata.type')
            if ($vdType -and $vdType -notlike '*StringSettingValueDefinition') { return & $fail "List child value definition is '$vdType', expected string" }
            $items = @($Policy.Value)
            if ($child.psobject.Properties.Name -contains 'maximumCount' -and $child.maximumCount -and $items.Count -gt $child.maximumCount) {
                return & $fail "$($items.Count) list entries exceed maximumCount $($child.maximumCount)"
            }
            $maxLen = Get-Prop $vd 'maximumLength'
            $tooLong = @($items | Where-Object { $maxLen -and $_.Length -gt $maxLen })
            if ($tooLong) { return & $fail "List entry longer than maximumLength $maxLen" }
            $inst = [ordered]@{
                '@odata.type'                = '#microsoft.graph.deviceManagementConfigurationSimpleSettingCollectionInstance'
                settingDefinitionId          = $child.id
                simpleSettingCollectionValue = @($items | ForEach-Object {
                        [ordered]@{ '@odata.type' = '#microsoft.graph.deviceManagementConfigurationStringSettingValue'; value = $_ }
                    })
            }
            return & $ok (& $root "${id}_1" @($inst)) 'Enabled' "Enabled: [$($items -join ', ')]"
        }
        default { return & $fail "registry.pol shape '$($Policy.Kind)' is not mappable" }
    }
}

#endregion

#region Supplemental values

function Add-SupplementalGpoPolicy {
    <#
    .SYNOPSIS
        Merges extra Chrome registry values (not in the Build Kit) into the GPO policy list.

    .DESCRIPTION
        For recommendations the Build Kit does not set: values added in a newer workbook, or
        org-specific values ("Is Configured" items). -Values maps a Chrome policy name to:
            [int]/[long]  REG_DWORD scalar   (boolean 0/1, enum value, integer)
            [string]      REG_SZ scalar
            [array]       list policy (Chrome\<Policy>\1..N)
        A supplemental value replaces a registry.pol value of the same name (noted). Results carry
        a note naming the source, so coverage.md shows where every value came from.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$GpoPolicies,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Values,
        [string]$SourceName = 'supplemental values'
    )

    $root = $script:ChromePolicyRoot
    $result = [System.Collections.Generic.List[object]]::new()
    $replaced = @{}
    $added = foreach ($name in $Values.Keys) {
        if ($name -notmatch '^[A-Za-z][A-Za-z0-9]*$') { throw "Supplemental key '$name' is not a Chrome policy name" }
        $v = $Values[$name]
        $p = [pscustomobject]@{
            PolicyName = [string]$name; Kind = $null; Recommended = $false; RegistryKey = $root
            ValueType = $null; Value = $null; Entries = @(); Notes = [System.Collections.Generic.List[string]]::new()
        }
        if ($v -is [int] -or $v -is [long]) {
            if ($v -lt 0 -or $v -gt [uint32]::MaxValue) { throw "Supplemental '$name': $v is outside the REG_DWORD range" }
            $p.Kind = 'Scalar'; $p.ValueType = 'REG_DWORD'; $p.Value = [uint32]$v
        } elseif ($v -is [string]) {
            $p.Kind = 'Scalar'; $p.ValueType = 'REG_SZ'; $p.Value = $v
        } elseif ($v -is [System.Collections.IEnumerable] -and $v -isnot [System.Collections.IDictionary]) {
            $items = @($v)
            if (-not $items -or @($items | Where-Object { $_ -isnot [string] -or -not $_ })) { throw "Supplemental '$name': a list must hold one or more non-empty strings" }
            $p.Kind = 'List'; $p.ValueType = 'REG_SZ'; $p.Value = [string[]]$items; $p.RegistryKey = "$root\$name"
        } else {
            throw "Supplemental '$name': unsupported value type $($v.GetType().Name) (use an integer, a string or an array of strings)"
        }
        $prior = $GpoPolicies | Where-Object { $_.PolicyName -eq $name -and $_.Kind -ne 'OutOfScope' -and -not $_.Recommended } | Select-Object -First 1
        $p.Notes.Add("Value from $SourceName (not from the Build Kit registry.pol)")
        if ($prior) { $p.Notes.Add("Overrides registry.pol value $($prior.Display)"); $replaced[$prior] = $true }
        $p | Add-Member -NotePropertyName Display -NotePropertyValue (Format-GpoPolicyValue -Policy $p)
        $p | Add-Member -NotePropertyName RegistryRef -NotePropertyValue (Format-RegistryReference -Path "HKLM\$($p.RegistryKey)" -ValueName $(if ($p.Kind -eq 'List') { $null } else { $p.PolicyName }))
        $p
    }
    foreach ($g in $GpoPolicies) { if (-not $replaced.ContainsKey($g)) { $result.Add($g) } }
    foreach ($a in $added) { $result.Add($a) }
    $result.ToArray()
}

#endregion

#region Pipeline

function Invoke-CisChromeMapping {
    <#
    .SYNOPSIS
        Joins CIS recommendations, GPO values and definitions into coverage rows + settings.

    .DESCRIPTION
        One coverage row per in-profile recommendation; no row is dropped. Status values:
          Mapped           setting produced
          NoDefinition     no selected root definition ends with '_<name>'
          Ambiguous        more than one does
          UnsupportedShape GPO value / definition structure not mappable (reason in Notes)
          NotInGpo         recommendation's registry value is not in registry.pol
          OutOfScope       registry path outside Software\Policies\Google\Chrome (e.g. Google Update)
          NoRegistryPath   audit text has no Google policy registry path
          Conflict         mapped state contradicts the CIS remediation state, or two
                           recommendations need different values for one setting
        Also returns GPO values that no in-profile recommendation claims (UnmatchedGpo).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Recommendations,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$GpoPolicies,
        [Parameter(Mandatory)]$Index
    )

    $inProfile = @($Recommendations | Where-Object InProfile)
    $coverage = [System.Collections.Generic.List[object]]::new()
    $settings = [System.Collections.Generic.List[object]]::new()
    $emitted = @{}   # definition id -> @{ CisId; Signature }
    $claimed = [System.Collections.Generic.HashSet[object]]::new()

    foreach ($rec in $inProfile) {
        $notes = [System.Collections.Generic.List[string]]::new()
        foreach ($n in $rec.Notes) { $notes.Add($n) }
        $row = [ordered]@{
            CisId         = $rec.CisId
            Title         = $rec.Title
            PolicyName    = $rec.PolicyName
            RegistryValue = Format-RegistryReference -Path $rec.RegistryPath
            Expected      = $null
            DefinitionId  = $null
            Status        = $null
            Notes         = $notes
            ExpectedState = $rec.ExpectedState
            Candidates    = @()
            Setting       = $null
        }
        $finish = { $coverage.Add([pscustomobject]$row) }

        if ($rec.Scope -eq 'None') {
            $row.Status = 'NoRegistryPath'; $row.Expected = $rec.RemediationText
            $notes.Add('Audit text has no HKLM\SOFTWARE\Policies\Google path'); & $finish; continue
        }
        $gpo = Find-GpoPolicy -Policies $GpoPolicies -Name $rec.PolicyName -Recommended $rec.Recommended -OutOfScope:($rec.Scope -eq 'OutOfScope')
        if ($gpo) { [void]$claimed.Add($gpo); $row.RegistryValue = $gpo.RegistryRef }

        if ($rec.Scope -eq 'OutOfScope') {
            $row.Status = 'OutOfScope'
            $row.Expected = if ($gpo) { $gpo.Display } else { $rec.RemediationText }
            $notes.Add('Not a Chrome policy; outside the chromeintune* definitions'); & $finish; continue
        }
        if (-not $gpo) {
            $row.Status = 'NotInGpo'
            $row.Expected = if ($rec.RemediationText) { "$($rec.RemediationText) (workbook)" } else { $null }
            $notes.Add("'$($rec.PolicyName)' is not in registry.pol"); & $finish; continue
        }
        $row.Expected = $gpo.Display
        foreach ($n in $gpo.Notes) { $notes.Add($n) }
        if ($gpo.Kind -eq 'Unsupported') { $row.Status = 'UnsupportedShape'; & $finish; continue }
        if ($gpo.Recommended) { $notes.Add('CIS sets this as a Recommended (user-overridable) policy; matched against mandatory definitions only') }

        $found = Find-ChromeSettingDefinition -PolicyName $gpo.PolicyName -Index $Index
        foreach ($n in $found.Notes) { $notes.Add($n) }
        if ($found.Status -ne 'Found') { $row.Status = $found.Status; $row.Candidates = @($found.Candidates); & $finish; continue }
        $row.DefinitionId = $found.Definition.id

        $built = New-ChromeSettingInstance -Policy $gpo -Definition $found.Definition -Index $Index
        foreach ($n in $built.Notes) { $notes.Add($n) }
        if ($built.Status -ne 'Mapped') { $row.Status = $built.Status; & $finish; continue }
        $row.Expected = $built.Expected

        if ($rec.ExpectedState -and $built.State -ne $rec.ExpectedState) {
            $row.Status = 'Conflict'
            $notes.Add("registry.pol gives '$($built.State)' but CIS remediation says '$($rec.RemediationText)'")
            & $finish; continue
        }
        if ($rec.AuditValue -match '^\d+$' -and $gpo.Kind -eq 'Scalar' -and $gpo.ValueType -eq 'REG_DWORD' -and [long]$rec.AuditValue -ne [long]$gpo.Value) {
            $notes.Add("CIS audit text expects $($rec.AuditValue); registry.pol has $($gpo.Value)")
        }

        $sig = (ConvertTo-SettingValueMap -Setting $built.Setting | ConvertTo-Json -Compress)
        if ($emitted.ContainsKey($row.DefinitionId)) {
            $prior = $emitted[$row.DefinitionId]
            if ($prior.Signature -eq $sig) {
                $row.Status = 'Mapped'; $notes.Add("Same setting as CIS $($prior.CisId); emitted once")
            } else {
                $row.Status = 'Conflict'; $notes.Add("CIS $($prior.CisId) needs a different value for the same setting")
            }
            & $finish; continue
        }
        $emitted[$row.DefinitionId] = @{ CisId = $rec.CisId; Signature = $sig }
        $row.Status = 'Mapped'
        $row.Setting = $built.Setting
        $settings.Add($built.Setting)
        & $finish
    }

    $byName = @{}
    foreach ($r in $Recommendations) { if ($r.PolicyName) { if (-not $byName[$r.PolicyName]) { $byName[$r.PolicyName] = @() }; $byName[$r.PolicyName] += $r } }
    $unmatched = foreach ($p in $GpoPolicies) {
        if ($claimed.Contains($p)) { continue }
        $others = @($byName[$p.PolicyName] | Where-Object { $_ })
        [pscustomobject]@{
            RegistryValue = $p.RegistryRef
            Value         = $p.Display
            Reason        = if ($others) { ($others | ForEach-Object { "Workbook $($_.CisId): $(Get-ProfileShortName $_.Profile)" }) -join '; ' } else { 'Not referenced by any workbook recommendation' }
        }
    }

    [pscustomobject]@{
        Coverage     = $coverage
        Settings     = $settings
        UnmatchedGpo = @($unmatched)
    }
}

function Find-GpoPolicy {
    param($Policies, [string]$Name, [bool]$Recommended, [switch]$OutOfScope)
    $hits = @($Policies | Where-Object { $_.PolicyName -eq $Name -and (($_.Kind -eq 'OutOfScope') -eq [bool]$OutOfScope) })
    if ($hits.Count -le 1) { return $hits | Select-Object -First 1 }
    # Same name as both mandatory and recommended: prefer the one the workbook points at.
    $pref = @($hits | Where-Object Recommended -eq $Recommended)
    if ($pref) { $pref[0] } else { $hits[0] }
}

function Format-RegistryReference {
    # 'HKLM\SOFTWARE\Policies\Google\Chrome\X' + 'V' -> 'Chrome\X:V' (relative to ...\Policies\Google)
    param([string]$Path, [string]$ValueName)
    if (-not $Path) { return $null }
    $p = $Path -replace '(?i)^(?:HKLM|HKEY_LOCAL_MACHINE)\\', '' -replace '(?i)^SOFTWARE\\Policies\\Google\\', ''
    if ($ValueName) { "${p}:$ValueName" } else { $p }
}

function Get-ProfileShortName {
    param([string]$Profile)
    if ($Profile -match '\((?<s>L\d)\)') { $Matches.s } elseif ($Profile) { $Profile } else { 'no profile' }
}

function ConvertTo-SettingValueMap {
    <#
    .SYNOPSIS
        Flattens a setting (or setting instance) into 'path' -> 'value' pairs for comparison.

    .DESCRIPTION
        Works on hashtables (built here) and PSCustomObjects (from Graph). Choice values are
        lower-cased (ids); collection values are sorted (order-insensitive comparison).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Setting)

    $obj = $Setting | ConvertTo-Json -Depth 50 | ConvertFrom-Json -Depth 50
    $inst = if ($obj.psobject.Properties.Name -contains 'settingInstance') { $obj.settingInstance } else { $obj }
    $map = [ordered]@{}
    Add-InstanceToValueMap -Instance $inst -Prefix '' -Map $map
    $map
}

function Add-InstanceToValueMap {
    param($Instance, [string]$Prefix, $Map)
    $id = [string]$Instance.settingDefinitionId
    $path = if ($Prefix) { "$Prefix/$id" } else { $id }
    $type = [string]$Instance.'@odata.type'
    $has = { param($n) $Instance.psobject.Properties.Name -contains $n -and $null -ne $Instance.$n }
    if ($type -like '*ChoiceSettingInstance' -and (& $has 'choiceSettingValue')) {
        $Map[$path] = ([string]$Instance.choiceSettingValue.value).ToLowerInvariant()
        $kids = if ($Instance.choiceSettingValue.psobject.Properties.Name -contains 'children') { @($Instance.choiceSettingValue.children) } else { @() }
        foreach ($c in $kids) { if ($c) { Add-InstanceToValueMap -Instance $c -Prefix $path -Map $Map } }
    } elseif ($type -like '*SimpleSettingInstance' -and (& $has 'simpleSettingValue')) {
        $Map[$path] = [string]$Instance.simpleSettingValue.value
    } elseif ($type -like '*SimpleSettingCollectionInstance') {
        $vals = @($Instance.simpleSettingCollectionValue | Where-Object { $_ } | ForEach-Object { [string]$_.value } | Sort-Object)
        $Map[$path] = '[' + ($vals -join ', ') + ']'
    } elseif ($type -like '*ChoiceSettingCollectionInstance') {
        $vals = @($Instance.choiceSettingCollectionValue | Where-Object { $_ } | ForEach-Object { ([string]$_.value).ToLowerInvariant() } | Sort-Object)
        $Map[$path] = '[' + ($vals -join ', ') + ']'
    } elseif ($type -like '*GroupSettingCollectionInstance') {
        $i = 0
        foreach ($g in @($Instance.groupSettingCollectionValue)) {
            foreach ($c in @($g.children)) { if ($c) { Add-InstanceToValueMap -Instance $c -Prefix "$path[$i]" -Map $Map } }
            $i++
        }
    } else {
        $Map[$path] = ($Instance | ConvertTo-Json -Depth 50 -Compress)
    }
}

function New-CisChromePolicyBody {
    <#
    .SYNOPSIS
        Wraps settings in a Settings Catalog configurationPolicy body (windows10 / mdm, unassigned).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [string]$Description = '',
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Settings
    )
    [ordered]@{
        name            = $Name
        description     = $Description
        platforms       = 'windows10'
        technologies    = 'mdm'
        roleScopeTagIds = @('0')
        settings        = @($Settings)
    }
}

function Compare-CisChromePolicy {
    <#
    .SYNOPSIS
        Diffs an existing Settings Catalog policy against the expected CIS settings.

    .DESCRIPTION
        Compared per top-level setting definition id:
          Missing     expected setting not in the policy
          WrongValue  present, but any flattened value (root choice, child values) differs
          Extra       in the policy but not expected (includes every non-selected-namespace
                      setting, e.g. Edge or Windows settings mixed into the same policy)
          Match       identical
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$ExpectedSettings,
        [Parameter(Mandatory)]$Policy,
        [object[]]$Coverage = @(),
        [string[]]$Namespace = @('chromeintunev1', 'chromeintunev141')
    )

    $selected = @($Namespace | ForEach-Object { $_.ToLowerInvariant().TrimEnd('~') })
    $cisByDef = @{}
    foreach ($c in $Coverage) {
        $ids = @($c.DefinitionId) + @(if ($c.psobject.Properties.Name -contains 'Candidates') { $c.Candidates })
        foreach ($i in $ids) { if ($i -and -not $cisByDef[$i]) { $cisByDef[$i] = $c } }
    }

    $expected = [ordered]@{}
    foreach ($s in $ExpectedSettings) {
        $m = ConvertTo-SettingValueMap -Setting $s
        $expected[[string]@($m.Keys)[0]] = $m
    }
    $actual = [ordered]@{}
    foreach ($s in @($Policy.settings)) {
        if (-not $s) { continue }
        $m = ConvertTo-SettingValueMap -Setting $s
        $actual[[string]@($m.Keys)[0]] = $m
    }

    $fmt = { param($Map) ($Map.GetEnumerator() | ForEach-Object { "$(($_.Key -split '/')[-1]) = $($_.Value)" }) -join '; ' }
    foreach ($id in $expected.Keys) {
        $cis = $cisByDef[$id]
        $row = [ordered]@{ Result = $null; DefinitionId = $id; CisId = (Get-Prop $cis 'CisId'); Title = (Get-Prop $cis 'Title'); Expected = & $fmt $expected[$id]; Actual = $null; Notes = $null }
        if (-not $actual.Contains($id)) {
            $row.Result = 'Missing'; [pscustomobject]$row; continue
        }
        $e = $expected[$id]; $a = $actual[$id]
        $diffs = foreach ($k in (@($e.Keys) + @($a.Keys) | Select-Object -Unique)) {
            $ev = if ($e.Contains($k)) { $e[$k] } else { '<absent>' }
            $av = if ($a.Contains($k)) { $a[$k] } else { '<absent>' }
            if ($ev -cne $av) { "$(($k -split '/')[-1]): expected $ev, actual $av" }
        }
        $row.Result = if ($diffs) { 'WrongValue' } else { 'Match' }
        $row.Actual = & $fmt $a
        $row.Notes = $diffs -join '; '
        [pscustomobject]$row
    }
    foreach ($id in $actual.Keys) {
        if ($expected.Contains($id)) { continue }
        $ns = Get-DefinitionNamespace -Id $id
        $why = if (-not $ns) { 'Not a Chrome (chromeintune*) setting' }
        elseif ($ns -notin $selected) { "Namespace '$ns' not selected" }
        elseif ($cisByDef[$id]) { "CIS $($cisByDef[$id].CisId) is $($cisByDef[$id].Status); not in the expected set" }
        else { 'Not in the CIS expected set' }
        $cis = $cisByDef[$id]
        [pscustomobject][ordered]@{ Result = 'Extra'; DefinitionId = $id; CisId = (Get-Prop $cis 'CisId'); Title = (Get-Prop $cis 'Title'); Expected = $null; Actual = & $fmt $actual[$id]; Notes = $why }
    }
}

#endregion

#region Reports

function ConvertTo-MarkdownCell {
    param($Value)
    if ($null -eq $Value) { return '' }
    $s = if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string]) { (@($Value) -join '; ') } else { [string]$Value }
    ($s -replace '\r?\n', ' ' -replace '\|', '\|').Trim()
}

function ConvertTo-CoverageMarkdown {
    <#
    .SYNOPSIS
        Renders coverage rows (every in-profile recommendation) and unmatched GPO values.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Result,
        [System.Collections.IDictionary]$Metadata = @{}
    )

    $sb = [System.Text.StringBuilder]::new()
    $title = if ($Metadata['Title']) { $Metadata['Title'] } else { 'CIS Google Chrome coverage' }
    [void]$sb.AppendLine("# $title").AppendLine()
    foreach ($k in $Metadata.Keys) {
        if ($k -eq 'Title') { continue }
        [void]$sb.AppendLine("- **$k**: $(ConvertTo-MarkdownCell $Metadata[$k])")
    }
    [void]$sb.AppendLine()

    $cov = @($Result.Coverage)
    [void]$sb.AppendLine('## Summary').AppendLine()
    [void]$sb.AppendLine('| Status | Count |').AppendLine('|---|---:|')
    foreach ($g in ($cov | Group-Object Status | Sort-Object { @('Mapped', 'Conflict', 'Ambiguous', 'NoDefinition', 'UnsupportedShape', 'NotInGpo', 'OutOfScope', 'NoRegistryPath').IndexOf($_.Name) })) {
        [void]$sb.AppendLine("| $($g.Name) | $($g.Count) |")
    }
    [void]$sb.AppendLine("| **Total** | **$($cov.Count)** |").AppendLine()
    [void]$sb.AppendLine("Settings in policy: **$(@($Result.Settings).Count)**").AppendLine()

    [void]$sb.AppendLine('## Recommendations').AppendLine()
    [void]$sb.AppendLine('| CIS ID | Title | Registry value | Expected | Definition id | Status | Notes |')
    [void]$sb.AppendLine('|---|---|---|---|---|---|---|')
    foreach ($r in ($cov | Sort-Object { ConvertTo-SortableCisId $_.CisId })) {
        $def = if ($r.DefinitionId) { "``$($r.DefinitionId)``" } else { '' }
        [void]$sb.AppendLine("| $(ConvertTo-MarkdownCell $r.CisId) | $(ConvertTo-MarkdownCell $r.Title) | $(ConvertTo-MarkdownCell $r.RegistryValue) | $(ConvertTo-MarkdownCell $r.Expected) | $def | $($r.Status) | $(ConvertTo-MarkdownCell $r.Notes) |")
    }

    [void]$sb.AppendLine().AppendLine('## GPO values not claimed by an in-profile recommendation').AppendLine()
    $un = @($Result.UnmatchedGpo)
    if (-not $un) { [void]$sb.AppendLine('None.') }
    else {
        [void]$sb.AppendLine('| Registry value | Value | Reason |').AppendLine('|---|---|---|')
        foreach ($u in $un) { [void]$sb.AppendLine("| $(ConvertTo-MarkdownCell $u.RegistryValue) | $(ConvertTo-MarkdownCell $u.Value) | $(ConvertTo-MarkdownCell $u.Reason) |") }
    }
    $sb.ToString()
}

function ConvertTo-CompareMarkdown {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Diff,
        [System.Collections.IDictionary]$Metadata = @{}
    )
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine("# $(if ($Metadata['Title']) { $Metadata['Title'] } else { 'CIS Google Chrome policy comparison' })").AppendLine()
    foreach ($k in $Metadata.Keys) { if ($k -ne 'Title') { [void]$sb.AppendLine("- **$k**: $(ConvertTo-MarkdownCell $Metadata[$k])") } }
    [void]$sb.AppendLine().AppendLine('| Result | Count |').AppendLine('|---|---:|')
    foreach ($r in 'Missing', 'WrongValue', 'Extra', 'Match') { [void]$sb.AppendLine("| $r | $(@($Diff | Where-Object Result -eq $r).Count) |") }
    foreach ($r in 'Missing', 'WrongValue', 'Extra') {
        $rows = @($Diff | Where-Object Result -eq $r | Sort-Object { ConvertTo-SortableCisId $_.CisId }, DefinitionId)
        [void]$sb.AppendLine().AppendLine("## $r ($($rows.Count))").AppendLine()
        if (-not $rows) { [void]$sb.AppendLine('None.'); continue }
        [void]$sb.AppendLine('| CIS ID | Title | Definition id | Expected | Actual | Notes |').AppendLine('|---|---|---|---|---|---|')
        foreach ($d in $rows) {
            [void]$sb.AppendLine("| $(ConvertTo-MarkdownCell $d.CisId) | $(ConvertTo-MarkdownCell $d.Title) | ``$($d.DefinitionId)`` | $(ConvertTo-MarkdownCell $d.Expected) | $(ConvertTo-MarkdownCell $d.Actual) | $(ConvertTo-MarkdownCell $d.Notes) |")
        }
    }
    $sb.ToString()
}

function ConvertTo-SortableCisId {
    # '2.10.1' -> '0002.0010.0001' so 2.10 sorts after 2.9
    param([string]$Id)
    if (-not $Id) { return 'zzzz' }
    ($Id.Split('.') | ForEach-Object { if ($_ -match '^\d+$') { $_.PadLeft(4, '0') } else { $_ } }) -join '.'
}

#endregion

#region Graph (thin wrappers; everything above is offline)

function Invoke-CisGraphRequest {
    <#
    .SYNOPSIS
        Invoke-MgGraphRequest with retry on throttling / transient errors. Returns PSCustomObjects.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('GET', 'POST', 'PUT')][string]$Method,
        [Parameter(Mandatory)][string]$Uri,
        $Body,
        [int]$MaxRetries = 4
    )
    $attempt = 0
    while ($true) {
        try {
            $params = @{ Method = $Method; Uri = $Uri; OutputType = 'Json'; ErrorAction = 'Stop' }
            if ($null -ne $Body) {
                $params.Body = if ($Body -is [string]) { $Body } else { $Body | ConvertTo-Json -Depth 50 }
                $params.ContentType = 'application/json'
            }
            $json = Invoke-MgGraphRequest @params
            if ([string]::IsNullOrWhiteSpace($json)) { return $null }
            return ($json | ConvertFrom-Json -Depth 100)
        } catch {
            $attempt++
            $status = $null
            $resp = $_.Exception.psobject.Properties['Response']
            if ($resp -and $resp.Value -and $resp.Value.psobject.Properties['StatusCode']) { $status = [int]$resp.Value.StatusCode }
            $transient = ($status -in 429, 500, 502, 503, 504) -or ($_.Exception.Message -match 'TooManyRequests|ServiceUnavailable|GatewayTimeout|temporarily')
            if (-not $transient -or $attempt -gt $MaxRetries) { throw }
            $delay = [Math]::Min(60, [Math]::Pow(2, $attempt))
            try {
                $ra = $resp.Value.Headers.RetryAfter
                if ($ra -and $ra.Delta) { $delay = [Math]::Max($delay, $ra.Delta.TotalSeconds) }
            } catch { }
            Write-Verbose "Graph $Method $Uri failed ($status); retry $attempt/$MaxRetries in ${delay}s"
            Start-Sleep -Seconds $delay
        }
    }
}

function Get-CisGraphCollection {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Uri, [scriptblock]$Where)
    $next = $Uri
    while ($next) {
        $page = Invoke-CisGraphRequest -Method GET -Uri $next
        foreach ($v in @($page.value)) { if (-not $Where -or (& $Where $v)) { $v } }
        $next = if ($page.psobject.Properties.Name -contains '@odata.nextLink') { $page.'@odata.nextLink' } else { $null }
    }
}

function Get-ChromeSettingDefinitionFromGraph {
    <#
    .SYNOPSIS
        Fetches every chromeintune* setting definition (all namespaces, children included).

    .DESCRIPTION
        Children are needed to build instances; other namespaces are needed to explain
        NoDefinition results. Selection (namespace / recommended / root) happens offline in
        New-ChromeDefinitionIndex.

        Uses the server-side filter contains(id,'chromeintunev') (~2k definitions, seconds) and
        falls back to listing the whole catalog if the service rejects the filter.
    #>
    [CmdletBinding()]
    param([string]$GraphBase = 'https://graph.microsoft.com/beta')
    $keep = { param($d) $d.id -match 'chromeintunev\d+~' }
    try {
        # Collected before returning, so a failure mid-paging leaves no partial output.
        $defs = @(Get-CisGraphCollection -Uri "$GraphBase/deviceManagement/configurationSettings?`$filter=contains(id,'chromeintunev')" -Where $keep)
        return $defs
    } catch {
        Write-Verbose "Server-side filter failed ($($_.Exception.Message)); listing the full catalog"
    }
    Get-CisGraphCollection -Uri "$GraphBase/deviceManagement/configurationSettings" -Where $keep
}

function Get-CisConfigurationPolicy {
    <#
    .SYNOPSIS
        GET a Settings Catalog policy with settings expanded (follows settings paging).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$PolicyId, [string]$GraphBase = 'https://graph.microsoft.com/beta')
    $policy = Invoke-CisGraphRequest -Method GET -Uri "$GraphBase/deviceManagement/configurationPolicies('$PolicyId')?`$expand=settings"
    $settings = [System.Collections.Generic.List[object]]::new()
    foreach ($s in @($policy.settings)) { if ($s) { $settings.Add($s) } }
    $next = if ($policy.psobject.Properties.Name -contains 'settings@odata.nextLink') { $policy.'settings@odata.nextLink' } else { $null }
    if ($next) { foreach ($s in (Get-CisGraphCollection -Uri $next)) { $settings.Add($s) } }
    $policy | Add-Member -NotePropertyName settings -NotePropertyValue $settings.ToArray() -Force
    $policy
}

#endregion

#region Excel (.xlsx) reading — dependency-free OpenXML reader

function Read-XlsxWorksheet {
    <#
    .SYNOPSIS
        Reads one worksheet of an .xlsx file into objects keyed by the header row.

    .DESCRIPTION
        Minimal OpenXML reader (shared strings, inline strings, numbers, booleans) so the tool
        does not depend on Excel or the ImportExcel module. The first row with any non-empty cell
        is the header. Empty header cells become 'ColumnN'; duplicate headers get a '_2' suffix.
        The file is opened with FileShare.ReadWrite so it can be read while open in Excel.

    .PARAMETER WorksheetName
        Sheet to read. Defaults to the first sheet.

    .PARAMETER ListWorksheets
        Return the worksheet names instead of rows.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [string]$WorksheetName,

        [switch]$ListWorksheets
    )

    $full = (Resolve-Path -LiteralPath $Path).ProviderPath
    $fs = [System.IO.File]::Open($full, 'Open', 'Read', 'ReadWrite')
    try {
        $zip = [System.IO.Compression.ZipArchive]::new($fs, [System.IO.Compression.ZipArchiveMode]::Read)
        $readXml = {
            param([string]$EntryName)
            $entry = $zip.GetEntry($EntryName)
            if (-not $entry) { return $null }
            $sr = [System.IO.StreamReader]::new($entry.Open())
            try { $x = [xml]::new(); $x.PreserveWhitespace = $true; $x.LoadXml($sr.ReadToEnd()); $x } finally { $sr.Dispose() }
        }

        $ns = [System.Xml.XmlNamespaceManager]::new([System.Xml.NameTable]::new())
        $ns.AddNamespace('m', $script:XlsxNs)
        $ns.AddNamespace('r', $script:XlsxRelNs)
        $ns.AddNamespace('p', $script:PkgRelNs)

        $workbook = & $readXml 'xl/workbook.xml'
        if (-not $workbook) { throw "Not an .xlsx workbook (xl/workbook.xml missing): $Path" }
        $sheets = @($workbook.SelectNodes('/m:workbook/m:sheets/m:sheet', $ns))
        if ($ListWorksheets) { return $sheets | ForEach-Object { $_.GetAttribute('name') } }

        $sheet = if ($WorksheetName) {
            $sheets | Where-Object { $_.GetAttribute('name') -eq $WorksheetName } | Select-Object -First 1
        } else { $sheets | Select-Object -First 1 }
        if (-not $sheet) {
            throw "Worksheet '$WorksheetName' not found. Available: $(($sheets | ForEach-Object { $_.GetAttribute('name') }) -join ', ')"
        }

        $relId = $sheet.GetAttribute('id', $script:XlsxRelNs)
        $rels = & $readXml 'xl/_rels/workbook.xml.rels'
        $target = ($rels.SelectNodes('/p:Relationships/p:Relationship', $ns) | Where-Object { $_.GetAttribute('Id') -eq $relId }).GetAttribute('Target')
        $sheetPart = if ($target.StartsWith('/')) { $target.TrimStart('/') } else { "xl/$target" }

        $shared = [System.Collections.Generic.List[string]]::new()
        $sst = & $readXml 'xl/sharedStrings.xml'
        if ($sst) {
            foreach ($si in $sst.SelectNodes('/m:sst/m:si', $ns)) {
                # Concatenate text runs; skip phonetic (rPh) runs.
                $text = ($si.SelectNodes('m:t | m:r/m:t', $ns) | ForEach-Object { $_.InnerText }) -join ''
                $shared.Add($text)
            }
        }

        $ws = & $readXml $sheetPart
        if (-not $ws) { throw "Worksheet part '$sheetPart' missing from $Path" }

        $rows = [System.Collections.Generic.List[object]]::new()
        foreach ($row in $ws.SelectNodes('/m:worksheet/m:sheetData/m:row', $ns)) {
            $cells = @{}
            $nextCol = 0
            foreach ($c in $row.SelectNodes('m:c', $ns)) {
                $ref = $c.GetAttribute('r')
                $col = if ($ref) { ConvertFrom-XlsxColumnRef -Reference $ref } else { $nextCol }
                $nextCol = $col + 1
                $t = $c.GetAttribute('t')
                $v = $c.SelectSingleNode('m:v', $ns)
                # Explicit if/else (not switch): a switch branch that outputs nothing yields
                # AutomationNull, which [string]-casts to $null instead of ''.
                $value = $null
                if ($t -eq 'inlineStr') { $value = ($c.SelectNodes('m:is/m:t | m:is/m:r/m:t', $ns) | ForEach-Object { $_.InnerText }) -join '' }
                elseif ($null -ne $v) {
                    if ($t -eq 's') { $value = $shared[[int]$v.InnerText] }
                    elseif ($t -eq 'b') { $value = $v.InnerText -eq '1' }
                    else { $value = $v.InnerText }
                }
                $cells[$col] = $value
            }
            $rows.Add($cells)
        }
    }
    finally {
        if ($zip) { $zip.Dispose() }
        $fs.Dispose()
    }

    $isEmpty = { param($h) -not ($h.Values | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }) }
    $headerIndex = -1
    for ($i = 0; $i -lt $rows.Count; $i++) { if (-not (& $isEmpty $rows[$i])) { $headerIndex = $i; break } }
    if ($headerIndex -lt 0) { return }

    $headerCells = $rows[$headerIndex]
    $maxCol = ($rows | ForEach-Object { $_.Keys } | Measure-Object -Maximum).Maximum
    $headers = [string[]]::new($maxCol + 1)
    $seen = @{}
    for ($col = 0; $col -le $maxCol; $col++) {
        $name = ([string]$headerCells[$col]).Trim()
        if (-not $name) { $name = "Column$($col + 1)" }
        if ($seen.ContainsKey($name)) { $seen[$name]++; $name = "${name}_$($seen[$name])" } else { $seen[$name] = 1 }
        $headers[$col] = $name
    }

    for ($i = $headerIndex + 1; $i -lt $rows.Count; $i++) {
        if (& $isEmpty $rows[$i]) { continue }
        $obj = [ordered]@{}
        for ($col = 0; $col -le $maxCol; $col++) { $obj[$headers[$col]] = $rows[$i][$col] }
        [pscustomobject]$obj
    }
}

function ConvertFrom-XlsxColumnRef {
    # 'A1' -> 0, 'Z9' -> 25, 'AA3' -> 26
    param([string]$Reference)
    $letters = ($Reference -replace '[^A-Za-z]').ToUpperInvariant()
    $n = 0
    foreach ($ch in $letters.ToCharArray()) { $n = $n * 26 + ([int]$ch - 64) }
    $n - 1
}

#endregion

Export-ModuleMember -Function @(
    'Read-RegistryPolFile', 'ConvertTo-ChromeGpoPolicy', 'Add-SupplementalGpoPolicy'
    'Read-XlsxWorksheet', 'Import-CisBenchmarkWorkbook', 'Get-CisRegistryReference', 'Get-CisBenchmarkVersion'
    'Get-DefinitionNamespace', 'New-ChromeDefinitionIndex', 'Find-ChromeSettingDefinition', 'New-ChromeSettingInstance'
    'Invoke-CisChromeMapping', 'ConvertTo-SettingValueMap', 'New-CisChromePolicyBody', 'Compare-CisChromePolicy'
    'ConvertTo-CoverageMarkdown', 'ConvertTo-CompareMarkdown'
    'Invoke-CisGraphRequest', 'Get-CisGraphCollection', 'Get-ChromeSettingDefinitionFromGraph', 'Get-CisConfigurationPolicy'
)
