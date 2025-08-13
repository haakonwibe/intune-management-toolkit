<#
.SYNOPSIS
    Generates comprehensive compliance reports from Microsoft Intune with actionable insights.

.DESCRIPTION
    This script retrieves device compliance status from Microsoft Intune and generates detailed reports
    with non-compliance analysis. It supports multiple output formats (CSV, HTML, JSON) and provides
    actionable insights for improving device compliance across your organization.

.PARAMETER OutputPath
    The directory where report files will be saved. Default is current directory.

.PARAMETER OutputFormat
    The output format(s) for the report. Valid options: 'CSV', 'HTML', 'JSON', 'All'. Default is 'All'.

.PARAMETER FilterByPlatform
    Filter devices by operating system platform(s). Valid options: 'Windows', 'iOS', 'Android', 'macOS'.

.PARAMETER FilterByComplianceState
    Filter devices by compliance state. Valid options: 'Compliant', 'NonCompliant', 'InGracePeriod', 'ConfigManager', 'Error', 'Unknown'.

.PARAMETER IncludeDeviceDetails
    Include additional device details such as model, manufacturer, and last sync time in the report.

.PARAMETER IncludePolicyDetails
    Include detailed compliance policy information for each device.

.PARAMETER GroupBy
    Group results by specified criteria. Valid options: 'Platform', 'ComplianceState', 'Policy', 'User', 'Department'.

.PARAMETER Top
    Limit the number of devices to process. Useful for testing with large environments.

.PARAMETER WhatIf
    Shows what would be done without executing the actual operations.

.PARAMETER Disconnect
    Disconnect from Microsoft Graph when the script completes.

.NOTES
    File Name      : Get-IntuneComplianceReport.ps1
    Author         : Haakon Wibe
    Prerequisite   : Microsoft Graph PowerShell SDK
    Copyright      : (c) 2025 Haakon Wibe. All rights reserved.
    License        : MIT
    Version        : 1.1
    Creation Date  : 2025-01-24
    Last Modified  : 2025-01-24

.EXAMPLE
    .\Get-IntuneComplianceReport.ps1

.EXAMPLE
    .\Get-IntuneComplianceReport.ps1 -OutputFormat HTML -FilterByPlatform Windows

.EXAMPLE
    .\Get-IntuneComplianceReport.ps1 -FilterByComplianceState NonCompliant -IncludeDeviceDetails -OutputPath "C:\Reports"

.EXAMPLE
    .\Get-IntuneComplianceReport.ps1 -GroupBy Platform -Top 100 -WhatIf

#>

[CmdletBinding(SupportsShouldProcess)]
param (
    [Parameter(Mandatory = $false)]
    [string]$OutputPath = ".",

    [Parameter(Mandatory = $false)]
    [ValidateSet('CSV', 'HTML', 'JSON', 'All')]
    [string[]]$OutputFormat = @('All'),

    [Parameter(Mandatory = $false)]
    [ValidateSet('Windows', 'iOS', 'Android', 'macOS')]
    [string[]]$FilterByPlatform,

    [Parameter(Mandatory = $false)]
    [ValidateSet('Compliant', 'NonCompliant', 'InGracePeriod', 'ConfigManager', 'Error', 'Unknown')]
    [string[]]$FilterByComplianceState,

    [Parameter(Mandatory = $false)]
    [switch]$IncludeDeviceDetails,

    [Parameter(Mandatory = $false)]
    [switch]$IncludePolicyDetails,

    [Parameter(Mandatory = $false)]
    [ValidateSet('Platform', 'ComplianceState', 'Policy', 'User', 'Department')]
    [string]$GroupBy,

    [Parameter(Mandatory = $false)]
    [int]$Top,

    [Parameter(Mandatory = $false)]
    [switch]$Disconnect
)

# Requires the Microsoft Graph PowerShell SDK
# Install-Module Microsoft.Graph -Scope CurrentUser

#region Helper Functions

