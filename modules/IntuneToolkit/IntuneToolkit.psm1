<#
.SYNOPSIS
    Intune Management Toolkit - Reusable PowerShell functions for Microsoft Intune management.

.DESCRIPTION
    This module provides common functions used across the Intune Management Toolkit scripts.
    It includes utilities for Graph API connections, device management, reporting, and error handling.

.NOTES
    File Name      : IntuneToolkit.psm1
    Author         : Haakon Wibe  
    Version        : 1.0
    Copyright      : (c) 2025 Haakon Wibe. All rights reserved.
    License        : MIT
#>

#region Graph Connection Functions

function Connect-IntuneGraph {
    <#
    .SYNOPSIS
        Establishes a connection to Microsoft Graph with opinionated permission level presets.

    .DESCRIPTION
        Provides simplified permission selection via -PermissionLevel while supporting custom scope
        definitions through -AdditionalScopes or direct -PermissionLevel Custom usage.
        Will re-use an existing connection if all required scopes are already granted.

    .PARAMETER PermissionLevel
        Predefined permission set: ReadOnly, Standard, Full, Custom. (Default: Standard)

    .PARAMETER AdditionalScopes
        Extra scopes to append to selected PermissionLevel or explicit list when using Custom.

    .PARAMETER NoWelcome
        Suppresses the Microsoft Graph welcome banner.

    .PARAMETER ForceReconnect
        Forces a new Connect-MgGraph even if current context already satisfies required scopes.

    .PARAMETER Quiet
        Suppress non-error console output (still writes Verbose / errors). Prefer using -Verbose for diagnostics.

    .EXAMPLE
        Connect-IntuneGraph -PermissionLevel ReadOnly

    .EXAMPLE
        Connect-IntuneGraph -PermissionLevel Full -AdditionalScopes "Reports.Read.All"

    .EXAMPLE
        Connect-IntuneGraph -PermissionLevel Custom -AdditionalScopes "Device.Read.All","Group.Read.All"

    .EXAMPLE
        Connect-IntuneGraph -PermissionLevel Standard -Verbose

    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [ValidateSet('ReadOnly','Standard','Full','Custom')]
        [string]$PermissionLevel = 'Standard',

        [Parameter(Mandatory = $false)]
        [string[]]$AdditionalScopes = @(),

        [Parameter(Mandatory = $false)]
        [switch]$NoWelcome,

        [Parameter(Mandatory = $false)]
        [switch]$ForceReconnect,

        [Parameter(Mandatory = $false)]
        [switch]$Quiet
    )

    # Predefined scope sets (ordered roughly by least to most privilege)
    $scopeSets = @{        
        ReadOnly = @(
            'DeviceManagementManagedDevices.Read.All'
            'DeviceManagementConfiguration.Read.All'
            'DeviceManagementApps.Read.All'
            'User.Read.All'
            'Group.Read.All'
        )
        Standard = @(
            'DeviceManagementManagedDevices.ReadWrite.All'
            'DeviceManagementConfiguration.Read.All'
            'DeviceManagementApps.Read.All'
            'User.Read.All'
            'Group.Read.All'
        )
        Full = @(
            'DeviceManagementManagedDevices.ReadWrite.All'
            'DeviceManagementManagedDevices.PrivilegedOperations.All'
            'DeviceManagementConfiguration.ReadWrite.All'
            'DeviceManagementApps.ReadWrite.All'
            'DeviceManagementServiceConfig.ReadWrite.All'
            'User.Read.All'
            'Group.ReadWrite.All'
            'Directory.Read.All'
        )
    }

    if ($PermissionLevel -eq 'Custom' -and -not $AdditionalScopes) {
        throw 'When using -PermissionLevel Custom you must supply -AdditionalScopes.'
    }

    $requestedScopes = if ($PermissionLevel -eq 'Custom') { $AdditionalScopes } else { $scopeSets[$PermissionLevel] + $AdditionalScopes }
    $scopes = $requestedScopes | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique

    try {
        $haveConnection = $false
        if (-not $ForceReconnect) {
            try {
                if (Test-GraphConnection -RequiredScopes $scopes) { $haveConnection = $true }
            } catch { }
        }

        if ($haveConnection) {
            if (-not $Quiet) { Write-Host "[Connect-IntuneGraph] Already connected with required scopes (PermissionLevel=$PermissionLevel)." -ForegroundColor Green }
            return (Get-MgContext)
        }

        if (-not $Quiet) { Write-Host "[Connect-IntuneGraph] Connecting to Microsoft Graph (PermissionLevel=$PermissionLevel)" -ForegroundColor Cyan }
        Write-Verbose "Scopes requested: $($scopes -join ', ')"
        Connect-MgGraph -Scopes $scopes -NoWelcome:$NoWelcome

        $ctx = Get-MgContext
        if (-not $ctx) { throw 'Graph context not returned after connection attempt.' }

        # Validate scopes post-connection
        $missing = $scopes | Where-Object { $_ -notin $ctx.Scopes }
        if ($missing) {
            Write-Warning "Connected but missing expected scopes: $($missing -join ', ')"
        } else {
            if (-not $Quiet) { Write-Host "[Connect-IntuneGraph] Connected as $($ctx.Account)" -ForegroundColor Green }
        }

        return $ctx
    }
    catch {
        throw "Failed to connect to Microsoft Graph: $_"
    }
}

