# m365-workspace-migration-toolkit

Scripts for moving a small organization from Microsoft 365 to Google Workspace.

- `ExoTenantAudit` is a PowerShell module that inventories an Exchange Online tenant before a migration. It is read-only.
- `migration_check.py` compares item counts between source and target and lists anything that didn't make it across.
- `docs/cutover-runbook-template.md` is the checklist I follow for the final sync and DNS change.

## Background

Google's Data Import service moves the data, but it doesn't plan the migration for you. Before starting I need a list of mailboxes, shared mailboxes, aliases, delegates and groups so they can be rebuilt on the Google side. After each sync I want one view of which accounts are short, across every workload, instead of reading each report separately.

These came out of a 33-mailbox migration (about 250 GB and 470,000 items). No client data is included; examples use `contoso.com`.

## Install

Requirements:

- PowerShell 7 and [ExchangeOnlineManagement](https://www.powershellgallery.com/packages/ExchangeOnlineManagement) 3.x for the audit
- Python 3.9 or later for the count check (standard library only)

```powershell
git clone https://github.com/Noire1812/m365-workspace-migration-toolkit.git
cd m365-workspace-migration-toolkit
Install-Module ExchangeOnlineManagement -Scope CurrentUser
```

## Usage

### Tenant audit

```powershell
Connect-ExchangeOnline -UserPrincipalName admin@contoso.com
Import-Module ./powershell/ExoTenantAudit
Invoke-ExoTenantAudit -OutputPath ./audit
```

This writes the following to `./audit`:

```
domains.csv       accepted domains
mailboxes.csv     type, item count, size in bytes, litigation hold, deleted-item retention
aliases.csv       secondary SMTP addresses
delegation.csv    Full Access and Send As grants
groups.csv        distribution and Microsoft 365 group members and owners
summary.json      totals
```

The individual functions (`Get-ExoMailboxInventory`, `Get-ExoAliasInventory`, `Get-ExoMailboxDelegation`, `Get-ExoGroupInventory`, `Get-ExoDomainInventory`) can also be run on their own and piped wherever you need them.

Audit output contains real tenant data. `audit/` is in `.gitignore`; keep it out of version control.

### Count check

Both files are CSVs with the columns `account,workload,items`. Build the source file from `mailboxes.csv` (or the Microsoft 365 admin reports) and the target file from the Data Import report.

```console
$ python python/migration_check.py python/examples/source.csv python/examples/target.csv
workload            source    migrated   success  review
calendar               813         813   100.00%       0
contacts               140         140   100.00%       0
drive                4,664       4,664   100.00%       0
email               76,447      67,518    88.32%       2
--------------------------------------------------------
ALL                 82,064      73,135    89.12%       2

Needs review:
  BELOW_THRESHOLD    email        billing@contoso.com                  39,410 of 41,022 (96.07%)
  MISSING_IN_TARGET  email        frontdesk@contoso.com                0 of 7,310 (0.00%)
```

Options:

```
--threshold N   minimum success percentage per account and workload (default 99)
--json PATH     also write the full result as JSON
```

The script exits 0 when everything meets the threshold, 1 when something needs review, and 2 on bad input, so it can be used as a check before cutover.

## Tests

```powershell
Install-Module Pester -MinimumVersion 5.0 -Scope CurrentUser
Invoke-Pester ./powershell/ExoTenantAudit/Tests
python -m unittest discover python
```

The Pester tests mock the Exchange Online cmdlets, so no tenant or connection is needed.

## License

[MIT](LICENSE) © Joseph Lyons
