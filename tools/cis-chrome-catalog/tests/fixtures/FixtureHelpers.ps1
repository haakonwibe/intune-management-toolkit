# Writers used to (re)generate the binary fixtures and to build ad-hoc files inside tests.
# Dot-source this file; it defines no state.

function Write-TestRegistryPol {
    <#
    .SYNOPSIS
        Writes a PReg v1 registry.pol from entries @{ Key; ValueName; Type; Value }.
        Type: REG_SZ, REG_EXPAND_SZ, REG_DWORD, REG_QWORD, REG_MULTI_SZ, REG_BINARY.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][object[]]$Entries
    )
    $u = [System.Text.Encoding]::Unicode
    $types = @{ REG_SZ = 1; REG_EXPAND_SZ = 2; REG_BINARY = 3; REG_DWORD = 4; REG_MULTI_SZ = 7; REG_QWORD = 11 }
    $ms = [System.IO.MemoryStream]::new()
    $w = [System.IO.BinaryWriter]::new($ms)
    $w.Write([System.Text.Encoding]::ASCII.GetBytes('PReg'))
    $w.Write([uint32]1)
    foreach ($e in $Entries) {
        $type = $types[$e.Type]
        $data = switch ($e.Type) {
            { $_ -in 'REG_SZ', 'REG_EXPAND_SZ' } { $u.GetBytes([string]$e.Value + "`0") }
            'REG_DWORD' { [BitConverter]::GetBytes([uint32]$e.Value) }
            'REG_QWORD' { [BitConverter]::GetBytes([uint64]$e.Value) }
            'REG_MULTI_SZ' { $u.GetBytes((@($e.Value) -join "`0") + "`0`0") }
            'REG_BINARY' { [byte[]]$e.Value }
        }
        $w.Write($u.GetBytes('['))
        $w.Write($u.GetBytes($e.Key + "`0"))
        $w.Write($u.GetBytes(';'))
        $w.Write($u.GetBytes($e.ValueName + "`0"))
        $w.Write($u.GetBytes(';'))
        $w.Write([uint32]$type)
        $w.Write($u.GetBytes(';'))
        $w.Write([uint32]$data.Length)
        $w.Write($u.GetBytes(';'))
        $w.Write([byte[]]$data)
        $w.Write($u.GetBytes(']'))
    }
    $w.Flush()
    [System.IO.File]::WriteAllBytes($Path, $ms.ToArray())
    $w.Dispose()
}

function New-TestXlsx {
    <#
    .SYNOPSIS
        Writes a minimal .xlsx. -Sheets is an ordered dictionary: sheet name -> array of rows,
        each row an array of cell values ($null = empty cell, numbers stay numeric).
        Strings go to sharedStrings.xml except values wrapped as @{ Inline = 'text' }, which are
        written as inline strings (both encodings occur in real workbooks).
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Sheets
    )
    Add-Type -AssemblyName System.IO.Compression
    $esc = { param($s) [System.Security.SecurityElement]::Escape([string]$s) }
    $colName = { param([int]$i) $n = ''; $i++; while ($i -gt 0) { $m = ($i - 1) % 26; $n = [char](65 + $m) + $n; $i = [int](($i - $m) / 26) }; $n }

    $shared = [System.Collections.Generic.List[string]]::new()
    $sharedIdx = @{}
    $sheetXml = [ordered]@{}
    foreach ($name in $Sheets.Keys) {
        $sb = [System.Text.StringBuilder]::new()
        [void]$sb.Append('<?xml version="1.0" encoding="UTF-8" standalone="yes"?><worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>')
        $r = 0
        foreach ($row in $Sheets[$name]) {
            $r++
            [void]$sb.Append("<row r=`"$r`">")
            for ($c = 0; $c -lt @($row).Count; $c++) {
                $v = @($row)[$c]
                if ($null -eq $v) { continue }
                $ref = "$(& $colName $c)$r"
                if ($v -is [hashtable] -and $v.ContainsKey('Inline')) {
                    [void]$sb.Append("<c r=`"$ref`" t=`"inlineStr`"><is><t>$(& $esc $v.Inline)</t></is></c>")
                } elseif ($v -is [int] -or $v -is [long] -or $v -is [double]) {
                    [void]$sb.Append("<c r=`"$ref`"><v>$v</v></c>")
                } else {
                    $s = [string]$v
                    if (-not $sharedIdx.ContainsKey($s)) { $sharedIdx[$s] = $shared.Count; $shared.Add($s) }
                    [void]$sb.Append("<c r=`"$ref`" t=`"s`"><v>$($sharedIdx[$s])</v></c>")
                }
            }
            [void]$sb.Append('</row>')
        }
        [void]$sb.Append('</sheetData></worksheet>')
        $sheetXml[$name] = $sb.ToString()
    }

    $parts = [ordered]@{}
    $ct = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/sharedStrings.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sharedStrings+xml"/>'
    $wbSheets = ''; $wbRels = ''
    $i = 0
    foreach ($name in $sheetXml.Keys) {
        $i++
        $ct += "<Override PartName=`"/xl/worksheets/sheet$i.xml`" ContentType=`"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml`"/>"
        $wbSheets += "<sheet name=`"$(& $esc $name)`" sheetId=`"$i`" r:id=`"rId$i`"/>"
        $wbRels += "<Relationship Id=`"rId$i`" Type=`"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet`" Target=`"worksheets/sheet$i.xml`"/>"
        $parts["xl/worksheets/sheet$i.xml"] = $sheetXml[$name]
    }
    $ct += '</Types>'
    $wbRels += "<Relationship Id=`"rId$($i + 1)`" Type=`"http://schemas.openxmlformats.org/officeDocument/2006/relationships/sharedStrings`" Target=`"sharedStrings.xml`"/>"
    $parts['[Content_Types].xml'] = $ct
    $parts['_rels/.rels'] = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>'
    $parts['xl/workbook.xml'] = "<?xml version=`"1.0`" encoding=`"UTF-8`" standalone=`"yes`"?><workbook xmlns=`"http://schemas.openxmlformats.org/spreadsheetml/2006/main`" xmlns:r=`"http://schemas.openxmlformats.org/officeDocument/2006/relationships`"><sheets>$wbSheets</sheets></workbook>"
    $parts['xl/_rels/workbook.xml.rels'] = "<?xml version=`"1.0`" encoding=`"UTF-8`" standalone=`"yes`"?><Relationships xmlns=`"http://schemas.openxmlformats.org/package/2006/relationships`">$wbRels</Relationships>"
    $sst = ($shared | ForEach-Object { "<si><t xml:space=`"preserve`">$(& $esc $_)</t></si>" }) -join ''
    $parts['xl/sharedStrings.xml'] = "<?xml version=`"1.0`" encoding=`"UTF-8`" standalone=`"yes`"?><sst xmlns=`"http://schemas.openxmlformats.org/spreadsheetml/2006/main`" count=`"$($shared.Count)`" uniqueCount=`"$($shared.Count)`">$sst</sst>"

    if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Force }
    $fs = [System.IO.File]::Open($Path, 'CreateNew')
    $zip = [System.IO.Compression.ZipArchive]::new($fs, [System.IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($p in $parts.Keys) {
            $entry = $zip.CreateEntry($p)
            $sw = [System.IO.StreamWriter]::new($entry.Open(), [System.Text.UTF8Encoding]::new($false))
            $sw.Write($parts[$p]); $sw.Dispose()
        }
    } finally { $zip.Dispose(); $fs.Dispose() }
}