function Write-LogMessage {
    param(
        [Parameter(Mandatory = $false)]
        [AllowEmptyString()]
        [string]$Message = "",
        [Parameter(Mandatory = $false)]
        [ValidateSet('Info', 'Warning', 'Error', 'Success')]
        [string]$Level = 'Info'
    )
    
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $colors = @{
        'Info' = 'White'
        'Warning' = 'Yellow'
        'Error' = 'Red'
        'Success' = 'Green'
    }
    
    # Handle empty messages by just writing a newline
    if ([string]::IsNullOrWhiteSpace($Message)) {
        Write-Host ""
        Write-Verbose "[NEWLINE]"
        return
    }
    
    Write-Host "[$timestamp] $Message" -ForegroundColor $colors[$Level]
    Write-Verbose "[$Level] $Message"
}

function Get-DeviceComplianceDetails {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Device
    )
    
    try {
        # Get detailed compliance information for the device
        $complianceDetails = Get-MgDeviceManagementManagedDeviceCompliancePolicyState -ManagedDeviceId $Device.Id -All -ErrorAction SilentlyContinue
        
        $nonCompliantPolicies = @()
        $compliantPolicies = @()
        
        if ($complianceDetails) {
            foreach ($policy in $complianceDetails) {
                $policyInfo = @{
                    PolicyName = $policy.DisplayName
                    State = $policy.State
                    SettingStates = @()
                }
                
                # Get setting states for non-compliant policies
                if ($policy.State -eq 'nonCompliant') {
                    try {
                        $settingStates = Get-MgDeviceManagementManagedDeviceCompliancePolicySettingState -ManagedDeviceId $Device.Id -CompliancePolicyStateId $policy.Id -All -ErrorAction SilentlyContinue
                        if ($settingStates) {
                            $policyInfo.SettingStates = $settingStates | ForEach-Object {
                                @{
                                    Setting = $_.Setting
                                    State = $_.State
                                    ErrorDescription = $_.ErrorDescription
                                }
                            }
                        }
                    } catch {
                        Write-Verbose "Could not retrieve setting states for policy $($policy.DisplayName): $_"
                    }
                    $nonCompliantPolicies += $policyInfo
                } else {
                    $compliantPolicies += $policyInfo
                }
            }
        }
        
        return @{
            NonCompliantPolicies = $nonCompliantPolicies
            CompliantPolicies = $compliantPolicies
        }
    } catch {
        Write-Verbose "Error getting compliance details for device $($Device.DeviceName): $_"
        return @{
            NonCompliantPolicies = @()
            CompliantPolicies = @()
        }
    }
}

function Get-UserDepartment {
    param(
        [Parameter(Mandatory = $true)]
        [string]$UserId
    )
    
    try {
        if ([string]::IsNullOrEmpty($UserId)) {
            return "Unknown"
        }
        
        $user = Get-MgUser -UserId $UserId -Property Department -ErrorAction SilentlyContinue
        return if ($user.Department) { $user.Department } else { "Unknown" }
    } catch {
        return "Unknown"
    }
}

