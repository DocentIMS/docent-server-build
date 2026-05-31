# CLAUDE.md

## Communication style (operator preference)
- Give very specific actions, including links (PR URLs, file paths).
- Use short, numbered steps: 1, 2, 3.
- Minimal words. No long explanations or walls of text.
- Don't dump caveats — surface only what's needed to act now.

---

## SMTP relay setup notes (from related work, chelseamallproject)

Background / hard-won context for a future SMTP-relay phase script in this repo. Hetzner Cloud blocks outbound ports 25/465 by default and won't unblock 25 on request for a while, so direct Postfix → recipient-MX delivery silently fails (queues, looks "sent," never arrives). 587/2525 stay open → relay all outbound mail through an external SMTP service (SMTP2GO) over 587.

### Diagnosis chain (for future debugging)
- `sudo postqueue -p` — shows queued mail + per-message failure reason. Single most useful command.
- `connect to mx...:25: Connection timed out` = the Hetzner port-25 block (pre-relay state).
- `535 Incorrect authentication data` = reached the relay fine, but credentials wrong. This error is **progress** — relay path works.
- `Mail queue is empty` = success.

### DNS records (added at the authoritative DNS host)
Authoritative DNS for `chelseamallproject.com` is **Hetzner** (SOA = `hydrogen.ns.hetzner.com`), even though the domain may be registered elsewhere. Verify with `nslookup -type=ns <domain>`. SMTP2GO's "configure automatically" does nothing for Hetzner-hosted DNS; add manually.

Three CNAMEs from SMTP2GO (Verified Senders → DNS configuration), entered as subdomain-only in Hetzner, value ending with a trailing dot:

| Type  | Name                    | Value                       |
|-------|-------------------------|-----------------------------|
| CNAME | `emXXXXXXX`             | `return.smtp2go.net.`       |
| CNAME | `sXXXXXXX._domainkey`   | `dkim.smtp2go.net.` (domain-aligned DKIM) |
| CNAME | `linktrack`             | `smtp2go.net.` (optional: open/click tracking) |

Plus update SPF on the `@` TXT record:
```
v=spf1 mx include:spf.smtp2go.com ~all
```
DMARC (`_dmarc`) and MX need no changes. Together these make relayed mail authenticate as your own domain (SPF + DKIM aligned → DMARC pass → trusted inbox delivery).

### Postfix config (`/etc/postfix/main.cf`)
Edit the existing (empty) `relayhost =` line rather than adding a duplicate, and add the SASL/TLS block:
```
relayhost = [mail.smtp2go.com]:587
smtp_sasl_auth_enable = yes
smtp_sasl_password_maps = hash:/etc/postfix/sasl_passwd
smtp_sasl_security_options = noanonymous
smtp_tls_security_level = encrypt
smtp_sasl_mechanism_filter = plain, login
```
**Gotcha:** Debian's default `main.cf` already ships `smtp_tls_security_level = may`. Adding a second `= encrypt` causes the *repeating overriding earlier entry* warning that floods the logs. Remove the original `may` line (the `smtp_` one — leave `smtpd_tls_security_level = may`, which is the unrelated inbound setting).

### Credentials file (`/etc/postfix/sasl_passwd`)
The SMTP username is whatever you named the SMTP2GO SMTP user (here it's literally `docentims.com` — it doesn't have to be auto-generated, and it's **not** your account login). Write it with a quoted heredoc so special chars in the password aren't mangled:
```bash
sudo tee /etc/postfix/sasl_passwd > /dev/null <<'EOF'
[mail.smtp2go.com]:587 docentims.com:THE_SMTP_USER_PASSWORD
EOF
```
**Gotchas learned:**
- Use an **alphanumeric** password for the SMTP user. Symbols (`()`, `~`, `:`, etc.) invite shell-quoting and copy errors — the single biggest time-sink was a password mismatch; resetting to a clean alphanumeric in SMTP2GO removed all ambiguity.
- Postfix reads the compiled `.db`, **not** the text file — run `postmap` after every edit.
- Verify with `sudo cat -A /etc/postfix/sasl_passwd`. The `$` is `cat -A`'s end-of-line marker (not part of the password); reveals stray trailing whitespace.

### Apply, secure, test
```bash
sudo postmap /etc/postfix/sasl_passwd
sudo chmod 600 /etc/postfix/sasl_passwd /etc/postfix/sasl_passwd.db
sudo systemctl reload postfix
sudo postqueue -f      # flush queued mail through the new relay
sleep 5
sudo postqueue -p      # want: "Mail queue is empty"
```
Final verification — send to a Gmail address and check "Show original" for `SPF: PASS` and `DKIM: PASS` aligned to your domain:
```bash
echo "relay test" | mail -s "relay test" -r wglover@chelseamallproject.com you@gmail.com
```

### Per-server values to parameterize when building a phase script
- Domain name (DNS records, SPF, `-r` sender).
- SMTP2GO SMTP username + password — pull from `org-secrets.local` (matches the existing email-AI phase pattern of auto-supplying keys).
- The three CNAME selector IDs are **per-account** from SMTP2GO. The SPF include (`spf.smtp2go.com`) and relay host (`mail.smtp2go.com:587`) are constant.

### Pipeline notes
- The DNS step is **manual + external** — it can't be fully automated from the server build (touches Hetzner DNS, not the server). Worth a prominent prompted "do this in Hetzner DNS console now, then confirm" step (like the UptimeRobot/monitoring phase).
- Unrelated items surfaced in the logs worth a separate look later: the `spamass-milter.sock: No such file` warning (milter referenced but not running), and steady SSH/SMTP brute-force probes (e.g. `sasl_username=oracle`). Neither blocked anything; the brute-force noise is a hardening item.

### Open question
Turn this into an actual phase script (e.g. `phaseXc-smtp-relay.sh`) matching the existing idempotent bash style, with values pulled from `org-secrets.local`?
