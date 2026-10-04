# EventSales WordPress update discovery

WP-SOURCE-06 adds native, read-only update discovery for the four EventSales WordPress plugins. WordPress 5.8 and newer can show when a newer EventSales release is available. WordPress 5.6 and 5.7 continue to run the plugins but do not get this update notice.

The active `eventsales-integration-health` plugin owns the shared updater. Its update-discovery module uses the native `Update URI` header and `update_plugins_github.com` filter. It recognizes only these exact plugin basenames and the canonical Update URI `https://github.com/JCSchoeman96/EventSales`:

| Plugin slug | Main file | JC-320 version |
| --- | --- | ---: |
| `eventsales-tickera-catalog-feed` | `eventsales-tickera-catalog-feed.php` | `0.1.2` |
| `eventsales-woo-order-index-feed` | `eventsales-woo-order-index-feed.php` | `0.2.2` |
| `eventsales-woo-order-line-identity` | `eventsales-woo-order-line-identity.php` | `0.1.2` |
| `eventsales-integration-health` | `eventsales-integration-health.php` | `0.1.2` |

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

The response omits `package`. It contains no ZIP URL, release asset URL, workflow artifact URL, or temporary signed URL. This release metadata can notify an administrator that a newer version may exist. It cannot authorize WordPress to download or install code.

Installation remains a separate WP-SOURCE-05 operator process. Before a release candidate is promoted for installation, the release-candidate workflow must run from the default branch and its `actions/attest@v4` attestations must be verified. The operator then verifies archive hashes and upgrade-transition preflight before publishing and manually installing a reviewed package.

## Site Health and diagnostics

The EventSales update-discovery debug section reads local plugin headers and the current site transient. WordPress calls `wp_update_plugins()` while rendering Site Health Info, so the owner marks `load-site-health.php` requests and skips GitHub discovery during them. Opening either Site Health screen does not call GitHub or refresh metadata. It may show whether the owner is active, WordPress capability, installed plugin versions, the last cached category and check time, and cached release ID and versions.

Diagnostics use only bounded categories: `never_checked`, `current`, `update_available`, `wp_version_unsupported`, `remote_timeout`, `remote_http_error`, `release_missing`, `manifest_missing`, `manifest_invalid`, `tag_mismatch`, and `redirect_rejected`. They do not include response bodies, stack traces, header dumps, or signed redirect URLs.

## Validation

Run the fake-response PHP tests and the distribution/release checks from the repository root:

```bash
php integrations/wordpress/eventsales-integration-health/tests/update-discovery-test.php
php integrations/wordpress/eventsales-integration-health/tests/integration-health-test.php
bash scripts/ci_wordpress_plugin_distribution.sh
```

The update-discovery tests do not contact GitHub. They cover cache sharing, plugin identity, supported WordPress versions, version comparisons, release and manifest validation, HTTP failures, redirects, the package-free response, and Site Health's no-network behavior.

The next real candidate after JC-320 should use catalog `0.1.2`, order index `0.2.2`, order-line identity `0.1.2`, and Integration Health `0.1.2`. JC-320 itself must not publish or promote that release. Follow the release process in [the WP-SOURCE-05 lifecycle guide](wordpress-plugin-release-lifecycle.md) after the implementation merges.
