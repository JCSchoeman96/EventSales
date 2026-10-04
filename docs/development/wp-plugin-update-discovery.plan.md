# WP-SOURCE-06: read-only WordPress update discovery

Plan version: v1
Status: locked before updater implementation
Issue: JC-320
Branch: `t3code/wp-update-discovery`
Worktree: `/home/jcschoeman96/.t3/worktrees/EventSales/t3code-99135ad6`
Original base and current `origin/main`: `a8510f1093ca07c16108b70c556c0dbbaff1c024`
Original base tree: `7dbf3882aaa2cc477d1aa48eb0807594c17d1499`

## Goal and security boundary

WordPress administrators can see when a newer reviewed EventSales plugin release is available. Discovery reads public release metadata and validates the attached `release-manifest.json`. It never downloads or installs a plugin package.

GitHub release metadata can tell an administrator that a newer EventSales release may exist. WordPress does not trust that metadata to install or execute code. Package installation remains a separate operator action after WP-SOURCE-05 review, attestation, hash verification, and upgrade-transition preflight.

The update response will not contain a `package` key or package URL. It will set `autoupdate` to `false`. This work will not use upgrader hooks, `Plugin_Upgrader`, `WP_Automatic_Updater`, or legacy update-transient manipulation.

## Ownership and identity

The active `eventsales-integration-health` plugin owns discovery for the four-plugin suite. Its bootstrap will load a separate `includes/update-discovery.php` module. That module will register the native WordPress update filter and a local-only Site Health debug section. Existing integration-health observers and their no-network tests remain unchanged.

This creates a soft operational dependency: discovery runs while Integration Health is active. It adds no `Requires Plugins` header, sibling include, or hard dependency. Integration Health does not load or execute sibling plugin code.

Every EventSales main plugin file will declare this exact Update URI:

```text
https://github.com/JCSchoeman96/EventSales
```

On WordPress 5.8 and newer, the owner registers `update_plugins_github.com`. Before fetching metadata, the callback must match the exact Update URI, plugin basename, slug directory, main file, and one of the four canonical suite entries. Any other GitHub-hosted plugin passes through unchanged.

WordPress 5.6 and 5.7 keep their current plugin behavior and receive no update-discovery hook. WordPress 5.8 and newer use the native `Update URI` and `update_plugins_{$hostname}` mechanism. The plugin floor remains WordPress 5.6 and PHP 8.0.

## Remote release contract

The only release authority is the public repository `JCSchoeman96/EventSales`. Discovery starts with:

```text
GET https://api.github.com/repos/JCSchoeman96/EventSales/releases/latest
```

The response must describe a published release, with `draft` and `prerelease` both false, a non-empty tag, and exactly one asset named `release-manifest.json`. No ZIP is selected or requested.

The manifest is retrieved by the fixed GitHub API asset endpoint constructed from the validated positive integer asset ID:

```text
GET https://api.github.com/repos/JCSchoeman96/EventSales/releases/assets/{asset_id}
Accept: application/octet-stream
```

The request disables automatic redirects. Each redirect is checked before the next request. The exact allowed redirect host is `release-assets.githubusercontent.com`; schemes other than HTTPS, user-info, unexpected ports, any other host, and more than three redirects fail closed. Host matching is exact and does not use suffix matching.

The canonical repository currently has no published releases, so no EventSales asset redirect was available to inspect. GitHub's asset API documents both `200` and `302` responses for binary asset retrieval. A public GitHub release-asset check returned `302` to `release-assets.githubusercontent.com`, followed by `200`. GitHub also lists that exact host for release downloads in its [runner network reference](https://docs.github.com/en/actions/reference/runners/github-hosted-runners). The first published EventSales release must confirm this redirect host before promotion; unexpected hosts remain rejected.

Requests use WordPress's safe HTTP API, HTTPS, SSL verification, a five-second timeout per request, no cookies, no authorization, and the fixed User-Agent `EventSales-WordPress-Update-Discovery/1.0`. The release metadata response is limited to 256 KiB and the manifest response to 1 MiB. GitHub metadata and manifest bodies remain in memory only while being parsed. Diagnostics never store response bodies, headers, redirect URLs, or query strings.

## Cache and failure behavior

All four plugin checks share one WordPress site transient named `eventsales_wp_update_discovery_v1`, read and written with `get_site_transient()` and `set_site_transient()`.

```text
validated positive result: 12 hours
bounded negative result:   15 minutes
maximum redirect count:    3
HTTP timeout:              5 seconds per request
```

The cache stores only the validation category, checked time, suite release ID, release tag, WordPress/PHP floors, and validated plugin versions. A cache miss may make one release API request and one manifest request, plus at most three explicitly validated redirect requests. Later plugin-row evaluations reuse the same result. Failures receive the negative TTL and do not retry on each row.

Internal categories are bounded to `never_checked`, `current`, `update_available`, `wp_version_unsupported`, `remote_timeout`, `remote_http_error`, `release_missing`, `manifest_missing`, `manifest_invalid`, `tag_mismatch`, and `redirect_rejected`. A remote 404 for the latest-release endpoint maps to `release_missing`; other non-2xx responses map to `remote_http_error`.

