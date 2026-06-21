<#
.SYNOPSIS
    Clears legacy on-premises attributes from Entra ID user objects after on-premises
    directory synchronization has been permanently disabled (DC loss, decommission,
    or migration to cloud-only identity).

.DESCRIPTION
    When Entra Connect / AAD Connect sync is disabled, formerly-synced user objects
    retain stale on-premises attributes (onPremisesImmutableId, onPremisesDistinguishedName,
    onPremisesSamAccountName, onPremisesUserPrincipalName, onPremisesDomainName,
    onPremisesSecurityIdentifier). These can break hybrid device join, Intune enrollment,
    and Outlook autodiscover even though the source on-premises AD no longer exists.

    This script clears those attributes via Microsoft Graph, working around two issues:

      1. The Microsoft.Graph PowerShell SDK's typed cmdlets (Update-MgUser) cannot send
         an explicit JSON null. Passing -SomeProperty $null gets dropped or mangled by
         the SDK, producing a 400 Request_BadRequest "Invalid value specified for
         property" error. Invoke-MgGraphRequest with a raw JSON body sends a literal
         null and works correctly.

      2. Several on-premises attributes (distinguishedName, samAccountName,
         userPrincipalName, domainName) are read-only on the Graph v1.0 endpoint and
         only writable on /beta/. onPremisesImmutableId is writable on v1.0.

.NOTES
    Requires modules : Microsoft.Graph.Authentication, Microsoft.Graph.Users
    Requires scopes   : User.ReadWrite.All, Directory.ReadWrite.All
    Prerequisite      : onPremisesSyncEnabled must be FALSE at the ORG level
                        (Get-MgOrganization). Deactivation can take up to 72 hours
                        after being turned off re-run this script if attributes
                        won't clear and that hasn't elapsed yet.

    onPremisesSecurityIdentifier is system-generated and occasionally resists direct
    Graph writes even via beta. If -IncludeSecurityIdentifier fails for a user, fall
    back to the ADSyncTools module's Clear-ADSyncToolsOnPremisesAttribute cmdlet,
    which is purpose-built to handle that attribute.

.PARAMETER UserId
    A single user UPN or Object ID to process.

.PARAMETER CsvPath
    Path to a CSV with a 'UserPrincipalName' column, for bulk processing.

.PARAMETER LogPath
    Path to write the before/after results log. Defaults to a timestamped CSV in the
    current directory.

.PARAMETER IncludeSecurityIdentifier
    Also attempts to clear onPremisesSecurityIdentifier. See Notes above.

.EXAMPLE
    .\Clear-EntraOnPremisesAttributes.ps1 -UserId "userid@domain.com" -WhatIf

.EXAMPLE
    .\Clear-EntraOnPremisesAttributes.ps1 -CsvPath .\orphaned-users.csv -IncludeSecurityIdentifier
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(ParameterSetName = 'Single', Mandatory)]
    [string]$UserId,

    [Parameter(ParameterSetName = 'Bulk', Mandatory)]
    [string]$CsvPath,

    [string]$LogPath = ".\OnPremAttributeClear-$(Get-Date -Format 'yyyyMMdd-HHmmss').csv",

    [switch]$IncludeSecurityIdentifier
)

$ErrorActionPreference = 'Stop'

# Writable on v1.0
$v1Attributes = @('onPremisesImmutableId')

# Only writable on beta
$betaAttributes = @(
    'onPremisesDistinguishedName',
    'onPremisesDomainName',
    'onPremisesSamAccountName',
    'onPremisesUserPrincipalName'
)

if ($IncludeSecurityIdentifier) {
    $betaAttributes += 'onPremisesSecurityIdentifier'
}

$allAttributes = $v1Attributes + $betaAttributes

#region Pre-flight checks
if (-not (Get-MgContext)) {
    Write-Error "Not connected to Graph. Run: Connect-MgGraph -Scopes 'User.ReadWrite.All','Directory.ReadWrite.All'"
    return
}

