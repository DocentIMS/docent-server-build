# Default branding

Phase 5b looks for branding assets in this order:

1. `branding/<domain>/`     — per-domain branding (highest priority)
2. `branding/_default/`     — falls back here when no per-domain dir exists

Files in this directory:

| File | Purpose |
|------|---------|
| `docent-logo.svg` | Wide wordmark logo. Used for Roundcube login page, top bar, and avatar circle. |
| `docent-icon.svg` | Square icon. Reserved for favicon / small monogram use. |

To brand a specific client domain differently, create
`branding/<their-domain>/` and drop in matching filenames. The per-domain
directory overrides `_default` file-by-file (rsync two-pass).

Phase 5b will also place Inter font files in `_default/fonts/` on first
run if it has internet access. Those persist in the repo so subsequent
servers don't need to re-download.
