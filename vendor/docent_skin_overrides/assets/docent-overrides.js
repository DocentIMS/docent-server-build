/**
 * docent-overrides.js
 *
 * Companion to docent-overrides.css. Handles DOM manipulations that
 * CSS cannot do:
 *   - Injects a "New Message" button at the top-left of the toolbar
 *     (using Microsoft Fluent UI System Icons, MIT-licensed)
 *   - Relocates the user's email-address element from the top bar to
 *     sit above the message-list column
 *
 * Design notes:
 *   - Idempotent: safe to run more than once. Each operation checks
 *     for an "already done" marker before acting.
 *   - Defensive: wrapped in try/catch so a single failure doesn't
 *     blow up other initialization.
 *   - Roundcube-aware: hooks into rcmail.addEventListener('init') so
 *     it only runs after Roundcube's own UI is ready. Falls back to
 *     DOMContentLoaded if rcmail is unavailable (login page, etc.).
 *
 * @author  Docent IMS LLC
 * @license Proprietary (internal use only)
 */
(function () {
    'use strict';

    // Fluent UI System Icons -> "Compose" / "New mail" icon
    // Source: https://github.com/microsoft/fluentui-system-icons (MIT)
    // Inlined as SVG string to avoid an extra HTTP request and to keep
    // the plugin self-contained.
    var FLUENT_NEW_MAIL_SVG = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 20 20" aria-hidden="true">' +
        '<path d="M14.5 2A3.5 3.5 0 0 1 18 5.5v3.66a4.5 4.5 0 0 0-1-.16V5.5A2.5 2.5 0 0 0 14.5 3h-9A2.5 2.5 0 0 0 3 5.5v9A2.5 2.5 0 0 0 5.5 17h3.66c.04.35.1.68.18 1H5.5A3.5 3.5 0 0 1 2 14.5v-9A3.5 3.5 0 0 1 5.5 2h9zM10 10.5a.5.5 0 0 1-.5.5h-3a.5.5 0 0 1 0-1h3a.5.5 0 0 1 .5.5zm3-3a.5.5 0 0 1-.5.5h-6a.5.5 0 0 1 0-1h6a.5.5 0 0 1 .5.5zm5.85 5.65a.5.5 0 0 0-.7-.7L14 16.58l-2.15-2.13a.5.5 0 0 0-.7.7l2.5 2.5c.2.2.5.2.7 0l4.5-4.5z"/>' +
        '</svg>';

    // Fluent UI System Icons -> Close / X (for cancel-message mode)
    var FLUENT_CLOSE_SVG = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 20 20" aria-hidden="true">' +
        '<path d="m4.09 4.22.06-.07a.5.5 0 0 1 .63-.06l.07.06L10 9.29l5.15-5.14a.5.5 0 0 1 .63-.06l.07.06c.18.18.2.45.06.63l-.06.07L10.71 10l5.14 5.15c.18.18.2.45.06.63l-.06.07a.5.5 0 0 1-.63.06l-.07-.06L10 10.71l-5.15 5.14a.5.5 0 0 1-.63.06l-.07-.06a.5.5 0 0 1-.06-.63l.06-.07L9.29 10 4.15 4.85a.5.5 0 0 1-.06-.63l.06-.07-.06.07z"/>' +
        '</svg>';


    /**
     * Build the Outlook-style top header band.
     *
     *   [ logo ]       [ search bar centered ]       [ email · avatar ]
     *
     * The band is a fixed-position bar at the top of the page. We push
     * the existing #layout down by setting padding-top on it equal to
     * the band height. Everything else (folder list, message list, etc.)
     * lives below.
     *
     * Logo source: clone the existing #logo img from popover-header.
     * Search source: clone the existing search form/bar from #layout-list.
     * Account area: the existing #docent-account-corner (rendered by
     *   injectAccountCorner) will be repositioned into the band.
     */
    function buildHeaderBand() {
        // Idempotency
        if (document.getElementById('docent-header-band')) {
            return;
        }

        var band = document.createElement('div');
        band.id = 'docent-header-band';

        // --- Logo slot (left) ---
        var logoSlot = document.createElement('div');
        logoSlot.className = 'docent-header-logo-slot';
        var srcLogo = document.getElementById('logo');
        if (srcLogo) {
            // Clone so the original stays in the DOM (some skin JS may
            // reference it); hide the original via CSS.
            var logoClone = srcLogo.cloneNode(true);
            logoClone.id = 'docent-header-logo';
            logoSlot.appendChild(logoClone);
        }
        band.appendChild(logoSlot);

        // --- Search slot (center) ---
        var searchSlot = document.createElement('div');
        searchSlot.className = 'docent-header-search-slot';

        // The existing search bar is a <div role="search"> with class
        // "searchbar menu" inside #layout-list. Move it (not clone) so
        // its Roundcube event handlers continue to work.
        var srcSearch = document.querySelector('#layout-list .searchbar')
                     || document.querySelector('#layout-list [role="search"]')
                     || document.querySelector('.searchbar');
        if (srcSearch) {
            searchSlot.appendChild(srcSearch);
        }
        band.appendChild(searchSlot);

        // --- Account slot (right) ---
        // Placeholder; injectAccountCorner will populate this slot if
        // it finds the band already in DOM.
        var accountSlot = document.createElement('div');
        accountSlot.className = 'docent-header-account-slot';
        accountSlot.id = 'docent-header-account-slot';
        band.appendChild(accountSlot);

        // Insert at the top of <body>
        document.body.insertBefore(band, document.body.firstChild);

        // Mark body so CSS can push everything else down
        document.body.classList.add('docent-header-band-active');
    }


    /**
     * Inject the New Message button into the top toolbar.
     * Placement varies by mode:
     *   - Inbox view: above the folder list (#layout-sidebar) as a
     *     prominent blue "New message" block button.
     *   - Compose view: left of Save in the compose toolbar, as a
     *     gray-outlined "Cancel message" button (X icon).
     */
    function injectNewMessageButton() {
        // Only on Mail task
        if (!document.body.classList.contains('task-mail')) {
            return;
        }

        // Idempotency check
        if (document.getElementById('docent-new-message')) {
            return;
        }

        // Determine mode: compose vs inbox/folder view.
        var isComposeMode = document.body.classList.contains('action-compose');

        // Target depends on mode.
        var target;
        if (isComposeMode) {
            // Compose view: find the Save button and insert before it.
            // The skin creates a "clone" of Save inside a hidden bottom
            // footer navigation - we MUST skip that one and find the
            // visible Save in the top toolbar.
            // Strategy: find all Save candidates, pick the one whose
            // parent chain is visible (not hidden by display:none).
            var saveCandidates = document.querySelectorAll(
                'a.save.draft, a.button.save, a.save.draft.button, ' +
                '#toolbar-menu a.save, a[onclick*="save-draft"]'
            );

            var saveBtn = null;
            for (var i = 0; i < saveCandidates.length; i++) {
                var cand = saveCandidates[i];
                // Skip any candidate whose id ends in "-clone" (these
                // are the duplicated buttons in hidden navigation).
                if (cand.id && cand.id.indexOf('-clone') !== -1) {
                    continue;
                }
                // Skip if inside a hidden parent (e.g. .hide-nav-buttons)
                var rect = cand.getBoundingClientRect();
                if (rect.width === 0 && rect.height === 0) {
                    continue;
                }
                saveBtn = cand;
                break;
            }

            // Fallback: if no visible candidate found via dimensions,
            // take the first non-clone candidate (might be visible after
            // a paint cycle).
            if (!saveBtn) {
                for (var j = 0; j < saveCandidates.length; j++) {
                    if (!saveCandidates[j].id || saveCandidates[j].id.indexOf('-clone') === -1) {
                        saveBtn = saveCandidates[j];
                        break;
                    }
                }
            }

            if (saveBtn) {
                target = saveBtn.parentElement;
            } else {
                return;  // No Save button found; skip.
            }
        } else {
            // Inbox view: above the folder list
            target = document.querySelector('#layout-sidebar')
                  || document.querySelector('#layout-list');
            if (!target) {
                return;
            }
        }

        // Build the button.
        var btn = document.createElement('a');
        btn.id = 'docent-new-message';
        btn.setAttribute('role', 'button');
        btn.href = '#';

        if (isComposeMode) {
            // Cancel mode: use Roundcube's native "discard" icon class
            // so it matches the other toolbar buttons (Save, Attach, etc.)
            // exactly. The skin defines .menu a.discard::before and
            // a.button.icon.discard::before with the correct glyph.
            btn.classList.add('docent-cancel-mode');
            btn.classList.add('button');
            btn.classList.add('discard');
            btn.title = 'Cancel and return to inbox';
            btn.innerHTML = '<span class="inner">Cancel</span>';
        } else {
            // New message mode: blue solid, envelope icon, "New message"
            btn.title = 'Create a new message';
            btn.innerHTML = FLUENT_NEW_MAIL_SVG + '<span class="label">New message</span>';
        }

        btn.addEventListener('click', function (ev) {
            ev.preventDefault();
            if (typeof rcmail === 'undefined' || !rcmail.command) {
                return;
            }
            if (isComposeMode) {
                // Cancel: navigate back to inbox via Roundcube's list
                // command. If there are unsaved changes, Roundcube will
                // prompt the user; on confirm it actually navigates.
                rcmail.command('list', '', this, ev);
            } else {
                rcmail.command('compose', '', this, ev);
            }
        });

        // Placement:
        if (isComposeMode) {
            // Insert before Save's containing <li> (or before Save itself
            // if it's not in a list). Wrap our button in <li> if needed.
            var saveItem = target;
            if (saveItem.tagName === 'LI' && saveItem.parentElement) {
                // Wrap our button in a <li> too so it integrates with
                // the toolbar list structure.
                var wrapper = document.createElement('li');
                wrapper.setAttribute('role', 'menuitem');
                wrapper.appendChild(btn);
                saveItem.parentElement.insertBefore(wrapper, saveItem);
            } else {
                saveItem.parentElement.insertBefore(btn, saveItem);
            }
        } else {
            // Insert at top of sidebar
            target.insertBefore(btn, target.firstChild);
        }
    }

    /**
     * Move the user's email-address element. CURRENTLY DISABLED per user
     * direction - email address now appears in the top-right account
     * corner via injectAccountCorner(), so this dedicated relocator is
     * not needed. Stub kept for API stability.
     */
    function relocateEmailAddress() {
        // No-op: superseded by injectAccountCorner().
    }

    /**
     * Heuristic fallback: find a span in the top header whose text
     * looks like an email address.
     */
    function findEmailSpanInHeader() {
        var spans = document.querySelectorAll('#layout-menu span, .header span, .header-title');
        for (var i = 0; i < spans.length; i++) {
            var text = (spans[i].textContent || '').trim();
            if (/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(text)) {
                return spans[i];
            }
        }
        return null;
    }


    /**
     * Build the top-right account corner: email address text + avatar
     * circle + dropdown containing the moon/info/logout icons that
     * normally live at the bottom-left of the rail.
     *
     * Layout:
     *
     *   [ test@example.com ]   ( T )      <- avatar always visible, click opens menu
     *                              \
     *                               [ moon ]
     *                               [ info ]
     *                               [ log off ]
     */
    function injectAccountCorner() {
        // Idempotency
        if (document.getElementById('docent-account-corner')) {
            return;
        }

        // Find the email address in the existing markup
        var emailEl = findEmailSpanInHeader();
        var emailText = emailEl ? (emailEl.textContent || '').trim() : '';

        // Find the three rail icons we're moving (dark mode toggle,
        // about/info, logout) - they live in #taskmenu .special-buttons
        var darkBtn   = document.querySelector('#taskmenu a.theme.dark, #taskmenu a.theme');
        var aboutBtn  = document.querySelector('#taskmenu a.about');
        var logoutBtn = document.querySelector('#taskmenu a.logout');

        // Build the account corner container, append to body so it
        // floats over the top-right regardless of layout container
        var corner = document.createElement('div');
        corner.id = 'docent-account-corner';

        // Email label (left of avatar)
        if (emailText) {
            var label = document.createElement('span');
            label.className = 'docent-account-email';
            label.textContent = emailText;
            corner.appendChild(label);
        }

        // Avatar (circle with first letter)
        var initial = emailText ? emailText.charAt(0).toUpperCase() : '?';
        var avatar = document.createElement('button');
        avatar.id = 'docent-account-avatar';
        avatar.type = 'button';
        avatar.className = 'docent-account-avatar';
        avatar.setAttribute('aria-haspopup', 'true');
        avatar.setAttribute('aria-expanded', 'false');
        avatar.textContent = initial;
        avatar.title = emailText || 'Account';
        corner.appendChild(avatar);

        // Dropdown menu (hidden until avatar click)
        var menu = document.createElement('div');
        menu.id = 'docent-account-menu';
        menu.className = 'docent-account-menu';
        menu.setAttribute('aria-hidden', 'true');
        menu.style.display = 'none';

        // Move (not clone) the three rail buttons into the menu, so
        // their existing click handlers and Roundcube wiring are
        // preserved. Wrap each in a list item.
        function appendMovedButton(srcBtn, fallbackLabel) {
            if (!srcBtn) {
                return;
            }
            var item = document.createElement('div');
            item.className = 'docent-account-menu-item';

            // Make the icon's accessible name visible as a text label
            var labelText = srcBtn.querySelector('.inner')
                ? srcBtn.querySelector('.inner').textContent.trim()
                : fallbackLabel;

            item.appendChild(srcBtn);
            var lbl = document.createElement('span');
            lbl.className = 'docent-account-menu-label';
            lbl.textContent = labelText;
            item.appendChild(lbl);

            // Make the entire item clickable. The moved <a> still has
            // its original href and onclick (Roundcube-wired), so we
            // forward clicks on the wrapper to the inner <a>.
            item.addEventListener('click', function (ev) {
                // If user clicked the actual <a>, let it handle itself
                if (ev.target === srcBtn || srcBtn.contains(ev.target)) {
                    return;
                }
                ev.preventDefault();
                ev.stopPropagation();
                // Trigger the original <a>'s click programmatically.
                // This invokes its onclick AND its href navigation,
                // exactly as if the user clicked the <a> directly.
                srcBtn.click();
            });

            menu.appendChild(item);
        }
        appendMovedButton(darkBtn,   'Dark mode');
        appendMovedButton(aboutBtn,  'About');
        appendMovedButton(logoutBtn, 'Logout');

        corner.appendChild(menu);

        // If the header band is built, append into its account slot.
        // Otherwise fall back to floating top-right (legacy behavior).
        var bandSlot = document.getElementById('docent-header-account-slot');
        if (bandSlot) {
            bandSlot.appendChild(corner);
        } else {
            document.body.appendChild(corner);
        }

        // Toggle dropdown on avatar click
        avatar.addEventListener('click', function (ev) {
            ev.stopPropagation();
            var open = menu.style.display !== 'none';
            menu.style.display = open ? 'none' : 'block';
            menu.setAttribute('aria-hidden', open ? 'true' : 'false');
            avatar.setAttribute('aria-expanded', open ? 'false' : 'true');
        });

        // Close on outside click
        document.addEventListener('click', function (ev) {
            if (!corner.contains(ev.target)) {
                menu.style.display = 'none';
                menu.setAttribute('aria-hidden', 'true');
                avatar.setAttribute('aria-expanded', 'false');
            }
        });

        // Hide the original email-address element (we've duplicated it
        // in the corner label)
        if (emailEl) {
            emailEl.style.display = 'none';
        }

        // Mark body so CSS knows the corner is active
        document.body.classList.add('docent-account-corner-active');
    }


    /**
     * Relocate the Folder Actions three-dot button.
     *
     * Default location: in the sidebar's .header (above the folder list),
     * with class "sidebar-menu". It opens a menu containing Compact /
     * Empty / Mark all read / Manage folders.
     *
     * Target location: after the "Mark" button in the message toolbar
     * at the top-right of the page.
     */
    function relocateFolderActions() {
        // Idempotency
        if (document.body.classList.contains('docent-folder-actions-moved')) {
            return;
        }

        // Find the source button. The skin uses class "sidebar-menu"
        // for this; data-popup links it to mailboxoptions-menu.
        var srcBtn = document.querySelector('a.sidebar-menu[data-popup="mailboxoptions-menu"]')
                  || document.querySelector('a[data-popup="mailboxoptions-menu"]');

        if (!srcBtn) {
            return;
        }

        // Find the destination toolbar - the message toolbar at top-right
        // containing Reply / Reply all / Forward / Delete / Mark.
        // In outlook_plus this is typically #layout-content .header or
        // a similar .toolbar inside #layout.
        var markBtn = document.querySelector('a.button.markmessage, a.markmessage, a[onclick*="markmessage"], a.button.mark, a.mark');
        var toolbar = markBtn ? markBtn.parentElement : null;

        // If we can't find the Mark button reliably, fall back to the
        // last .button in the top toolbar
        if (!toolbar) {
            var topToolbar = document.querySelector('#layout-content > .header')
                          || document.querySelector('#layout > .header');
            if (topToolbar) {
                var buttons = topToolbar.querySelectorAll('a.button, button');
                if (buttons.length) {
                    markBtn = buttons[buttons.length - 1];
                    toolbar = markBtn.parentElement;
                }
            }
        }

        if (!toolbar || !markBtn) {
            return;
        }

        // Move the button to just after Mark
        if (markBtn.nextSibling) {
            toolbar.insertBefore(srcBtn, markBtn.nextSibling);
        } else {
            toolbar.appendChild(srcBtn);
        }

        document.body.classList.add('docent-folder-actions-moved');
    }


    /**
     * Main entry: run all our DOM tweaks, defensively.
     */
    function applyDocentOverrides() {
        try { buildHeaderBand();        } catch (e) { console.warn('docent: header band failed', e); }
        try { injectNewMessageButton(); } catch (e) { console.warn('docent: button injection failed', e); }
        try { injectAccountCorner();    } catch (e) { console.warn('docent: account corner failed', e); }
        try { relocateFolderActions();  } catch (e) { console.warn('docent: folder actions relocate failed', e); }
        try { relocateEmailAddress();   } catch (e) { console.warn('docent: address relocation failed', e); }
    }

    // Hook into Roundcube's init event if available, otherwise fall
    // back to DOMContentLoaded.
    if (typeof rcmail !== 'undefined' && rcmail.addEventListener) {
        rcmail.addEventListener('init', applyDocentOverrides);
        // Also run on listupdate (after folder change or refresh) to
        // re-inject if Roundcube rerenders the toolbar.
        rcmail.addEventListener('listupdate', applyDocentOverrides);
    } else if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', applyDocentOverrides);
    } else {
        applyDocentOverrides();
    }
})();
