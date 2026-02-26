# --- CONFIGURATION ---
$CsvOutputPath = ".\AdminPortalAppIDs.csv"

# The specific list of portals you requested
$PortalNames = @(
    "Azure portal",
    "Exchange admin center",
    "Microsoft 365 admin center",
    "Microsoft 365 Defender portal",
    "Microsoft Entra admin center",
    "Microsoft Intune admin center",
    "Microsoft Purview portal",
    "Microsoft Teams admin center"
)

# --- TRANSLATION MAP ---
# Maps the "Portal Name" to the actual Service Principal Name(s) used by Microsoft.
# This is necessary because "Exchange admin center" is not an App ID in Entra ID.
$PortalMap = @{
    "Azure portal"                  = @("Azure Portal", "Microsoft Azure Management")
    "Exchange admin center"         = @("Office 365 Exchange Online")
    "Microsoft 365 admin center"    = @("Microsoft 365 Support Service", "Office 365 Management APIs", "Office.com")
    "Microsoft 365 Defender portal" = @("Microsoft 365 Defender", "Microsoft Threat Protection", "Windows Azure Active Directory")
    "Microsoft Entra admin center"  = @("Azure Portal", "Microsoft Azure Management") # Shares ID with Azure Portal
    "Microsoft Intune admin center" = @("Microsoft Intune")
    "Microsoft Purview portal"      = @("Microsoft Purview", "Azure Purview", "Azure Data Catalog")
    "Microsoft Teams admin center"  = @("Skype and Teams Tenant Admin API", "Microsoft Teams")
}

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

foreach ($PortalName in $PortalNames) {
    Write-Host "Looking up: $PortalName" -ForegroundColor Yellow
    
    # 1. Determine which Service Principal names to search for
    $SearchTerms = if ($PortalMap.ContainsKey($PortalName)) { $PortalMap[$PortalName] } else { @($PortalName) }
    
    $FoundMatch = $false

    foreach ($Term in $SearchTerms) {
        # Search Graph
        $SP = Get-MgServicePrincipal -Filter "displayName eq '$Term'" -ErrorAction SilentlyContinue

        if ($SP) {
            foreach ($Match in $SP) {
                $Results += [PSCustomObject]@{
                    RequestedPortal = $PortalName
                    ActualDisplayName = $Match.DisplayName
                    ApplicationId   = $Match.AppId
                    ObjectId        = $Match.Id
                    Notes           = "Mapped from '$PortalName'"
                }
            }
            $FoundMatch = $true
        }
    }

    # If no mapped principal found, report it
    if (-not $FoundMatch) {
        $Results += [PSCustomObject]@{
            RequestedPortal = $PortalName
            ActualDisplayName = "NOT FOUND"
            ApplicationId   = "N/A"
            ObjectId        = "N/A"
            Notes           = "No backing Service Principal found in this tenant"
        }
    }
}

# --- OUTPUT ---
Write-Host "`nSearch Complete. Results:" -ForegroundColor Green
$Results | Format-Table -AutoSize

# Export to CSV
try {
    $Results | Export-Csv -Path $CsvOutputPath -NoTypeInformation
    Write-Host "Results exported to: $CsvOutputPath" -ForegroundColor Yellow
}
catch {
    Write-Error "Failed to export CSV."
}