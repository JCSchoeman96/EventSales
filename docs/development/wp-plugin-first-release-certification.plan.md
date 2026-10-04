# WP-SOURCE-07 first release promotion and local upgrade certification

**Plan ID:** `wp-plugin-first-release-certification`
**Plan version:** v1
**Issue:** JC-322
**Status:** Implementation in progress; public promotion is blocked on immutable-release policy and operator authorization
**Last updated:** 2026-10-04

## Goal

Certify the path from canonical-main source through the attested candidate, immutable GitHub release, localhost installation, and WP-SOURCE-06 update discovery. This plan does not authorize a release publication or let WordPress download plugin packages.

## Accepted source and candidate

`origin/main` is the source authority at execution time. The first candidate uses the current canonical-main commit that contains JC-320. If `main` moves before a future candidate run, record the selected full source SHA and the reason for using it.

Select a suite release ID only after checking all three live sources: `eventsales-wp-*` tags, GitHub Releases, and prior candidate workflow runs. Local test fixtures do not reserve an ID.

### Certification record

| Field | Result |
| --- | --- |
| Branch | `t3code/wp-first-release-certification` |
| Worktree | `t3code-994111c4` |
| Base commit | `f55ea2632ca9480412be4b086af1bd26b9b9889c` |
| Base tree | `52bbe026bf6d7d975ac6bf0dc03109b7ca3ecc9b` |
| Current canonical main at candidate dispatch | `f55ea2632ca9480412be4b086af1bd26b9b9889c` |
| Candidate source commit | `f55ea2632ca9480412be4b086af1bd26b9b9889c` |
| Candidate source tree | `52bbe026bf6d7d975ac6bf0dc03109b7ca3ecc9b` |
| Suite release ID | `2026.10.04.1` |
| Suggested tag | `eventsales-wp-2026.10.04.1` |
| Candidate workflow | [Run 37225489789](https://github.com/JCSchoeman96/EventSales/actions/runs/37225489789), success |
| Candidate artifact | ID `11311443229`, `wordpress-plugin-release-candidate` |
| Artifact archive digest | `sha256:cc5068e06cc1a404c2cdc88ca45f76cbee673de11e232d0eecf45591ade80371` |
| Artifact archive digest check | Downloaded archive SHA-256 matched the GitHub artifact digest |
| Repository release count at certification | `0` |
| EventSales tag count at certification | `0` |

The candidate verifier passed. GitHub attestation verification passed for each of the eight uploaded subjects.

| Candidate subject | SHA-256 |
| --- | --- |
| `eventsales-tickera-catalog-feed-0.1.2.zip` | `2bcc419e83116d433dc528c87b27fd698d8ec00722f7edd4e4af53b990faab10` |
| `eventsales-woo-order-index-feed-0.2.2.zip` | `b7a15a88cf0a3584c40bccf1c34a66e9394ce937abe15b5a2c0b54106bdfd10a` |
| `eventsales-woo-order-line-identity-0.1.2.zip` | `e245598bafac3287eecb19d46251153206e0b6e46d4357cf14b7724a14ca3849` |
| `eventsales-integration-health-0.1.2.zip` | `30fc4641fbd386966107572adb314d06219b84e73e9cf1cda3ff89ee08f151d4` |
| `manifest.json` | `7c59001d609a9c014500936d05bfb861e2c143f06b6c75facdbc3d70e1f37cd7` |
| `SHA256SUMS` | `d954139bdbb31353294dff31ae9a5076589ead445a4a494d6e4ee70beb6f64c4` |
| `release-manifest.json` | `8e1ee75055332dc539ce8966aa30688e6fd8d74bcae64e4fecd89b1d7f1a7292` |
| `RELEASE_SHA256SUMS` | `99502138955293b7604993da6dd5e1958e159313bb9822b1450846c431d235ac` |

## Candidate requirements

The candidate workflow must run from canonical `main` and succeed. Download the exact workflow artifact. Do not rebuild or substitute its bytes.

Run `scripts/verify_wordpress_plugin_release_candidate.sh` on the downloaded candidate. Verify GitHub attestations with `gh attestation verify <subject> --repo JCSchoeman96/EventSales` for all four ZIPs, both manifests, and both checksum files. Keep the verification result, not the full attestation bundles.

The candidate is promotable only when the source commit is on canonical-main history, the candidate verifier passes, the checksum authority agrees with every candidate file, and every required attestation verifies.

## Published release contract

The published release must meet all of these checks before it can be called certified:

- Repository is `JCSchoeman96/EventSales`.
- `draft` and `prerelease` are both false, and GitHub reports `immutable: true`.
- Release tag equals `release-manifest.suggested_tag` and `eventsales-wp-<suite_release_id>`.
- The tag resolves to `release-manifest.source_commit`.
- The source commit is on canonical `main` history, and its GitHub tree matches `release-manifest.source_tree`.
- The release contains exactly the eight assets below, each once.
- Each GitHub asset SHA-256 digest matches the downloaded bytes. Plugin ZIP hashes also match both manifests and the checksum files.
- When a candidate directory is supplied, every published asset matches the exact attested candidate bytes.

The read-only verifier is:

```bash
bash scripts/verify_wordpress_plugin_published_release.sh \
  --tag eventsales-wp-2026.10.04.1 \
  --candidate tmp/wordpress-plugin-first-release-certification/2026.10.04.1
```

It uses unauthenticated public GitHub API requests, constructs asset API paths from validated numeric IDs, follows no more than three redirects, and accepts only HTTPS redirects to the exact host `release-assets.githubusercontent.com`. It does not read or print `browser_download_url` values, credentials, or signed query strings. It creates no GitHub objects and does not change repository settings.

The release asset set is:

```text
eventsales-tickera-catalog-feed-0.1.2.zip
eventsales-woo-order-index-feed-0.2.2.zip
eventsales-woo-order-line-identity-0.1.2.zip
eventsales-integration-health-0.1.2.zip
manifest.json
SHA256SUMS
release-manifest.json
RELEASE_SHA256SUMS
```

GitHub-generated source archives are not plugin assets. A filename match alone is not integrity proof.

## First-release and transition rules

`FIRST_RELEASE=true` while the repository has no published EventSales release. Do not create a fictional prior release manifest. There is no release-to-release upgrade or rollback transition to validate yet.

The available earlier source-package versions are a `PRE_RELEASE_SOURCE_BASELINE`, not a previous release:

```text
catalog feed          0.1.1
order index           0.2.1
order-line identity   0.1.1
Integration Health    0.1.1
```

If those exact packages are used for a local upgrade exercise, preserve that label. Never downgrade the order-index database, drop or truncate its tables, or mutate READY manifests during plugin replacement or rollback.

## Local WordPress certification

Before an install, identify a WordPress root with WP-CLI and require both `home` and `siteurl` to equal `http://localhost:10059`, allowing a trailing slash. Confirm that the candidate site's database is local before querying it. Before replacement, set `EVENTSALES_WP_ROOT` and `EVENTSALES_ALLOW_LOCAL_WP_PLUGIN_REPLACE=1` and use `scripts/install_wordpress_plugins_local.sh` with the exact candidate ZIPs.

Current discovery result:

| Check | Result |
| --- | --- |
| `http://localhost:10059` HTTP status | `200` |
| WP-CLI installed | Yes |
| Safe Local WordPress roots checked | `12` |
| Successful `wp option get home/siteurl` queries | `0` |
| Root with both URLs equal to `http://localhost:10059` | None proven |
| Plugin install or replacement | Not run |
| Local first-install/upgrade result | Blocked until a working root/database connection is available |
| Site Health UI proof | Deferred |

An example local `wp option get home` command failed with `Error establishing a database connection.` No candidate root was accepted and no WordPress files or data were changed.

## Post-publication checks

Only after an authorized, immutable public release exists:

1. Verify the release with the published-release verifier and record the asset redirect chain. If GitHub uses a host outside the current WP-SOURCE-06 allowlist, stop and review the source contract.
2. On the verified localhost site, clear only `eventsales_wp_update_discovery_v1` and trigger normal update checking.
3. Confirm the release manifest and tag are accepted through the shared discovery cache.
4. Confirm an installed-current site reports `current`; if testing an older package, confirm `update_available` while the response still omits `package` and sets `autoupdate` to false.
5. Do not let WordPress download any package.

Both live checks remain `WAITING_FOR_AUTHORIZED_PUBLIC_RELEASE`.

## Promotion boundary

The proposed title is `EventSales WordPress suite 2026.10.04.1`. The release notes must identify the first EventSales WordPress suite release, list the catalogue feed, historical order index, order-line identity, Integration Health, delivery telemetry, and read-only update discovery, and state the WordPress 5.6 and PHP 8.0 floors. They must state that native update discovery requires WordPress 5.8 and only notifies administrators. There is no package URL or automatic update support.

Prepared release notes:

```text
First EventSales WordPress suite release.

Includes the Tickera catalogue feed, historical WooCommerce order index, WooCommerce order-line identity, Integration Health, catalogue delivery telemetry, and read-only update discovery.

Requires WordPress 5.6 or newer and PHP 8.0 or newer. Native update discovery requires WordPress 5.8 or newer. It only notifies administrators. This release does not provide a plugin package URL or automatic updates.
```

The repository currently reports immutable releases disabled and not owner-enforced. Do not enable or disable that setting in this task. Do not create a draft release, tag, or public release. Public promotion requires immutable-release policy to be enabled by an authorized operator and separate explicit authorization to publish the first release.

## Runtime and marketing versions

No runtime plugin PHP files or plugin marketing versions change in WP-SOURCE-07. The certified suite remains catalog `0.1.2`, order index `0.2.2`, order-line identity `0.1.2`, and Integration Health `0.1.2`.

## GitHub references

- [Immutable releases](https://docs.github.com/en/code-security/concepts/supply-chain-security/immutable-releases)
- [REST API release metadata](https://docs.github.com/en/rest/releases/releases?apiVersion=latest)
- [REST API release assets](https://docs.github.com/en/rest/releases/assets)
- [`gh attestation verify`](https://cli.github.com/manual/gh_attestation_verify)
