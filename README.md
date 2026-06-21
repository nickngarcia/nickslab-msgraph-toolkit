# MSGraph

Microsoft Graph PowerShell solutions for Entra ID / M365 administration
built while solving real problems, documented so the gotchas don't have to be
rediscovered next time.

## Structure

Each subfolder is a self-contained solution: a `README.md` covering the
problem, why it's harder than it looks, and usage, plus the script(s)
themselves. Folders are named after the primary script's verb-noun, minus
extension.

## Solutions

| Folder | Problem solved |
|---|---|
| [Clear-EntraOnPremisesAttributes](./Clear-EntraOnPremisesAttributes/) | Clear stale `onPremises*` attributes from Entra users after on-prem sync is permanently disabled (DC loss, decommission) without needing AD access. |

## Conventions used across these scripts

- `[CmdletBinding(SupportsShouldProcess)]` with `-WhatIf` support for any
  script that writes or deletes
- Before/after results logged to a timestamped CSV for audit/rollback
  reference
- Per-target `try/catch` so one bad target (offline, missing, no permission)
  doesn't kill a batch run
- Prerequisites and required Graph scopes documented in each script's
  comment-based help (`Get-Help .\Script.ps1 -Full`)
- `Invoke-MgGraphRequest` with raw JSON used instead of typed cmdlets
  anywhere a property needs to be explicitly cleared the  Microsoft.Graph SDK's typed cmdlets can't send a real JSON `null`

## General prerequisites

- [Microsoft.Graph PowerShell SDK](https://learn.microsoft.com/powershell/microsoftgraph)
- `Connect-MgGraph` with the scopes listed in each solution's README
- PowerShell 7+ recommended
