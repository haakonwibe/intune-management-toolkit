# --- CONFIGURATION ---
$CsvOutputPath = ".\MicrosoftAppIDs.csv"

# The list of apps provided
$AppNames = @(
    "App Studio for Microsoft Teams",
    "Augmentation Loop",
    "Call Recorder",
    "Connectors",
    "Copilot Data Platform",
    "DataSecurityInvestigation",
    "Device Management Service",
    "EDU Assignments",
    "EnrichmentSvc",
    "Enterprise Copilot Platform",
    "Groups Service",
    "IC3 Gateway",
    "IC3 Gateway Non Cae",
    "Insights Services",
    "INT Augmentation Loop 1P",
    "Legacy Smart Compose",
    "Loop",
    "Loop Web Application",
    "Loop Web Service",
    "M365 Admin Services",
    "M365 Auditing Public Protected Web API app",
    "M365ChatClient",
    "make.gov.powerapps.us",
    "make.powerapps.com",
    "Media Analysis and Transformation Service",
    "Message Recall",
    "Messaging Async Media",
    "MessagingAsyncMediaProd",
    "Microsoft 365 Reporting Service",
    "Microsoft Discovery Service",
    "Microsoft Exchange Online Protection",
    "Microsoft Flow Portal",
    "Microsoft Flow Portal GCC",
    "Microsoft Forms",
    "Microsoft Forms Web",
    "Microsoft Information Protection API",
    "Microsoft Office",
    "Microsoft Office 365 Portal",
    "Microsoft People Cards Service",
    "Microsoft Planner",
    "Microsoft Planner Client",
    "Microsoft SharePoint Online - SharePoint Home",
    "Microsoft Stream Portal",
    "Microsoft Stream Service",
    "Microsoft Teams",
    "Microsoft Teams - T4L Web Client",
    "Microsoft Teams - Teams And Channels Service",
    "Microsoft Teams Analytics",
    "Microsoft Teams Chat Aggregator",
    "Microsoft Teams Graph Service",
    "Microsoft Teams Mailhook",
    "Microsoft Teams Retail Service",
    "Microsoft Teams Services",
    "Microsoft Teams Targeting Application",
    "Microsoft Teams UIS",
    "Microsoft Teams Web Client",
    "Microsoft Todo web app",
    "Microsoft To-Do web app",
    "Microsoft Virtual Events Portal",
    "Microsoft Virtual Events Services",
    "Microsoft Visio Data Visualizer",
    "Microsoft Whiteboard Services",
    "MSAI Substrate Meeting Intelligence",
    "Natural Language Editor",
    "O365 Diagnostic Service",
    "O365 Suite UX",
    "O365 Suite UX PathFinder",
    "OCPS Checkin Service",
    "Office 365",
    "Office 365 Exchange Microservices",
    "Office 365 Exchange Online",
    "Office 365 Search Service",
    "Office 365 SharePoint Online",
    "Office Collab Actions",
    "Office Delve",
    "Office Hive",
    "Office Hive Fairfax",
    "Office MRO Device Manager Service",
    "Office Online Add-in SSO",
    "Office Online Augmentation Loop SSO",
    "Office Online Core SSO",
    "Office Online Loki SSO",
    "Office Online Maker SSO",
    "Office Online Print SSO",
    "Office Online Search SSO",
    "Office Online Service",
    "Office Online Speech SSO",
    "Office Scripts Service",
    "Office Scripts Service - INT",
    "Office Scripts Service - Local",
    "Office Scripts Service - Test",
    "Office Shredding Service",
    "Office.com",
    "Office365 Shell DoD WCSS-Client",
    "Office365 Shell WCSS-Client",
    "OfficeClientService",
    "OfficeHome",
    "OfficePowerPointSGS",
    "OfficeServicesManager",
    "Olympus",
    "OMEX External",
    "One Outlook Web",
    "OneDrive",
    "OneDrive SyncEngine",
    "OneNote",
    "OneOutlook",
    "Outlook Browser Extension",
    "Outlook Service for Exchange",
    "PowerApps Service",
    "Project for the web",
    "ProjectWorkManagement",
    "ProjectWorkManagement_AdminTools",
    "ProjectWorkManagement_USGov",
    "Protection Center",
    "Reply-At-Mention",
    "SharePoint eSignature",
    "SharePoint eSignature PPE",
    "SharePoint Online Web Client Extensibility",
    "SharePoint Online Web Client Extensibility Isolated",
    "Skype and Teams Tenant Admin API",
    "Skype for Business",
    "Skype for Business Online",
    "Skype Presence Service",
    "Sway",
    "Targeted Messaging Service",
    "Teams CMD Services Artifacts",
    "Teams Walkie Talkie Service",
    "Teams Walkie Talkie Service - GCC",
    "Viva Engage"
) | Select-Object -Unique # Deduplicate list automatically

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
$Total = $AppNames.Count
$Current = 0

Write-Host "Searching for $($Total) applications..." -ForegroundColor Cyan

foreach ($Name in $AppNames) {
    $Current++
    
    # Progress Bar (Essential for long lists)
    Write-Progress -Activity "Looking up Application IDs" -Status "Processing: $Name" -PercentComplete (($Current / $Total) * 100)

    # Search for Service Principal by Display Name
    # We use -ConsistencyLevel eventual to handle search queries better, though standard filter is usually enough for exact match
    $ServicePrincipal = Get-MgServicePrincipal -Filter "displayName eq '$Name'" -ErrorAction SilentlyContinue

    if ($ServicePrincipal) {
        # Handle case where multiple apps might have the same name (rare but possible)
        foreach ($sp in $ServicePrincipal) {
            $Results += [PSCustomObject]@{
                DisplayName   = $Name
                ApplicationId = $sp.AppId
                ObjectId      = $sp.Id
                Status        = "Found"
            }
        }
    }
    else {
        $Results += [PSCustomObject]@{
            DisplayName   = $Name
            ApplicationId = "NOT FOUND"
            ObjectId      = "N/A"
            Status        = "Missing"
        }
    }
}

# --- OUTPUT ---
Write-Progress -Completed -Activity "Looking up Application IDs"

# 1. Output to Terminal (Table format)
Write-Host "`nSearch Complete. Results:" -ForegroundColor Green
$Results | Format-Table -AutoSize

# 2. Output to CSV
try {
    $Results | Export-Csv -Path $CsvOutputPath -NoTypeInformation
    Write-Host "Results successfully exported to: $CsvOutputPath" -ForegroundColor Yellow
}
catch {
    Write-Error "Failed to export to CSV. Check file permissions."
}