function Export-ComplianceReport {
    param(
        [Parameter(Mandatory = $true)]
        [array]$ReportData,
        [Parameter(Mandatory = $true)]
        [string]$OutputPath,
        [Parameter(Mandatory = $true)]
        [string[]]$OutputFormat,
        [Parameter(Mandatory = $true)]
        [hashtable]$Summary
    )
    
    $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $baseFileName = "IntuneComplianceReport-$timestamp"
    
    foreach ($format in $OutputFormat) {
        if ($format -eq 'All') {
            Export-ComplianceReport -ReportData $ReportData -OutputPath $OutputPath -OutputFormat @('CSV', 'HTML', 'JSON') -Summary $Summary
            continue
        }
        
        switch ($format) {
            'CSV' {
                $csvPath = Join-Path $OutputPath "$baseFileName.csv"
                if ($PSCmdlet.ShouldProcess($csvPath, "Export CSV report")) {
                    $ReportData | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
                    Write-LogMessage "CSV report exported to: $csvPath" -Level Success
                }
            }
            'JSON' {
                $jsonPath = Join-Path $OutputPath "$baseFileName.json"
                if ($PSCmdlet.ShouldProcess($jsonPath, "Export JSON report")) {
                    $reportObject = @{
                        GeneratedAt = Get-Date -Format "yyyy-MM-dd HH:mm:ss UTC"
                        Summary = $Summary
                        Devices = $ReportData
                    }
                    $reportObject | ConvertTo-Json -Depth 10 | Out-File -FilePath $jsonPath -Encoding UTF8
                    Write-LogMessage "JSON report exported to: $jsonPath" -Level Success
                }
            }
            'HTML' {
                $htmlPath = Join-Path $OutputPath "$baseFileName.html"
                if ($PSCmdlet.ShouldProcess($htmlPath, "Export HTML report")) {
                    $htmlContent = Generate-HtmlReport -ReportData $ReportData -Summary $Summary
                    $htmlContent | Out-File -FilePath $htmlPath -Encoding UTF8
                    Write-LogMessage "HTML report exported to: $htmlPath" -Level Success
                }
            }
        }
    }
}