function Test-GraphConnection {
    <#
    .SYNOPSIS
        Tests if Microsoft Graph connection is active and has required permissions.
    
    .PARAMETER RequiredScopes
        Array of required permission scopes to validate.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [string[]]$RequiredScopes
    )
    try {
        $context = Get-MgContext
        if (-not $context) { return $false }
        if ($RequiredScopes) {
            $currentScopes = $context.Scopes
            $missingScopes = $RequiredScopes | Where-Object { $_ -notin $currentScopes }
            if ($missingScopes) { return $false }
        }
        return $true
    }
    catch { return $false }
}

#endregion

#region Logging Functions

function Write-IntuneLog {
    <#
    .SYNOPSIS
        Writes formatted log messages with timestamp and color coding.
    
    .PARAMETER Message
        The message to log.
    
    .PARAMETER Level
        The log level (Info, Warning, Error, Success).
    
    .PARAMETER NoConsole
        Suppresses console output (useful for file-only logging).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,
        
        [Parameter(Mandatory = $false)]
        [ValidateSet('Info', 'Warning', 'Error', 'Success', 'Debug')]
        [string]$Level = 'Info',
        
        [Parameter(Mandatory = $false)]
        [switch]$NoConsole
    )
    
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "[$timestamp] [$Level] $Message"
    
    # Write to verbose stream
    Write-Verbose $logMessage
    
    # Write to console with color coding unless suppressed
    if (-not $NoConsole) {
        $colors = @{
            'Info' = 'White'
            'Warning' = 'Yellow'
            'Error' = 'Red'
            'Success' = 'Green'
            'Debug' = 'Cyan'
        }
        
        Write-Host "[$timestamp] $Message" -ForegroundColor $colors[$Level]
    }
}

#endregion

#region Device Management Functions

function Get-IntuneDeviceCompliance {
    <#
    .SYNOPSIS
        Gets detailed compliance information for an Intune managed device.
    
    .PARAMETER DeviceId
        The ID of the managed device.
    
    .PARAMETER IncludeSettings
        Include detailed setting-level compliance information.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$DeviceId,
        
        [Parameter(Mandatory = $false)]
        [switch]$IncludeSettings
    )
    
    try {
        $compliancePolicies = Get-MgDeviceManagementManagedDeviceCompliancePolicyState -ManagedDeviceId $DeviceId -All -ErrorAction SilentlyContinue
        
        $result = @{
            CompliancePolicies = @()
            NonCompliantPolicies = @()
            CompliantPolicies = @()
        }
        
        if ($compliancePolicies) {
            foreach ($policy in $compliancePolicies) {
                $policyInfo = @{
                    Id = $policy.Id
                    DisplayName = $policy.DisplayName
                    State = $policy.State
                    Version = $policy.Version
                    Settings = @()
                }
                
                # Get setting-level details for non-compliant policies
                if ($IncludeSettings -and $policy.State -eq 'nonCompliant') {
                    try {
                        $settingStates = Get-MgDeviceManagementManagedDeviceCompliancePolicySettingState -ManagedDeviceId $DeviceId -CompliancePolicyStateId $policy.Id -All -ErrorAction SilentlyContinue
                        
                        if ($settingStates) {
                            $policyInfo.Settings = $settingStates | ForEach-Object {
                                @{
                                    Setting = $_.Setting
                                    State = $_.State
                                    ErrorDescription = $_.ErrorDescription
                                    CurrentValue = $_.CurrentValue
                                    Sources = $_.Sources
                                }
                            }
                        }
                    }
                    catch {
                        Write-Verbose "Could not retrieve setting states for policy $($policy.DisplayName): $_"
                    }
                }
                
                $result.CompliancePolicies += $policyInfo
                
                if ($policy.State -eq 'nonCompliant') {
                    $result.NonCompliantPolicies += $policyInfo
                } else {
                    $result.CompliantPolicies += $policyInfo
                }
            }
        }
        
        return $result
    }
    catch {
        Write-Warning "Error getting compliance details for device $DeviceId`: $_"
        return @{
            CompliancePolicies = @()
            NonCompliantPolicies = @()
            CompliantPolicies = @()
        }
    }
}

