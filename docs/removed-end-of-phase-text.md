===================================================================
  MANUAL VERIFICATION STEPS
===================================================================

Following are the manual steps that either configure or test the setup.
Based on experience, you may not need to run all of them.

**** Phase 1 - Checking SSH configuration ****

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

**** Phase 2 - Checking the domain configuration ****

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

**** Phase 3 - No Checks  ****


**** Phase 4 - Checking the domain configuration ****

  1. configure the reverse lookup on Hetzner.  To set it, return to
     Hetzner and manually activate a PTR (reverse DNS) record for the
     server's IP -> mail.$DOMAIN (Hetzner Cloud Console -> this server ->
     reverse DNS).

  2. Send a test message from the local server to the test mailbox:
       echo "test body" | mail -s "test subject" $TEST_MAILBOX

  3. Confirm it landed in the maildir:
       sudo find $VMAIL_HOME/$DOMAIN -name 'new' -type d
       sudo ls -la $VMAIL_HOME/$DOMAIN/$TEST_MAILBOX_LOCAL/new/

  4. Check the mail logs for any errors:
       sudo tail -50 /var/log/mail.log

  EXTERNAL CONFIGURATION (DNS):

  5. DNS is already done,   The MX, SPF, DKIM,
     DMARC and CAA records for $DOMAIN are created automatically in
     Hetzner DNS (phase-pre-hetzner.sh plus the post-dkim phase).
     Confirm them in Hetzner Cloud Console -> DNS -> $DOMAIN.

  6. After DNS has propagated (usually < 1 minute), verify:
       dig @8.8.8.8 MX $DOMAIN
       dig @8.8.8.8 TXT $DOMAIN
       dig @8.8.8.8 TXT ${DKIM_SELECTOR}._domainkey.$DOMAIN
       dig @8.8.8.8 TXT _dmarc.$DOMAIN

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

**** Phase 5 - Round Cube Testing ****

  1. Open a web browser and go to:
       https://${DOMAIN}${ROUNDCUBE_URL_PATH}/

     You should see the Roundcube login page.

  2. Log in with the test mailbox credentials from Phase 4:
       Username:  test@${DOMAIN}  (full email address required)
       Password:  (the test mailbox password from Phase 4)

  3. Try composing a new message and sending it. Check the mail log:
       sudo tail -30 /var/log/mail.log

     You should see SASL authentication and outbound delivery.

  4. SIEVE FILTER TEST:
     Click Settings (top right gear) -> Filters -> + (create rule)
     If managesieve is working, you'll see Sieve rule editor.
     The default global script (file X-Spam-Flag mail to Junk) is already
     active - you don't need to recreate it. This is for adding
     per-user custom rules.

  5. Check for errors:
       sudo tail /var/log/roundcube/errors.log
       sudo tail /var/log/apache2/error.log

  **** Phase 5a-rc-plus - Round Cube Skin ****

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

**** Phase 5b - Global Address Book ****

  1. Open Roundcube webmail in your browser and log in (or hard-refresh
     if you already had it open).

  2. Click the Contacts icon in the left sidebar.

  3. You should see "$ADDRESSBOOK_DISPLAY_NAME" listed alongside
     Personal Addresses, Collected Recipients, and Trusted Senders.

  4. Add a test contact in $ADDRESSBOOK_DISPLAY_NAME. Log out and back
     in as a different user — they should see the same contact.

  5. To pre-populate $ADDRESSBOOK_DISPLAY_NAME for this tenant, use
     Roundcube's Import feature in the contacts UI (vCard or CSV),
     or insert directly into the contacts table with user_id set to
     the dummy user ($ADDRESSBOOK_USER) created on first access.

  6. Check for plugin errors after first use:
       sudo tail /var/log/roundcube/errors.log
       sudo tail /var/log/apache2/error.log

**** Phase 5c - Email AI ****

  1. Open Roundcube webmail and log in (hard-refresh if already open).

  2. AI Composer:
     - Click "Compose" to open the new-mail page
     - Look for an AI button or icon in the compose toolbar
     - Click it, fill in style/length/instructions, click Generate
     - You should get drafted email text inserted into the body

  3. AI Summary:
     - Open a longer email (more than a couple paragraphs)
     - You should see a one-sentence summary at the top
     - The first time may take a few seconds (cached in DB after that)

  4. If something doesn't work, check:
       sudo tail /var/log/roundcube/errors.log
       sudo tail /var/log/apache2/error.log

  5. To monitor your OpenAI spend:
       https://platform.openai.com/usage

  6. To turn AI features off later, edit:
       $XAI_CONFIG
     Set xai_enable_message_generation = false (or _view_summaries = false).
     Then: sudo systemctl reload apache2

**** Phase 6 - Wordpress ****

  1. Confirm CREDENTIALS.txt is saved in your password manager.
     Both WordPress passwords (admin and database) are in
     BACKEND PASSWORDS.

  2. Log in to WordPress:
       URL:      https://$DOMAIN/wp-admin/
       Username: $WP_ADMIN_USERNAME
       Password: see CREDENTIALS.txt BACKEND PASSWORDS (WordPress admin)

  3. Theme/configure the site to look like a real Docent project page,
     using whatever template/approach you've used before.

