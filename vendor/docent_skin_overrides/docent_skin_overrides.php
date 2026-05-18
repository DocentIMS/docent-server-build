<?php
/**
 * docent_skin_overrides
 *
 * Roundcube plugin that applies Docent's Outlook-fidelity customizations
 * on top of the outlook_plus skin. Loads CSS overrides and a small JS
 * module that handles DOM relocations (email-address placement, New
 * Message button injection) that pure CSS cannot do.
 *
 * Architecture decision (May 2026):
 *   Previously these customizations lived in
 *   /usr/share/roundcube/skins/outlook_plus/assets/styles/docent-overrides.css
 *   which mixed Docent code with vendor skin files and risked being
 *   overwritten on skin updates. This plugin encapsulates all Docent
 *   skin customizations so the vendor skin folder stays pristine.
 *
 * Install:
 *   1. Drop this directory at /usr/share/roundcube/plugins/docent_skin_overrides/
 *   2. Add 'docent_skin_overrides' to $config['plugins'] in Roundcube's
 *      main config (typically /etc/roundcube/config.inc.php).
 *   3. No DB schema changes, no user config changes.
 *
 * @package    Plugins
 * @author     Docent IMS LLC
 * @license    Proprietary (internal use only)
 */
class docent_skin_overrides extends rcube_plugin
{
    // Apply to all tasks (mail, addressbook, settings, calendar if installed)
    public $task = '.*';

    // Don't require auth - we want overrides on the login page too
    public $noajax = false;
    public $noframe = false;

    /**
     * Plugin entry point. Roundcube calls this on every page load.
     */
    public function init()
    {
        // Only inject assets on HTML pages, not API/JSON responses
        $rcmail = rcube::get_instance();
        if ($rcmail->output && $rcmail->output->type === 'html') {
            $this->add_hook('render_page', [$this, 'inject_assets']);
        }
    }

    /**
     * Hook callback: injects our CSS and JS into the page <head>.
     *
     * We use include_css/include_script rather than appending to a
     * template string, so Roundcube's asset versioning (cache-busting
     * query strings) is applied automatically.
     */
    public function inject_assets($args)
    {
        $rcmail = rcube::get_instance();

        // CSS works fine with include_css() since it accepts root-relative paths.
        $css_path = 'plugins/docent_skin_overrides/assets/docent-overrides.css';
        $rcmail->output->include_css($css_path);

        // JS: include_script() prefixes paths with "program/js/" which is
        // wrong for our case. Instead, inject a <script src> tag directly
        // via add_header(), which adds raw HTML to <head>.
        $js_url = $rcmail->output->asset_url('plugins/docent_skin_overrides/assets/docent-overrides.js');
        $rcmail->output->add_header(
            '<script src="' . htmlspecialchars($js_url, ENT_QUOTES) . '"></script>'
        );

        return $args;
    }
}
