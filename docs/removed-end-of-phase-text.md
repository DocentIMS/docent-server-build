# Removed end-of-phase text (for consolidation into the final "manual steps" block)

This file accumulates the per-phase summary / verification / next-steps blocks
that have been removed from individual phase scripts (per operator preference:
roll them into a single "manual steps" block at the very end of `run-phases`).
Trim or fold into the consolidated final block; nothing here is live anymore.

---

## From `phase1.sh` (removed) — end-of-phase PASSWORDS block

```
===================================================================
  PASSWORDS
===================================================================

  All passwords are in CREDENTIALS.txt at the repo root.
  This script does NOT print passwords (to avoid scrollback exposure).

  To view the credentials again:
    cat /root/server-build/CREDENTIALS.txt
```

---

## From `phase1.sh` (removed) — MANUAL VERIFICATION STEPS

```
===================================================================
  MANUAL VERIFICATION STEPS (cannot be automated)
===================================================================

  These steps require an external connection and CANNOT be checked
  by this script. Do them from your Windows machine while keeping
  this session open as a safety net.

  IMPORTANT: get the password for $ADMIN_USER from CREDENTIALS.txt
  BEFORE you try to SSH. Three wrong attempts = 1-hour fail2ban
  lockout from your IP.

  1. Open a NEW terminal window and SSH in as your personal admin:
       ssh -p $SSH_PORT $ADMIN_USER@$SERVER_IP
     This proves the new port and user account work end-to-end.

  2. Verify root SSH is rejected (do this from another new session):
       ssh -p $SSH_PORT root@$SERVER_IP
     This should fail with "Permission denied".

  3. Confirm CREDENTIALS.txt is saved in your password manager.

  4. (Optional) Clear your terminal scrollback:
       clear && history -c

  Once these checks are done, Phase 1 is fully complete and you
  can proceed to Phase 2 (Web server + TLS foundation).
```

---

## From `phase2.sh` (removed) — MANUAL VERIFICATION STEPS

```
===================================================================
  MANUAL VERIFICATION STEPS (cannot be automated)
===================================================================

  These steps require an external connection / human eyes and CANNOT
  be checked by this script. Do them from your Windows machine.

  1. Open https://$DOMAIN/ in a web browser.
     - You should see the placeholder page with the domain name.
     - The lock icon next to the URL should be CLOSED (green/secure).
     - No certificate warnings.

  2. Open http://$DOMAIN/ (no https) in the browser.
     - The browser should automatically redirect you to https://.

  3. Open https://www.$DOMAIN/ in the browser.
     - Should also work, with no cert warnings.

  4. (Optional) Run an SSL check at:
       https://www.ssllabs.com/ssltest/analyze.html?d=$DOMAIN
     A grade of A or A+ is expected for a default Let's Encrypt setup.

  Once these checks pass, Phase 2 is fully complete and you are ready
  for Phase 3 (Database - MySQL/MariaDB).
```

---

## From `phase4.sh` (removed) — MANUAL VERIFICATION & NEXT STEPS

