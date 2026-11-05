# Cutover runbook template: Microsoft 365 to Google Workspace

A checklist for the final switch, after the first full copy and at least one delta sync have run. Replace the placeholders in `<angle brackets>` for each project.

## 1. One week before

- [ ] Run the tenant audit again (`Invoke-ExoTenantAudit`) and compare it with the first audit. New mailboxes, aliases or groups since the first pass need target accounts before cutover.
- [ ] Confirm every source mailbox has a provisioned, licensed target account.
- [ ] Recreate secondary addresses (`aliases.csv`) and groups (`groups.csv`) on the target. Keep internal-only posting where the source group had it.
- [ ] Rebuild delegation (`delegation.csv`): shared mailbox access and Send As.
- [ ] Lower the TTL on every MX record to 300 seconds so the change propagates quickly on cutover day.
- [ ] Confirm the retention fallback is in place on the source in case data has to be recovered after cutover. Litigation hold needs Exchange Online Plan 2 or an add-on, so check the license first.
- [ ] Agree the cutover window and the user communication with the client.

## 2. Cutover day (per domain: `<domain>`)

| Step | Record or action | Value |
|---|---|---|
| 1 | Final delta sync | Start, wait for completion |
| 2 | MX | Google's MX target (`smtp.google.com`, priority 1) |
| 3 | SPF (TXT) | `v=spf1 include:_spf.google.com ~all`; add any other senders the audit found, and keep one SPF record per domain |
| 4 | DKIM | Generate the key in the Google Admin console, publish the TXT record, then turn on signing |
| 5 | DMARC (TXT at `_dmarc`) | Start at `v=DMARC1; p=none; rua=mailto:<reports address>` and tighten after reports are clean |
| 6 | Autodiscover / old CNAMEs | Remove the Microsoft records once mail flows to Google |

- [ ] Send a test message from outside to every domain and to one shared address, and check it lands in Google.
- [ ] Run one more delta sync after MX propagates to catch mail delivered to Microsoft during the change.
- [ ] Run `migration_check.py` against the final counts. Do not close the project until it exits 0 or every flagged item has a reason.

## 3. Handover

- [ ] Hand over credentials securely, never by email in plain text. Require a password change and 2-step verification at first sign-in.
- [ ] Give users the one-page guide: signing in, where mail, calendar and files now live, shared drives, mobile setup.
- [ ] Keep the Microsoft tenant read-only for `<N>` days, then cancel licenses on an agreed date.
- [ ] Remove stale accounts and guests the audit flagged.

## 4. After cutover

- [ ] Review DMARC reports after one to two weeks; move to `p=quarantine` when only expected senders appear.
- [ ] Restore the MX TTL to a normal value.
- [ ] Record final numbers: mailboxes, items, GB, success rate, downtime.
