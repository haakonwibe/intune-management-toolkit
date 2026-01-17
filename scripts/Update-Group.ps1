<#
.SYNOPSIS
    Updates Active Directory group membership from a CSV file containing user UPNs.

.DESCRIPTION
    This script clears an existing Active Directory group and repopulates it with users
    specified in a CSV file. Useful for maintaining group membership based on external
    data sources or scheduled updates.

.NOTES
    File Name      : Update-Group.ps1
    Author         : Haakon Wibe
    Prerequisite   : Active Directory PowerShell module
    License        : MIT
    Version        : 1.0

.EXAMPLE
    .\Update-Group.ps1
    Runs the script with hardcoded $groupName and $csvPath values (edit script to configure).
#>

# Import the Active Directory module
Import-Module ActiveDirectory

# Define variables
$groupName = "Group_Of_The_Day"
$csvPath = "C:\Path\To\File.csv"

# Empty the group
try {
    Get-ADGroupMember -Identity $groupName | ForEach-Object {
        Remove-ADGroupMember -Identity $groupName -Members $_ -Confirm:$true -WhatIf:$true
    }
    Write-Host "Successfully removed all members from the group $groupName"
} catch {
    Write-Error "Failed to remove members from the group: $($_.Exception.Message)"
    exit
}

# Import the CSV file, skipping the header row
try {
    $users = Import-Csv -Path $csvPath -Header "UPN" | Select-Object -Skip 1
} catch {
    Write-Error "Failed to import CSV file: $($_.Exception.Message)"
    exit
}

# Add users to the group
foreach ($user in $users) {
    $upn = $user.UPN
    if ([string]::IsNullOrWhiteSpace($upn)) {
        Write-Warning "Skipping empty UPN in CSV"
        continue
    }

    try {
        $adUser = Get-ADUser -Filter "UserPrincipalName -eq '$upn'" -ErrorAction Stop
        if ($adUser) {
            Add-ADGroupMember -Identity $groupName -Members $adUser
            Write-Host "Added user $upn to the group $groupName"
        } else {
            Write-Warning "User with UPN $upn not found in Active Directory"
        }
    } catch {
        Write-Error ("Error processing user {0}: {1}" -f $upn, $_.Exception.Message)
        if ($_.Exception.GetType().Name -eq "ADFilterParsingException") {
            Write-Host "This error often occurs due to special characters in the UPN. Please check the UPN for any unusual characters."
        }
    }
}

Write-Host "Group membership update completed."