```
===================================================================
  MANUAL VERIFICATION & NEXT STEPS
===================================================================

  INTERNAL TESTING (works without PTR or DNS records):

  1. Confirm CREDENTIALS.txt is saved in your password manager. The
     test mailbox password is in section 4. The Mail DB password is
     in BACKEND PASSWORDS.

  2. Send a test message from the local server to the test mailbox:
       echo "test body" | mail -s "test subject" $TEST_MAILBOX

  3. Confirm it landed in the maildir:
       sudo find $VMAIL_HOME/$DOMAIN -name 'new' -type d
       sudo ls -la $VMAIL_HOME/$DOMAIN/$TEST_MAILBOX_LOCAL/new/

  4. Check the mail logs for any errors:
       sudo tail -50 /var/log/mail.log

  EXTERNAL CONFIGURATION (DNS):

  5. DNS is already done - nothing to add by hand. The MX, SPF, DKIM,
     DMARC and CAA records for $DOMAIN are created automatically in
     Hetzner DNS (phase-pre-hetzner.sh plus the post-dkim phase).
     Confirm them in Hetzner Cloud Console -> DNS -> $DOMAIN.

  6. After DNS has propagated (usually < 1 minute), verify:
       dig @8.8.8.8 MX $DOMAIN
       dig @8.8.8.8 TXT $DOMAIN
       dig @8.8.8.8 TXT ${DKIM_SELECTOR}._domainkey.$DOMAIN
       dig @8.8.8.8 TXT _dmarc.$DOMAIN

  EXTERNAL TESTING (limited until PTR is set):

  7. Configure Thunderbird/Outlook to connect to:
       IMAP server:    $MAIL_HOSTNAME  port 993  SSL/TLS
       SMTP server:    $MAIL_HOSTNAME  port 587  STARTTLS
       Username:       $TEST_MAILBOX  (full email address)
       Password:       (the test mailbox password)
       (POP3 is deliberately not supported - use IMAP only)

  8. Send mail TO $TEST_MAILBOX from your existing Gmail/Outlook/etc.
     Should arrive in the test mailbox. (Inbound is not affected by PTR.)

  9. Send mail FROM $TEST_MAILBOX to a tolerant address. Will likely
     land in spam at major providers until PTR is set. This is expected.

  10. SPAM FILTER TEST:
      To verify SpamAssassin + Sieve are filing junk into Junk folder, send
      a test message containing the GTUBE string (a standard test marker that
      SpamAssassin always scores as spam):

         XJS*C4JDBQADN1.NSBN3*2IDNEN*GTUBE-STANDARD-ANTI-UBE-TEST-EMAIL*C.34X

      Send this from any external account TO $TEST_MAILBOX with that string
      in the body. Within seconds it should land in the JUNK folder (not the
      INBOX). Check the mail log:
         sudo tail /var/log/mail.log
      You'll see the X-Spam-Flag header added and Sieve filing it into Junk.

  11. Clear scrollback:  clear && history -c

  Once a PTR record is set, outbound deliverability to Gmail/Outlook/etc.
  improves dramatically without any code changes. To set it, return to
  Hetzner and manually activate a PTR (reverse DNS) record for the
  server's IP -> mail.$DOMAIN (Hetzner Cloud Console -> this server ->
  reverse DNS). No support ticket is needed.
```

---

## From `phase3.sh` (removed) — PASSWORDS

```
===================================================================
  PASSWORDS
===================================================================

  All passwords are in CREDENTIALS.txt at the repo root.
  This script does NOT print passwords (to avoid scrollback exposure).

  The MariaDB root password is also stored in /root/.my.cnf
  (root-only readable) so 'mysql' and 'mysqldump' work without -p
  prompts when run as root.
```

---

## From `phase3.sh` (removed) — MANUAL VERIFICATION STEPS

```
===================================================================
  MANUAL VERIFICATION STEPS
===================================================================

  Quick sanity checks (run as root):

  1. Connect to MariaDB and confirm version:
       sudo mysql -e 'SELECT VERSION();'

  2. List databases (should see only system databases at this stage):
       sudo mysql -e 'SHOW DATABASES;'

  3. Confirm CREDENTIALS.txt is saved in your password manager.

  Once these are done, Phase 3 is complete and you are ready for
  Phase 4 (Mail server: Postfix + Dovecot + OpenDKIM + OpenDMARC + SpamAssassin).
```

---

## From `phase4.sh` (removed) — PASSWORDS

```
===================================================================
  PASSWORDS
===================================================================

  All passwords are in CREDENTIALS.txt at the repo root.
  This script does NOT print passwords (to avoid scrollback exposure).

  The mail DB password is also stored in:
    /etc/postfix/mysql-*.cf
    /etc/dovecot/dovecot.conf
```

---

## From `phase4.sh` (removed) — DNS RECORDS - HANDLED AUTOMATICALLY