## Manifest validation

The runtime validator will enforce the WP-SOURCE-05 release-manifest contract needed by discovery:

- `release_manifest_format_version` is the string `1`.
- `suite_release_id` matches `YYYY.MM.DD.N`, has a real calendar date, and uses a positive integer suffix.
- `suggested_tag` equals `eventsales-wp-` followed by that exact release ID, and the GitHub release tag equals `suggested_tag`.
- `source_commit` and `source_tree` are 40-character lowercase hexadecimal strings.
- `requires_wordpress` and `requires_php` are dotted numeric version strings.
- `plugins` contains exactly four entries, one for each canonical suite plugin.
- Each row has the canonical slug and main file, a valid dotted marketing version, and a 64-character lowercase hexadecimal `archive_sha256`. Duplicate or missing slugs fail validation.
- Catalog and order-index protocol fields keep their current names and dotted version shapes. JC-320 will not change their protocol versions.

The validator does not reproduce Git ancestry checks and does not claim to verify GitHub attestations. It ignores arbitrary URLs in all remote content.

## Version comparison and WordPress response

The owner uses `version_compare()` after validating both the installed and remote dotted versions:

- remote version greater than installed: report an update.
- equal or lower remote version: return no update.
- malformed installed or remote version: return no update.
- plugin absent from the exact suite mapping: return no update.

The update filter returns only `slug`, `version`, `url`, `requires_php`, and `autoupdate`. The details URL is constructed as `https://github.com/JCSchoeman96/EventSales/releases/tag/{validated_tag}`. It omits `package` and `tested`. `autoupdate` is always `false`. No response field comes from a remote URL.

## Site Health

Site Health reads only the current transient and local plugin headers. It reports whether the owner is active, whether native discovery is supported by the installed WordPress version, installed EventSales versions, the cached category and checked time, and cached release ID/versions when present. WordPress calls `wp_update_plugins()` while rendering the Site Health Info screen, so the owner also guards the `load-site-health.php` request and skips discovery during that request. Rendering either Site Health screen makes zero EventSales GitHub requests and performs no metadata refresh.

On WordPress 5.6 and 5.7, Site Health reports `wp_version_unsupported`; the updater does not register a compatibility fallback.

## Marketing versions

Adding the Update URI and discovery behavior changes each distributable plugin artifact, so all four marketing versions advance:

| Plugin slug | Current | JC-320 |
| --- | ---: | ---: |
| `eventsales-tickera-catalog-feed` | `0.1.1` | `0.1.2` |
| `eventsales-woo-order-index-feed` | `0.2.1` | `0.2.2` |
| `eventsales-woo-order-line-identity` | `0.1.1` | `0.1.2` |
| `eventsales-integration-health` | `0.1.1` | `0.1.2` |

The suite manifest and distribution assertions will match these versions. Existing transition fixtures that represent the prior release remain at their prior versions. Catalog, canonical contract, producer, delivery telemetry, and order-index schema versions remain unchanged.

## Focused verification

The deterministic PHP tests will cover WordPress 5.6/5.7/5.8 capability behavior, exact plugin identity, unrelated GitHub plugins, one shared metadata fetch across four plugin evaluations, version comparisons, every required release/manifest rejection case, timeouts and non-2xx responses, redirect host and hop limits, a response with no package and `autoupdate` false, and Site Health rendering with no HTTP calls.

Then run the WordPress distribution and release gates, `git diff --check`, `mix quality.fast`, and `bash scripts/local_ci.sh` as requested for JC-320. Any blocked database test will be reported with its exact error. This PR will not publish or promote a release candidate.

## After merge and future install work

After JC-320 merges, the release operator must run exact-head CI, merge the reviewed head, run the manual candidate workflow from `main` for the selected canonical-main source commit, verify artifact hashes and GitHub attestations, run transition preflight from the prior release, and then explicitly prepare and publish the release. The WP-SOURCE-05 attestation workflow must first run successfully from the default branch and its `actions/attest@v4` attestations must be checked before a candidate is promoted for installation.

WP-SOURCE-07 must make a separate decision before WordPress downloads any EventSales package. It must define package URL authority, manifest authenticity, SHA-256 binding, attestation/signature verification, upgrader interception, download integrity, rollback, and automatic-update policy. JC-320 does not pre-empt that decision.

## Official WordPress references

- [Plugin header requirements](https://developer.wordpress.org/plugins/plugin-basics/header-requirements/) document the `Update URI` header.
- [`update_plugins_{$hostname}`](https://developer.wordpress.org/reference/hooks/update_plugins_hostname/) documents the hostname-based callback, its four arguments, and its introduction in WordPress 5.8.
- [`wp_update_plugins()`](https://developer.wordpress.org/reference/functions/wp_update_plugins/) documents how WordPress applies the native host-specific filter while checking plugin updates.
- [`wp_safe_remote_get()`](https://developer.wordpress.org/reference/functions/wp_safe_remote_get/) documents WordPress HTTP API URL validation, including redirects. JC-320 disables automatic redirects and validates the manifest redirect targets itself.
