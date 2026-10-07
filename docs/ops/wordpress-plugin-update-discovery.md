# EventSales WordPress update discovery

WP-SOURCE-06 adds native, read-only update discovery for the four EventSales WordPress plugins. WordPress 5.8 and newer can show when a newer EventSales release is available. WordPress 5.6 and 5.7 continue to run the plugins but do not get this update notice.

The active `eventsales-integration-health` plugin owns the shared updater. Its update-discovery module uses the native `Update URI` header and `update_plugins_github.com` filter. It recognizes only these exact plugin basenames and the canonical Update URI `https://github.com/JCSchoeman96/EventSales`:

| Plugin slug | Main file | JC-320 version |
| --- | --- | ---: |
| `eventsales-tickera-catalog-feed` | `eventsales-tickera-catalog-feed.php` | `0.1.2` |
| `eventsales-woo-order-index-feed` | `eventsales-woo-order-index-feed.php` | `0.2.2` |
| `eventsales-woo-order-line-identity` | `eventsales-woo-order-line-identity.php` | `0.1.2` |
| `eventsales-integration-health` | `eventsales-integration-health.php` | `0.1.3` (WP-SOURCE-08 verifier owner) |

Other plugins that use a GitHub `Update URI` pass through without an EventSales request or response.

## Metadata checks

When WordPress checks an EventSales plugin and the shared cache is empty, the updater requests the latest published release from:

```text
https://api.github.com/repos/JCSchoeman96/EventSales/releases/latest
```

It rejects drafts, prereleases, missing or duplicate `release-manifest.json` assets, unexpected tags, and malformed release manifests. It retrieves only the manifest asset using its fixed GitHub API asset ID. It does not request any ZIP file or use a remote URL from the manifest.

All four plugin rows share the site transient `eventsales_wp_update_discovery_v1`. Valid metadata is cached for a fixed 12 hours; checking another plugin row does not extend that expiry. Errors are cached for 15 minutes. An in-request memo preserves the first result if a transient write fails, so the remaining plugin rows do not trigger duplicate requests. Each request has a five-second timeout. Automatic redirects are off. The updater follows no more than three redirects, and it accepts only HTTPS redirects to the exact host `release-assets.githubusercontent.com`. A different host or redirect scheme fails closed.

The updater sends no cookies, authorization, site URL, order data, ticket-holder data, catalog secrets, HMAC secrets, WordPress credentials, or EventSales API credentials. It stores no raw response body, HTTP headers, redirect URL, or signed query string.

## WordPress update response

For a valid manifest row whose marketing version is greater than the installed version, WordPress receives the plugin slug, release version, fixed GitHub release details URL, required PHP version, and `autoupdate: false`.

WP-SOURCE-06 responses never include a raw GitHub ZIP URL, release-assets host URL, or workflow artifact URL.

When WP-SOURCE-08 execution authority succeeds on an `immutable: true` public release, the response also includes:

```text
package = eventsales-verified://<github-release-id>/<asset-id>/<slug>
```

That sentinel is not downloadable without Integration Health’s `upgrader_pre_download` handler. If execution authority fails (mutable release, bad asset digest, incomplete eight-asset set, and similar), the JC-320 notification fields may still appear but `package` must be absent.

Clicking **Update now** re-fetches the exact GitHub release by ID, re-validates the manifest and asset digest, streams the asset to a temp file, checks SHA-256, and only then returns the path to `Plugin_Upgrader`. EventSales plugin auto-updates are denied via `auto_update_plugin`.

Manual operator installs from WP-SOURCE-05 remain supported for environments that do not use native verified updates.

## Site Health and diagnostics

The EventSales update-discovery debug section reads local plugin headers and the current site transient. WordPress calls `wp_update_plugins()` while rendering Site Health Info, so the owner marks `load-site-health.php` requests and skips GitHub discovery during them. Opening either Site Health screen does not call GitHub or refresh metadata. It may show whether the owner is active, WordPress capability, installed plugin versions, the last cached category and check time, and cached release ID and versions.

Diagnostics use only bounded categories: `never_checked`, `current`, `update_available`, `wp_version_unsupported`, `remote_timeout`, `remote_http_error`, `release_missing`, `manifest_missing`, `manifest_invalid`, `tag_mismatch`, and `redirect_rejected`. They do not include response bodies, stack traces, header dumps, or signed redirect URLs.

## Validation

Run the fake-response PHP tests and the distribution/release checks from the repository root:

```bash
php integrations/wordpress/eventsales-integration-health/tests/update-discovery-test.php
php integrations/wordpress/eventsales-integration-health/tests/verified-package-delivery-test.php
php integrations/wordpress/eventsales-integration-health/tests/integration-health-test.php
bash scripts/ci_wordpress_plugin_distribution.sh
```

The discovery and verified-package tests do not contact GitHub. They cover notification vs execution authority, sentinel parsing, click-time revalidation, redirects, streaming, hash verification, auto-update denial, and Site Health's no-network behavior.

The published immutable release `eventsales-wp-2026.10.04.1` carries catalog `0.1.2`, order index `0.2.2`, order-line identity `0.1.2`, and Integration Health `0.1.2`. After JC-328 merges, the next source candidate should bump Integration Health to `0.1.3` while sibling plugin versions stay unchanged until their bytes change. Follow [the WP-SOURCE-05 lifecycle guide](wordpress-plugin-release-lifecycle.md) before any new publication.