```
===================================================================
  DNS RECORDS - HANDLED AUTOMATICALLY
===================================================================

  No manual DNS work is needed. All mail DNS records for $DOMAIN are
  created automatically in Hetzner DNS:

    - A, MX, SPF, DMARC and CAA records are created by phase-pre-hetzner.sh.
    - The DKIM TXT record is published by the post-dkim phase, which
      run-phases.sh runs automatically right after this phase.

  You can confirm them in the Hetzner Cloud Console -> DNS -> $DOMAIN.
```

---

## From `phase-post-hetzner-dkim.sh` (removed) — Verification

```
=== Verification ===

  DKIM record published. To verify externally (give DNS a few minutes
  to propagate first):

    dig +short TXT ${DKIM_NAME}.${DOMAIN}

  Or with a public resolver:

    dig +short TXT ${DKIM_NAME}.${DOMAIN} @1.1.1.1

  You should see the v=DKIM1 record. If it shows the wrong value or no
  value, check Hetzner Console -> DNS -> ${DOMAIN}.

  Send a test mail to https://www.mail-tester.com to confirm DKIM
  signing works end-to-end (Postfix + OpenDKIM + DNS).
```

---

## From `phase5.sh` (removed) — PASSWORDS

```
===================================================================
  PASSWORDS
===================================================================

  All passwords are in CREDENTIALS.txt at the repo root.
  This script does NOT print passwords (to avoid scrollback exposure).

  The Roundcube DB password and DES key are also stored in:
    /etc/roundcube/config.inc.php
```

---

## From `phase5.sh` (removed) — MANUAL VERIFICATION & NEXT STEPS

```
===================================================================
  MANUAL VERIFICATION & NEXT STEPS
===================================================================

  1. Open a web browser and go to:
       https://${DOMAIN}${ROUNDCUBE_URL_PATH}/

     You should see the Roundcube login page.

  2. Log in with the test mailbox credentials from Phase 4:
       Username:  test@${DOMAIN}  (full email address required)
       Password:  (the test mailbox password from Phase 4)

  3. You should land in the inbox and see your existing messages
     (the local test plus any others).

  4. Try composing a new message and sending it. Check the mail log:
       sudo tail -30 /var/log/mail.log

     You should see SASL authentication and outbound delivery.

  5. SIEVE FILTER TEST:
     Click Settings (top right gear) -> Filters -> + (create rule)
     If managesieve is working, you'll see Sieve rule editor.
     The default global script (file X-Spam-Flag mail to Junk) is already
     active - you don't need to recreate it. This is for adding
     per-user custom rules.

  6. Check for errors:
       sudo tail /var/log/roundcube/errors.log
       sudo tail /var/log/apache2/error.log

  Roundcube is now available alongside Thunderbird/Outlook IMAP access.
  Users can pick whichever interface they prefer. Both go through the
  same Postfix and Dovecot - same mailbox, same folders.
```

---

## From `phase5a-rc-plus.sh` (removed) — MANUAL VERIFICATION & NEXT STEPS

```
===================================================================
  MANUAL VERIFICATION & NEXT STEPS
===================================================================

  1. Open https://${DOMAIN}/mail/ in your browser (or hard-refresh
     if you already had it open) and log in.

  2. The interface should now use the "outlook_plus" skin (Outlook-style
     navigation, modern layout, mobile-capable).

  3. Verify the plugin works:
       - Signature Designer (xsignature): go to Settings -> Identities -> edit
         your identity. There should now be a richer signature editor than
         the default plain text box.

  4. Check for any plugin errors:
       sudo tail /var/log/roundcube/errors.log
       sudo tail /var/log/apache2/error.log

  5. AI Assistant (xai) is installed by Phase 5c (Email AI), not this phase.
     Run that next if you want AI features in Roundcube.

  Re-running this script is safe - it preserves any plugin-specific config
  customizations you make in plugins/<plugin>/config.inc.php.
```
