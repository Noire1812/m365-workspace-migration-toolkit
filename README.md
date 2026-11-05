# M365 → Google Workspace migration toolkit

Tools I use to plan, check and finish small-business mail migrations from Microsoft 365 to Google Workspace:

| Part | What it does |
|---|---|
| [`ExoTenantAudit`](powershell/ExoTenantAudit) (PowerShell) | Read-only inventory of an Exchange Online tenant: domains, mailboxes with sizes and item counts, aliases, delegation and group membership. Writes one CSV per area plus `summary.json`. |
| [`migration_check.py`](python/migration_check.py) (Python) | Compares source and target item counts per account and workload, reports the success rate, and exits non-zero when anything needs review, so it can gate a cutover. |
| [Cutover runbook](docs/cutover-runbook-template.md) | The checklist for the final delta sync, DNS changes (MX, SPF, DKIM, DMARC), handover and cleanup. |

All three came out of a real migration: 33 mailboxes, about 250 GB and 470K items moved with a 99.1% first-pass success rate. No client data is in this repository; the examples use `contoso.com`.

## Tenant audit

Needs PowerShell 7 and the [ExchangeOnlineManagement](https://www.powershellgallery.com/packages/ExchangeOnlineManagement) module (v3). It only reads; it never changes the tenant.

```powershell
Install-Module ExchangeOnlineManagement -Scope CurrentUser
Connect-ExchangeOnline -UserPrincipalName admin@contoso.com
Import-Module ./powershell/ExoTenantAudit
Invoke-ExoTenantAudit -OutputPath ./audit -Verbose
```

Output:

| File | One row per |
|---|---|
| `domains.csv` | accepted domain |
| `mailboxes.csv` | mailbox: type, item count, size in bytes, litigation hold, deleted-item retention |
| `aliases.csv` | secondary SMTP address, to recreate on the target |
| `delegation.csv` | Full Access or Send As grant (inherited and `SELF` entries skipped) |
| `groups.csv` | group member or owner, with whether the group accepts outside senders |
| `summary.json` | totals for the whole tenant |

Design notes:

- **Exact sizes.** The REST-based v3 cmdlets return sizes as text such as `1.234 GB (1,325,000,000 bytes)`. `ConvertTo-ByteCount` reads the byte figure in brackets instead of converting units, so totals don't drift.
- **Aliases.** In `EmailAddresses`, `SMTP:` (uppercase) is the primary address and `smtp:` (lowercase) a secondary one, so that comparison is case-sensitive on purpose.
- **Empty groups stay visible.** They're listed as `(empty group)` so they can be reviewed for cleanup rather than silently dropped.

Tests use [Pester 5](https://pester.dev) and mock every Exchange cmdlet, so they run without a tenant:

```powershell
Install-Module Pester -MinimumVersion 5.0 -Scope CurrentUser
Invoke-Pester ./powershell/ExoTenantAudit/Tests
```

## Migration check

Standard library only (Python 3.9+). Each input is a CSV with the columns `account,workload,items`: one for the source counts (for example from `mailboxes.csv`), one for what arrived in the target (for example from the Google Workspace Data Import report).

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

- `--threshold` sets the minimum success rate per account and workload (default 99%).
- `--json out.json` also writes the full result.
- Exit status: `0` all clear, `1` something needs review, `2` bad input.
- Extra items on the target (duplicates) don't raise the success rate above 100%.

```console
python -m unittest discover python
```

## License

MIT
