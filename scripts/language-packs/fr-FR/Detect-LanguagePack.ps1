# Get-InstalledLanguage returns a dictionary-like object. Without GetEnumerator(),
# piping to Where-Object treats it as a single object rather than iterating over
# each language entry, so the filter would not work correctly.
$Language = "fr-FR"
$installed = (Get-InstalledLanguage).GetEnumerator() | Where-Object {
    $_.LanguageId -eq $Language -and
    $_.LanguagePacks -ne "None"
}
if ($installed) {
    Write-Output "Compliant: $Language has full language pack"
    exit 0
} else {
    Write-Output "Not compliant: $Language missing or features only"
    exit 1
}