function Generate-HtmlReport {
    param(
        [Parameter(Mandatory = $true)]
        [array]$ReportData,
        [Parameter(Mandatory = $true)]
        [hashtable]$Summary
    )
    
    $html = @"
<!DOCTYPE html>
<html>
<head>
    <title>Intune Compliance Report</title>
    <style>
        body { font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif; margin: 20px; background-color: #f5f5f5; }
        .header { background-color: #0078d4; color: white; padding: 20px; border-radius: 8px; margin-bottom: 20px; }
        .summary { background-color: white; padding: 20px; border-radius: 8px; margin-bottom: 20px; box-shadow: 0 2px 4px rgba(0,0,0,0.1); }
        .summary-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(200px, 1fr)); gap: 15px; }
        .summary-card { background-color: #f8f9fa; padding: 15px; border-radius: 6px; border-left: 4px solid #0078d4; }
        .summary-card h3 { margin: 0 0 10px 0; color: #323130; }
        .summary-card .value { font-size: 24px; font-weight: bold; color: #0078d4; }
        table { width: 100%; border-collapse: collapse; background-color: white; border-radius: 8px; overflow: hidden; box-shadow: 0 2px 4px rgba(0,0,0,0.1); }
        th, td { padding: 12px; text-align: left; border-bottom: 1px solid #e1e5e9; }
        th { background-color: #f8f9fa; font-weight: 600; color: #323130; }
        tr:hover { background-color: #f8f9fa; }
        .compliant { color: #107c10; font-weight: bold; }
        .non-compliant { color: #d13438; font-weight: bold; }
        .grace-period { color: #ff8c00; font-weight: bold; }
        .unknown { color: #605e5c; font-weight: bold; }
        .footer { text-align: center; margin-top: 30px; color: #605e5c; font-size: 14px; }
    </style>
</head>
<body>
    <div class="header">
        <h1>📊 Intune Compliance Report</h1>
        <p>Generated on $(Get-Date -Format "MMMM dd, yyyy 'at' HH:mm:ss UTC")</p>
    </div>
    
    <div class="summary">
        <h2>📋 Executive Summary</h2>
        <div class="summary-grid">
            <div class="summary-card">
                <h3>Total Devices</h3>
                <div class="value">$($Summary.TotalDevices)</div>
            </div>
            <div class="summary-card">
                <h3>Compliant Devices</h3>
                <div class="value compliant">$($Summary.CompliantDevices)</div>
            </div>
            <div class="summary-card">
                <h3>Non-Compliant Devices</h3>
                <div class="value non-compliant">$($Summary.NonCompliantDevices)</div>
            </div>
            <div class="summary-card">
                <h3>Compliance Rate</h3>
                <div class="value">$($Summary.ComplianceRate)%</div>
            </div>
        </div>
    </div>
    
    <div class="summary">
        <h2>📱 Device Details</h2>
        <table>
            <thead>
                <tr>
                    <th>Device Name</th>
                    <th>User</th>
                    <th>Platform</th>
                    <th>Compliance State</th>
                    <th>Last Sync</th>
                    <th>Issues</th>
                </tr>
            </thead>
            <tbody>
"@

    foreach ($device in $ReportData) {
        $complianceClass = switch -Regex ($device.ComplianceState) {
            '^compliant$' { 'compliant' }
            '^noncompliant$|^non-compliant$' { 'non-compliant' }
            '^ingraceperiod$|^in-grace-period$' { 'grace-period' }
            default { 'unknown' }
        }
        
        $issues = if ($device.NonCompliantPoliciesCount -gt 0) {
            "$($device.NonCompliantPoliciesCount) policy violations"
        } else {
            "None"
        }
        
        # Escape HTML characters to prevent issues
        $deviceName = [System.Web.HttpUtility]::HtmlEncode($device.DeviceName)
        $userDisplayName = [System.Web.HttpUtility]::HtmlEncode($device.UserDisplayName)
        $operatingSystem = [System.Web.HttpUtility]::HtmlEncode($device.OperatingSystem)
        $complianceState = [System.Web.HttpUtility]::HtmlEncode($device.ComplianceState)
        $lastSyncDateTime = [System.Web.HttpUtility]::HtmlEncode($device.LastSyncDateTime)
        
        $html += @"
                <tr>
                    <td>$deviceName</td>
                    <td>$userDisplayName</td>
                    <td>$operatingSystem</td>
                    <td><span class="$complianceClass">$complianceState</span></td>
                    <td>$lastSyncDateTime</td>
                    <td>$issues</td>
                </tr>
"@
    }

    $html += @"
            </tbody>
        </table>
    </div>
    
    <div class="footer">
        <p>Report generated by Intune Management Toolkit | <a href="https://github.com/haakonwibe/intune-management-toolkit">GitHub Repository</a></p>
    </div>
</body>
</html>
"@

    return $html
}

#endregion

#region Main Script

try {
    Write-LogMessage "=== Intune Compliance Report Generator ===" -Level Success
    Write-LogMessage "Generating comprehensive compliance analysis..." -Level Info
    
    if ($WhatIf) {
        Write-LogMessage "Running in WhatIf mode - no data will be exported" -Level Warning
    }
    
    # Validate output path
    if (-not (Test-Path $OutputPath)) {
        if ($PSCmdlet.ShouldProcess($OutputPath, "Create directory")) {
            New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null
            Write-LogMessage "Created output directory: $OutputPath" -Level Success
        }
    }
    
    # Connect to Microsoft Graph
    Write-LogMessage "Connecting to Microsoft Graph..." -Level Info
    try {
        Connect-MgGraph -Scopes "DeviceManagementManagedDevices.Read.All", "DeviceManagementConfiguration.Read.All", "User.Read.All" -NoWelcome
        Write-LogMessage "Connected successfully to Microsoft Graph" -Level Success
    } catch {
        throw "Failed to connect to Microsoft Graph: $_"
    }
    
    # Get all managed devices with progress indication
    Write-LogMessage "Retrieving managed devices from Intune..." -Level Info
    $allDevices = if ($Top) {
        Get-MgDeviceManagementManagedDevice -Top $Top -All
    } else {
        Get-MgDeviceManagementManagedDevice -All
    }
    
    if (-not $allDevices -or $allDevices.Count -eq 0) {
        Write-LogMessage "No managed devices found in Intune" -Level Warning
        return
    }
    
    Write-LogMessage "Retrieved $($allDevices.Count) managed devices" -Level Success
    
    # Apply filters
    $filteredDevices = $allDevices
    
    if ($FilterByPlatform) {
        $filteredDevices = $filteredDevices | Where-Object { $_.OperatingSystem -in $FilterByPlatform }
        Write-LogMessage "Filtered to $($filteredDevices.Count) devices by platform: $($FilterByPlatform -join ', ')" -Level Info
    }
    
    if ($FilterByComplianceState) {
        $filteredDevices = $filteredDevices | Where-Object { $_.ComplianceState -in $FilterByComplianceState }
        Write-LogMessage "Filtered to $($filteredDevices.Count) devices by compliance state: $($FilterByComplianceState -join ', ')" -Level Info
    }
    
    if ($filteredDevices.Count -eq 0) {
        Write-LogMessage "No devices match the specified filters" -Level Warning
        return
    }
    
    # Process devices and build report data
    Write-LogMessage "Analyzing device compliance data..." -Level Info
    $reportData = @()
    $processedCount = 0
    
    foreach ($device in $filteredDevices) {
        $processedCount++
        
        if ($processedCount % 50 -eq 0 -or $processedCount -eq $filteredDevices.Count) {
            Write-Progress -Activity "Processing devices" -Status "$processedCount of $($filteredDevices.Count)" -PercentComplete (($processedCount / $filteredDevices.Count) * 100)
        }
        
        Write-Verbose "Processing device: $($device.DeviceName)"
        
        # Base device information
        $deviceRecord = [PSCustomObject]@{
            DeviceName = $device.DeviceName
            DeviceId = $device.Id
            UserDisplayName = $device.UserDisplayName
            UserPrincipalName = $device.UserPrincipalName
            OperatingSystem = $device.OperatingSystem
            OSVersion = $device.OSVersion
            ComplianceState = $device.ComplianceState
            LastSyncDateTime = if ($device.LastSyncDateTime) { $device.LastSyncDateTime.ToString("yyyy-MM-dd HH:mm:ss") } else { "Never" }
            EnrollmentType = $device.DeviceEnrollmentType
            ManagementAgent = $device.ManagementAgent
            IsSupervised = $device.IsSupervised
            IsEncrypted = $device.IsEncrypted
            JailBroken = $device.JailBroken
        }
        
        # Add device details if requested
        if ($IncludeDeviceDetails) {
            $deviceRecord | Add-Member -NotePropertyName Manufacturer -NotePropertyValue $device.Manufacturer
            $deviceRecord | Add-Member -NotePropertyName Model -NotePropertyValue $device.Model
            $deviceRecord | Add-Member -NotePropertyName SerialNumber -NotePropertyValue $device.SerialNumber
            $deviceRecord | Add-Member -NotePropertyName DeviceType -NotePropertyValue $device.DeviceType
            $deviceRecord | Add-Member -NotePropertyName StorageTotal -NotePropertyValue $device.TotalStorageSpaceInBytes
            $deviceRecord | Add-Member -NotePropertyName StorageFree -NotePropertyValue $device.FreeStorageSpaceInBytes
        }
        
        # Add department information for grouping
        if ($GroupBy -eq 'Department' -or $GroupBy -eq 'User') {
            $department = Get-UserDepartment -UserId $device.UserId
            $deviceRecord | Add-Member -NotePropertyName Department -NotePropertyValue $department
        }
        
        # Get compliance policy details if requested
        if ($IncludePolicyDetails) {
            $complianceDetails = Get-DeviceComplianceDetails -Device $device
            $deviceRecord | Add-Member -NotePropertyName NonCompliantPolicies -NotePropertyValue ($complianceDetails.NonCompliantPolicies | ConvertTo-Json -Compress)
            $deviceRecord | Add-Member -NotePropertyName CompliantPolicies -NotePropertyValue ($complianceDetails.CompliantPolicies | ConvertTo-Json -Compress)
            $deviceRecord | Add-Member -NotePropertyName NonCompliantPoliciesCount -NotePropertyValue $complianceDetails.NonCompliantPolicies.Count
        } else {
            $deviceRecord | Add-Member -NotePropertyName NonCompliantPoliciesCount -NotePropertyValue 0
        }
        
        $reportData += $deviceRecord
    }
    
    Write-Progress -Completed -Activity "Processing devices"
    
    # Debug: Show actual compliance states found in the data
    Write-LogMessage "Debug: Analyzing compliance states in retrieved data..." -Level Info
    $actualStates = $reportData | Group-Object ComplianceState | Sort-Object Name
    foreach ($state in $actualStates) {
        Write-LogMessage "  - '$($state.Name)': $($state.Count) devices" -Level Info
    }
    
    # Generate summary statistics using case-insensitive comparison
    $summary = @{
        TotalDevices = $reportData.Count
        CompliantDevices = ($reportData | Where-Object { $_.ComplianceState -match '^compliant$' }).Count
        NonCompliantDevices = ($reportData | Where-Object { $_.ComplianceState -match '^(noncompliant|non-compliant)$' }).Count
        InGracePeriodDevices = ($reportData | Where-Object { $_.ComplianceState -match '^(ingraceperiod|in-grace-period)$' }).Count
        UnknownDevices = ($reportData | Where-Object { $_.ComplianceState -match '^(unknown|error)$' }).Count
        ComplianceRate = if ($reportData.Count -gt 0) { [math]::Round((($reportData | Where-Object { $_.ComplianceState -match '^compliant$' }).Count / $reportData.Count) * 100, 2) } else { 0 }
        PlatformBreakdown = ($reportData | Group-Object OperatingSystem | ForEach-Object { @{ Platform = $_.Name; Count = $_.Count } })
        GeneratedAt = Get-Date -Format "yyyy-MM-dd HH:mm:ss UTC"
    }
    
    # Apply grouping if specified
    if ($GroupBy) {
        Write-LogMessage "Grouping results by: $GroupBy" -Level Info
        
        $groupedData = switch ($GroupBy) {
            'Platform' { $reportData | Group-Object OperatingSystem }
            'ComplianceState' { $reportData | Group-Object ComplianceState }
            'User' { $reportData | Group-Object UserDisplayName }
            'Department' { $reportData | Group-Object Department }
            default { $reportData }
        }
        
        if ($GroupBy -ne 'Policy') {
            foreach ($group in $groupedData) {
                Write-LogMessage "Group: $($group.Name) - Devices: $($group.Count)" -Level Info
            }
        }
    }
    
    # Display summary (using newlines properly)
    Write-LogMessage # Empty line
    Write-LogMessage "=== Compliance Summary ===" -Level Success
    Write-LogMessage "Total devices analyzed: $($summary.TotalDevices)" -Level Info
    Write-LogMessage "Compliant devices: $($summary.CompliantDevices)" -Level Success
    Write-LogMessage "Non-compliant devices: $($summary.NonCompliantDevices)" -Level $(if ($summary.NonCompliantDevices -gt 0) { 'Warning' } else { 'Success' })
    Write-LogMessage "Devices in grace period: $($summary.InGracePeriodDevices)" -Level Info
    Write-LogMessage "Overall compliance rate: $($summary.ComplianceRate)%" -Level $(if ($summary.ComplianceRate -ge 90) { 'Success' } elseif ($summary.ComplianceRate -ge 75) { 'Warning' } else { 'Error' })
    
    # Export reports
    if (-not $WhatIf) {
        Write-LogMessage # Empty line
        Write-LogMessage "Exporting compliance reports..." -Level Info
        Export-ComplianceReport -ReportData $reportData -OutputPath $OutputPath -OutputFormat $OutputFormat -Summary $summary
        
        Write-LogMessage # Empty line
        Write-LogMessage "Compliance analysis completed successfully!" -Level Success
        Write-LogMessage "Reports saved to: $OutputPath" -Level Info
    } else {
        Write-LogMessage # Empty line
        Write-LogMessage "WhatIf mode - Reports would be saved to: $OutputPath" -Level Warning
        Write-LogMessage "Formats: $($OutputFormat -join ', ')" -Level Info
    }
    
} catch {
    Write-LogMessage "An error occurred during compliance analysis: $_" -Level Error
    throw
} finally {
    if ($Disconnect) {
        Write-LogMessage "Disconnecting from Microsoft Graph..." -Level Info
        Disconnect-MgGraph
        Write-LogMessage "Disconnected from Microsoft Graph" -Level Success
    }
}

#endregion