# docent_skin_overrides

Roundcube plugin that applies Docent IMS branding and Outlook-on-the-web style
customizations on top of the RoundcubePlus `outlook_plus` skin.

## What it does

Loads two asset files into every Roundcube page:

- `assets/docent-overrides.css` — Visual customizations (colors, typography,
  layout, the new horizontal docent info system logo, Outlook-style nav-pane
  gray, header band, etc.)
- `assets/docent-overrides.js` — DOM manipulation (top header band with
  logo/search/account corner, blue "New message" button at top of folder
  list, gray "Cancel message" button on compose page, account corner with
  email + avatar + dropdown menu, etc.)

## Requirements

- Roundcube 1.6+
- RoundcubePlus `outlook_plus` skin (Wayne's licensed RC+ subscription)
- Docent logo SVG installed at `/srv/www/<domain>/branding/docent-icon.svg`

## Installation

1. Place this folder at `/usr/share/roundcube/plugins/docent_skin_overrides/`
2. Symlink it to `/var/lib/roundcube/plugins/docent_skin_overrides`:
   ```
   sudo ln -sfn /usr/share/roundcube/plugins/docent_skin_overrides \
                /var/lib/roundcube/plugins/docent_skin_overrides
   ```
3. Add `'docent_skin_overrides'` to the `$config['plugins']` array in
   `/etc/roundcube/config.inc.php`
4. Set permissions:
   ```
   sudo chown -R root:www-data /usr/share/roundcube/plugins/docent_skin_overrides
   sudo chmod -R 644 /usr/share/roundcube/plugins/docent_skin_overrides/assets/*
   sudo chmod 755 /usr/share/roundcube/plugins/docent_skin_overrides
   sudo chmod 755 /usr/share/roundcube/plugins/docent_skin_overrides/assets
   ```

## Server-wide default skin color

Set the Fluent blue (`#0075c8`) as server-wide default by copying
`/usr/share/roundcube/skins/outlook_plus/config.inc.php.sample` to
`config.inc.php` and setting `$config['xskin_color'] = '0075c8';`

## Files

```
docent_skin_overrides/
├── docent_skin_overrides.php   — Plugin entry point (loads CSS + JS)
├── assets/
│   ├── docent-overrides.css    — All visual customizations
│   └── docent-overrides.js     — All DOM manipulations
└── README.md                   — This file
```

## License

Proprietary — Docent IMS LLC. Internal use only.