function Get-BatchedIntuneDevices {
    <#
    .SYNOPSIS
        Retrieves Intune devices in batches to handle large environments efficiently.
    
    .PARAMETER BatchSize
        Number of devices to process per batch.
    
    .PARAMETER Filter
        OData filter to apply to device query.
    
    .PARAMETER Top
        Maximum number of devices to retrieve.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [int]$BatchSize = 100,
        
        [Parameter(Mandatory = $false)]
        [string]$Filter,
        
        [Parameter(Mandatory = $false)]
        [int]$Top
    )
    
    try {
        Write-Verbose "Retrieving Intune devices with batch size: $BatchSize"
        
        $allDevices = @()
        $skip = 0
        
        do {
            $batchParams = @{
                Top = $BatchSize
                Skip = $skip
            }
            
            if ($Filter) {
                $batchParams.Filter = $Filter
            }
            
            $batch = Get-MgDeviceManagementManagedDevice @batchParams
            
            if ($batch) {
                $allDevices += $batch
                Write-Verbose "Retrieved batch of $($batch.Count) devices (Total: $($allDevices.Count))"
                
                if ($Top -and $allDevices.Count -ge $Top) {
                    $allDevices = $allDevices[0..($Top - 1)]
                    break
                }
            }
            
            $skip += $BatchSize
        } while ($batch -and $batch.Count -eq $BatchSize)
        
        Write-Verbose "Total devices retrieved: $($allDevices.Count)"
        return $allDevices
    }
    catch {
        throw "Error retrieving devices in batches: $_"
    }
}

#endregion

#region Export Functions

function Export-IntuneReport {
    <#
    .SYNOPSIS
        Exports Intune data to multiple formats (CSV, JSON, HTML).
    
    .PARAMETER Data
        The data object to export.
    
    .PARAMETER OutputPath
        Directory where files will be saved.
    
    .PARAMETER BaseFileName
        Base name for output files (timestamp will be added).
    
    .PARAMETER Formats
        Array of formats to export ('CSV', 'JSON', 'HTML', 'All').
    
    .PARAMETER WhatIf
        Shows what would be exported without creating files.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Data,
        
        [Parameter(Mandatory = $true)]
        [string]$OutputPath,
        
        [Parameter(Mandatory = $true)]
        [string]$BaseFileName,
        
        [Parameter(Mandatory = $false)]
        [ValidateSet('CSV', 'JSON', 'HTML', 'All')]
        [string[]]$Formats = @('All'),
        
        [Parameter(Mandatory = $false)]
        [hashtable]$Metadata = @{}
    )
    
    if (-not (Test-Path $OutputPath)) {
        if ($PSCmdlet.ShouldProcess($OutputPath, "Create directory")) {
            New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null
        }
    }
    
    $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $fileBaseName = "$BaseFileName-$timestamp"
    
    foreach ($format in $Formats) {
        if ($format -eq 'All') {
            Export-IntuneReport -Data $Data -OutputPath $OutputPath -BaseFileName $BaseFileName -Formats @('CSV', 'JSON', 'HTML') -Metadata $Metadata
            continue
        }
        
        switch ($format) {
            'CSV' {
                $csvPath = Join-Path $OutputPath "$fileBaseName.csv"
                if ($PSCmdlet.ShouldProcess($csvPath, "Export CSV")) {
                    $Data | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
                    Write-IntuneLog "CSV report exported: $csvPath" -Level Success
                }
            }
            'JSON' {
                $jsonPath = Join-Path $OutputPath "$fileBaseName.json"
                if ($PSCmdlet.ShouldProcess($jsonPath, "Export JSON")) {
                    $exportData = @{
                        Metadata = $Metadata
                        Data = $Data
                        GeneratedAt = Get-Date -Format "yyyy-MM-dd HH:mm:ss UTC"
                    }
                    $exportData | ConvertTo-Json -Depth 10 | Out-File -FilePath $jsonPath -Encoding UTF8
                    Write-IntuneLog "JSON report exported: $jsonPath" -Level Success
                }
            }
            'HTML' {
                $htmlPath = Join-Path $OutputPath "$fileBaseName.html"
                if ($PSCmdlet.ShouldProcess($htmlPath, "Export HTML")) {
                    Write-IntuneLog "HTML export not implemented in base module" -Level Warning
                }
            }
        }
    }
}

#endregion

#region Utility Functions

function ConvertTo-FriendlySize {
    <#
    .SYNOPSIS
        Converts byte values to human-readable format.
    
    .PARAMETER Bytes
        The byte value to convert.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [long]$Bytes
    )
    
    if ($Bytes -eq 0) { return "0 B" }
    
    $sizes = @("B", "KB", "MB", "GB", "TB")
    $order = [math]::Floor([math]::Log($Bytes, 1024))
    
    if ($order -ge $sizes.Length) {
        $order = $sizes.Length - 1
    }
    
    $size = [math]::Round($Bytes / [math]::Pow(1024, $order), 2)
    return "$size $($sizes[$order])"
}

function Test-AdminPrivileges {
    <#
    .SYNOPSIS
        Tests if the current PowerShell session has administrative privileges.
    #>
    [CmdletBinding()]
    param()
    
    $currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    return $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

#endregion

# Export module functions
Export-ModuleMember -Function @(
    'Connect-IntuneGraph',
    'Test-GraphConnection',
    'Write-IntuneLog',
    'Get-IntuneDeviceCompliance',
    'Get-BatchedIntuneDevices',
    'Export-IntuneReport',
    'ConvertTo-FriendlySize',
    'Test-AdminPrivileges'
)