$org = Get-MgOrganization
if ($org.OnPremisesSyncEnabled) {
    Write-Error "OnPremisesSyncEnabled is still TRUE at the org level. Disable sync first (Update-MgOrganization -OrganizationId $($org.Id) -BodyParameter @{onPremisesSyncEnabled=`$false}) and allow up to 72 hours for full deactivation before running this script."
    return
}
#endregion

#region Build target list
$targets = @()
if ($PSCmdlet.ParameterSetName -eq 'Single') {
    $targets += $UserId
}
else {
    if (-not (Test-Path $CsvPath)) {
        Write-Error "CSV not found: $CsvPath"
        return
    }
    $targets += (Import-Csv $CsvPath).UserPrincipalName
}
#endregion

$results = [System.Collections.Generic.List[object]]::new()

foreach ($target in $targets) {
    Write-Host "Processing $target..." -ForegroundColor Cyan

    try {
        $before = Get-MgUser -UserId $target `
            -Property (@('Id', 'UserPrincipalName', 'OnPremisesSyncEnabled') + $allAttributes) `
            -ErrorAction Stop

        if ($before.OnPremisesSyncEnabled) {
            Write-Warning "$target still shows OnPremisesSyncEnabled = True at the user level. Skipping to avoid conflicting with active sync."
            $results.Add([pscustomobject]@{
                    User      = $target; Attribute = 'ALL'; Before = 'N/A'; After = 'SKIPPED'
                    Status    = 'Skipped - user still synced'; Timestamp = Get-Date
                })
            continue
        }

        foreach ($attr in $allAttributes) {
            $results.Add([pscustomobject]@{
                    User      = $target; Attribute = $attr; Before = $before.$attr; After = $null
                    Status    = 'Pending'; Timestamp = Get-Date
                })
        }

        if ($PSCmdlet.ShouldProcess($target, "Clear on-premises attributes: $($allAttributes -join ', ')")) {

            $v1Json = "{ " + (($v1Attributes | ForEach-Object { "`"$_`": null" }) -join ', ') + " }"
            Invoke-MgGraphRequest -Method PATCH `
                -Uri "https://graph.microsoft.com/v1.0/users/$target" `
                -Body $v1Json -ContentType 'application/json' | Out-Null

            $betaJson = "{ " + (($betaAttributes | ForEach-Object { "`"$_`": null" }) -join ', ') + " }"
            Invoke-MgGraphRequest -Method PATCH `
                -Uri "https://graph.microsoft.com/beta/users/$target" `
                -Body $betaJson -ContentType 'application/json' | Out-Null

            Start-Sleep -Seconds 2
            $after = Get-MgUser -UserId $target -Property $allAttributes -ErrorAction Stop

            foreach ($attr in $allAttributes) {
                $row = $results | Where-Object { $_.User -eq $target -and $_.Attribute -eq $attr }
                $row.After = $after.$attr
                $row.Status = if ([string]::IsNullOrEmpty($after.$attr)) { 'Cleared' } else { 'Failed - still populated' }
            }
        }
        else {
            foreach ($attr in $allAttributes) {
                $row = $results | Where-Object { $_.User -eq $target -and $_.Attribute -eq $attr }
                $row.Status = 'WhatIf - not executed'
            }
        }
    }
    catch {
        Write-Warning "Error processing $target : $($_.Exception.Message)"
        $results.Add([pscustomobject]@{
                User      = $target; Attribute = 'ALL'; Before = 'N/A'; After = 'N/A'
                Status    = "Error: $($_.Exception.Message)"; Timestamp = Get-Date
            })
    }
}

$results | Export-Csv -Path $LogPath -NoTypeInformation
Write-Host "`nDone. Results logged to $LogPath" -ForegroundColor Green
$results | Format-Table User, Attribute, Status -AutoSize