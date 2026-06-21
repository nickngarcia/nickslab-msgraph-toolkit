# Clear-EntraOnPremisesAttributes

Clears stale `onPremises*` attributes from Microsoft Entra ID user objects after
on-premises directory sync has been disabled without needing access to the
original domain controller or Entra Connect server.

## The problem

If you lose your DC, decommission on-prem AD, or otherwise permanently disable
directory sync, formerly-synced user objects in Entra ID keep their legacy
`onPremises*` attributes (immutable ID, distinguished name, SAM account name,
UPN, domain name, security identifier). These stick around even though the
source AD no longer exists, and can break hybrid device join, Intune
enrollment, and Outlook autodiscover.

There's surprisingly little reliable guidance on actually clearing these once
the on-prem side is gone. This repo documents the working fix.

## Why it's cumbersome

Three separate issues stack on top of each other:

1. **The Microsoft.Graph PowerShell SDK can't send a real JSON `null`.**
   Typed cmdlets like `Update-MgUser -OnPremisesImmutableId $null` either drop
   the property from the request entirely or send a malformed value. Graph's
   PATCH semantics distinguish "property omitted" (leave alone) from "property
   explicitly null" (clear it) so the typed cmdlet literally can't express
   what you want. `Invoke-MgGraphRequest` with a raw JSON body sidesteps this:
   you write the JSON yourself, so `null` means null.

2. **Some attributes are read-only on Graph v1.0.** `onPremisesDistinguishedName`,
   `onPremisesSamAccountName`, `onPremisesUserPrincipalName`, and
   `onPremisesDomainName` only became writable on the `/beta/` endpoint
   Microsoft added this specifically for hybrid-to-cloud-only cleanup, but
   never promoted it to v1.0. `onPremisesImmutableId` is writable on v1.0.

3. **`onPremisesSecurityIdentifier` is system-generated.** Entra normally
   computes and stamps this during sync, so write support is more of a
   grudging edge-case allowance than a guaranteed path. It usually works via
   beta, but if it doesn't, fall back to the `ADSyncTools` PowerShell module's
   `Clear-ADSyncToolsOnPremisesAttribute` cmdlet, which is purpose-built to
   handle it.

## Prerequisites

- `onPremisesSyncEnabled` must be `$false` at the **org level**
  (`Get-MgOrganization`). Deactivation can take up to **72 hours** after
  you first disable sync if attributes won't clear and it hasn't been that
  long, that's likely why.
- The target user's own `OnPremisesSyncEnabled` must also be `$false`. The
  script checks this per-user and skips anyone still showing as synced.
- Graph scopes: `User.ReadWrite.All`, `Directory.ReadWrite.All`
- Modules: `Microsoft.Graph.Authentication`, `Microsoft.Graph.Users`

## Usage

```powershell
Connect-MgGraph -Scopes "User.ReadWrite.All", "Directory.ReadWrite.All"

# Single user, preview only
.\Clear-EntraOnPremisesAttributes.ps1 -UserId "userid@domain.com" -WhatIf

# Single user, execute
.\Clear-EntraOnPremisesAttributes.ps1 -UserId "userid@domain.com"

# Bulk via CSV (must have a UserPrincipalName column), including the SID
.\Clear-EntraOnPremisesAttributes.ps1 -CsvPath .\orphaned-users.csv -IncludeSecurityIdentifier
```

The script logs a before/after value and status for every attribute on every
user to a timestamped CSV, so you have a rollback reference and an audit
trail.

## Verifying results

The Entra admin center user blade caches aggressively and can keep showing
old values for a while after the underlying Graph object has actually been
cleared. Don't trust the portal verify directly:

```powershell
Get-MgUser -UserId "userid@domain.com" -Property OnPremisesImmutableId |
    Select-Object OnPremisesImmutableId
```

If Graph returns blank, the clear worked; give the portal a hard refresh (or
check in an incognito window) and it'll catch up.

## Disclaimer

Clearing these attributes is generally safe for users who are permanently
moving to cloud-only management, but it does sever the link Entra would use
to re-match the account if you ever re-enable sync against the same or a new
on-prem AD. Review the before/after log before running this against
production in bulk.