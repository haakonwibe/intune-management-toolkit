<#
.SYNOPSIS
    Detection script for regional settings Win32 app deployment.

.DESCRIPTION
    Checks if the expected regional settings are configured.
    Edit the $ExpectedGeoId and $ExpectedCulture variables to match your deployment.

.NOTES
    Author  : Haakon Wibe
    License : MIT
    Context : Used as Intune Win32 app detection rule (script).
#>

# ============================================
# CONFIGURE THESE VALUES FOR YOUR DEPLOYMENT
# ============================================
$ExpectedGeoId = 177       # Norway
$ExpectedCulture = "nb-NO" # Norwegian Bokmål
# ============================================

try {
    # Check GeoID
    $geoPath = "HKCU:\Control Panel\International\Geo"
    $currentGeoId = (Get-ItemProperty -Path $geoPath -Name "Nation" -ErrorAction Stop).Nation

    # Check Culture/Locale
    $intlPath = "HKCU:\Control Panel\International"
    $currentCulture = (Get-ItemProperty -Path $intlPath -Name "LocaleName" -ErrorAction Stop).LocaleName

    if ($currentGeoId -eq $ExpectedGeoId.ToString() -and $currentCulture -eq $ExpectedCulture) {
        Write-Host "Regional settings correctly configured: GeoId=$currentGeoId, Culture=$currentCulture"
        exit 0  # Detected - app is installed
    }
    else {
        Write-Host "Regional settings mismatch: Expected GeoId=$ExpectedGeoId Culture=$ExpectedCulture, Found GeoId=$currentGeoId Culture=$currentCulture"
        exit 1  # Not detected - app needs installation
    }
}
catch {
    Write-Host "Detection failed: $($_.Exception.Message)"
    exit 1  # Not detected - app needs installation
}
