# --- CONFIGURATION ---
$CsvOutputPath = ".\ResolvedAppNames.csv"

# The specific list of Application IDs you provided
$AppIds = @(
    "c44b4083-3bb0-49c1-b47d-974e53cbdf3c",
    "00000006-0000-0ff1-ce00-000000000000",
    "89bee1f7-5e6e-4d8a-9f3d-ecd601259da7",
    "d4ebce55-015a-49b5-a083-c84d1797ae8c",
    "797f4846-ba00-4fd7-ba43-dac1f8f63013",
    "c44b4083-3bb0-49c1-b47d-974e53cbdf3c", # Duplicate in your list, script will handle it
    "fc03f97a-9db0-4627-a216-ec98ce54e018"
) | Select-Object -Unique

# --- CONNECTION ---
try {
    # Check if we already have a valid context
    $CurrentContext = Get-MgContext -ErrorAction SilentlyContinue

    if (-not $CurrentContext) {
        Write-Host "Connecting to Microsoft Graph..." -ForegroundColor Cyan
        Connect-MgGraph -Scopes "Application.Read.All", "Directory.Read.All" -NoWelcome
    }
    else {
        Write-Host "Already connected to Graph as $($CurrentContext.Account)" -ForegroundColor Green
    }
}
catch {
    Write-Error "Could not connect to Graph. Ensure you have the SDK installed."
    exit
}

# --- PROCESSING ---
$Results = @()

foreach ($Id in $AppIds) {
    Write-Host "Looking up ID: $Id" -ForegroundColor Yellow
    
    # Search for Service Principal by AppId
    $SP = Get-MgServicePrincipal -Filter "appId eq '$Id'" -ErrorAction SilentlyContinue

    if ($SP) {
        foreach ($Match in $SP) {
            $Results += [PSCustomObject]@{
                ApplicationId     = $Id
                DisplayName       = $Match.DisplayName
                ObjectId          = $Match.Id
                ServicePrincipalType = $Match.ServicePrincipalType
                Status            = "Found"
            }
        }
    }
    else {
        $Results += [PSCustomObject]@{
            ApplicationId     = $Id
            DisplayName       = "NOT FOUND (Internal/Missing)"
            ObjectId          = "N/A"
            ServicePrincipalType = "N/A"
            Status            = "Missing"
        }
    }
}

# --- OUTPUT ---
Write-Host "`nLookup Complete. Results:" -ForegroundColor Green
$Results | Format-Table -AutoSize

# Export to CSV
try {
    $Results | Export-Csv -Path $CsvOutputPath -NoTypeInformation
    Write-Host "Results exported to: $CsvOutputPath" -ForegroundColor Yellow
}
catch {
    Write-Error "Failed to export CSV."
}