**** Phase 7 - Plone ****

  To log in:
    1. Open: https://$PLONE_PUBLIC_HOST/login
    2. Username: admin
       Password: see $REPO_ROOT/CREDENTIALS.txt (PLONE_ADMIN_PW)

  Useful commands going forward:
    sudo systemctl status  $PLONE_SYSTEMD_UNIT
    sudo systemctl restart $PLONE_SYSTEMD_UNIT
    sudo journalctl -u $PLONE_SYSTEMD_UNIT -f

==============================================================
  CREDENTIALS FOR $DOMAIN ($SERVER_IP)
  DocentIMS tenant server - $DOMAIN
  Generated: <generated_timestamp_utc>
==============================================================
  1. HETZNER CLOUD ACCOUNT (your account at hetzner.com)
==============================================================
  WHAT IT'S FOR:    Logging into the Hetzner Cloud Console to
                    manage your servers, view billing, see your
                    server list, or open a console to a server.
  WHERE YOU USE IT: https://console.hetzner.cloud (in browser)
  Username:         (your Hetzner account email)
  Password:         (your Hetzner account password)

  >>> NOT GENERATED BY THIS SCRIPT - this is your account
      with Hetzner, set up when you signed up. <<<

==============================================================
  2. HETZNER SERVER EMERGENCY ACCESS (when SSH is broken)
==============================================================
  WHAT IT'S FOR:    Reaching this server when SSH won't connect.
                    Emergency recovery only.
  WHERE YOU USE IT: Hetzner Cloud Console -> select this server.
                    Two tools there, neither needs SSH:
                      - "Console": a browser VNC window onto the
                        server's screen (the "$PLONE_SITE_NAME login:" prompt)
                      - "Rescue": reboots into a recovery Linux so
                        you can mount and repair the disk
  Login:            This server was provisioned with SSH-key auth
                    and root password login DISABLED - there is no
                    root password. Recover via Rescue mode, or use
                    the VNC Console once a user password exists
                    (phase 1 sets the wayne password).

  >>> NO PASSWORD GENERATED BY THIS SCRIPT - access is via your
      SSH key plus the Hetzner Cloud Console. <<<

==============================================================
  3. SSH ADMIN LOGIN  (your day-to-day server access)
==============================================================
  WHAT IT'S FOR:    Logging into the server via SSH using
                    MobaXterm, PuTTY, or any SSH client.
  WHERE YOU USE IT: ssh -p $SSH_PORT wayne@$SERVER_IP

                    Note: SSH is set to port $SSH_PORT (not the
                    default 22) in an attempt to reduce spam
                    attacks.

  Username:  wayne
  Password:  <wayne_password>

  Username:  admin
  Password:  <admin_password>

  Either user works. Both have full sudo. Use 'admin' if you
  need to give someone else access without sharing your wayne
  account.

  Username:  espen     (Plone developer access)
  Password:  <espen_password>

  espen has NO sudo. Member of 'plone' group, can do all Plone
  work in /home/plone/ as themselves (no sudo needed thanks to
  group-writable setgid permissions on /home/plone/<tenant>/).

==============================================================
  4. WEBMAIL TEST MAILBOX  (logging into Roundcube)
==============================================================
  WHAT IT'S FOR:    Logging into the Roundcube webmail to
                    test that email works.
  WHERE YOU USE IT: https://$DOMAIN/mail/

  Email address: $TEST_MAILBOX
  Password:      <test_mailbox_password>

==============================================================
  BACKEND PASSWORDS (mostly software-only, listed for recovery)
==============================================================
  Most of these are used by software internally and you'll never
  type them into a login screen. The exception is WordPress admin,
  which IS a login you'll use - it lives here for convenience so all
  generated passwords are in one place.

  MariaDB root:        <mariadb_root_password>
  Mail database:       <mail_db_password>
  Roundcube database:  <roundcube_db_password>
  Roundcube DES key:   <roundcube_des_key>
  WordPress database:  <wordpress_db_password>
  WordPress admin:     <wordpress_admin_password>
			(user: $WP_ADMIN_USERNAME)
                        login: https://$DOMAIN/wp-admin/
  Plone admin:         <plone_admin_password>
			(user: admin)
                         login: https://team.$DOMAIN/login

==============================================================
  PURCHASED LICENSE KEYS
==============================================================
  Roundcube Plus:      <roundcube_plus_license_key>
  AI API key:          <ai_api_key>

==============================================================
  *** SAVE THIS FILE TO YOUR PASSWORD MANAGER NOW. ***

  Keep this file on the server until the whole build - including
  the Plone phases (7a-7d) - is finished and verified. The Plone
  phases read PLONE_ADMIN_PW from this file. Once Plone is done
  and everything is confirmed working, you may delete it with:
      rm $REPO_ROOT/CREDENTIALS.txt
==============================================================
