# WordPress plugin release lifecycle (WP-SOURCE-05)

Operational runbook for release candidates, verification, attestation, promotion, install, and code rollback. Package contents and git-object rules remain defined in [wordpress-plugin-distribution.md](./wordpress-plugin-distribution.md) (WP-SOURCE-04).

Plan authority: [wp-plugin-release-lifecycle.plan.md](../development/wp-plugin-release-lifecycle.plan.md).

## Suite release identity

- `suite_release_id`: `YYYY.MM.DD.N` (example used in tests: `2026.10.04.1`)
- Suggested tag (not created automatically): `eventsales-wp-<suite_release_id>`
- Plugin marketing versions in ZIP filenames stay independent of the suite release id.

## Create a release candidate (local)

Pick a `source_commit` that is on `origin/main` history (need not be current `main` HEAD):

```bash
git fetch origin main
git merge-base --is-ancestor <source_commit> origin/main

bash scripts/build_wordpress_plugin_release_candidate.sh \
  --ref <40-char-source-sha> \
  --release-id 2026.10.04.1
```

Output:

```text
tmp/wordpress-plugin-release/<source_commit>/<suite_release_id>/
```

Artifacts: four ZIPs, `manifest.json`, `SHA256SUMS`, `release-manifest.json`, `RELEASE_SHA256SUMS`.

## Inspect candidate manifest

```bash
CANDIDATE=tmp/wordpress-plugin-release/<source_commit>/<suite_release_id>
cat "$CANDIDATE/release-manifest.json"
cat "$CANDIDATE/RELEASE_SHA256SUMS"
```

Confirm `source_commit`, `canonical_main_at_build`, per-plugin `archive_sha256`, and runtime floors (`requires_wordpress`, `requires_php`).

## Verify SHA-256

```bash
bash scripts/verify_wordpress_plugin_release_candidate.sh "$CANDIDATE"
```

This re-runs WP-SOURCE-04 package tests, validates ancestry, and checks `RELEASE_SHA256SUMS`.

## Verify GitHub attestation (after manual workflow)

Run the **WordPress plugin release candidate** GitHub Actions workflow (`workflow_dispatch`) with `source_sha` and `suite_release_id`. Download the uploaded artifact and compare hashes to your reviewed `release-manifest.json`.

Verify attestations against this repository:

```bash
gh attestation verify <path-to-candidate-file> --repo JCSchoeman96/EventSales
```

(Adjust owner/repo if forked.)

## Verify a published release (WP-SOURCE-07)

The published-release verifier is read-only. It requires a public, immutable release and checks its tag, GitHub source binding, exact asset set, asset digests, and checksum authority. Supplying the downloaded candidate directory also requires every release asset to match the exact candidate bytes.

```bash
bash scripts/verify_wordpress_plugin_published_release.sh \
  --tag eventsales-wp-<suite_release_id> \
  --candidate tmp/wordpress-plugin-first-release-certification/<suite_release_id>
```

The verifier uses public GitHub API requests without a token. It caps API JSON at 2 MiB and each release asset at 16 MiB. It disables curl's default config so a local `.curlrc` cannot enable automatic redirects. It downloads assets by validated release asset IDs and checks each redirect before following it. It allows only HTTPS redirects to `release-assets.githubusercontent.com`, with at most three redirects. It does not use release-provided download URLs, print signed query strings, or create or change GitHub resources.

The release must include exactly these assets, with each GitHub `sha256:` digest matching the downloaded bytes:

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

The verifier requires the tag to resolve to `release-manifest.source_commit`, the source tree to match `release-manifest.source_tree`, and the source commit and recorded build commit to be on current canonical-main history. It rejects missing digests, extra or duplicate assets, malformed manifests, and releases without `immutable: true`.

## First release state

At the start of JC-322, EventSales had no GitHub Releases or `eventsales-wp-*` tags. The first suite ID is selected only after checking live releases, tags, and candidate runs. Do not invent a prior release manifest. Earlier source-built packages may be used only as a `PRE_RELEASE_SOURCE_BASELINE`.

The repository's immutable-release setting must be checked before any publication. JC-322 found immutable releases disabled and not owner-enforced. Do not change that setting as part of candidate verification. Do not create a draft, tag, or public release without explicit operator authorization. Public publication also requires immutable-release protection to be enabled.

## Confirm source commit on main

```bash
git fetch origin main
git merge-base --is-ancestor <source_commit> origin/main && echo OK
```

## Review transition from previous release

```bash
bash scripts/check_wordpress_plugin_release_transition.sh \
  --mode upgrade \
  --from path/to/previous/release-manifest.json \
  --to "$CANDIDATE/release-manifest.json"

bash scripts/check_wordpress_plugin_release_transition.sh \
  --mode rollback \
  --from "$CANDIDATE/release-manifest.json" \
  --to path/to/previous/release-manifest.json
```

Upgrade mode reports public contract field changes for human review. Rollback mode fails closed on order-index schema mismatch.

## Prepare a GitHub Release (operator action only)

The candidate workflow does not publish releases. For a future promotion:

1. A repository administrator confirms immutable releases are enabled.
2. An operator obtains explicit authorization before creating a draft or tag.
3. Attach the **exact** candidate bytes. Do not rebuild or substitute assets.
4. Verify every attached asset digest against the candidate and checksum authority.
5. Publish only after the published-release verifier and independent review pass.

Promotion policy: use the attested candidate artifact bytes, or rebuild and require a byte-identical SHA-256 match before publication. Never publish assets that disagree with the reviewed candidate manifest.

For the first release, prepare concise notes that identify the suite as the first EventSales WordPress release and describe the catalogue feed, historical order index, order-line identity, Integration Health, delivery telemetry, and read-only update discovery. State WordPress 5.6 and PHP 8.0 minimums, and that native update discovery requires WordPress 5.8. Discovery is notification-only. It provides no package URL and does not enable automatic updates.

## Install / upgrade locally (certification)

Same guards as WP-SOURCE-04:

```bash
export EVENTSALES_WP_ROOT=/path/to/wordpress
export EVENTSALES_ALLOW_LOCAL_WP_PLUGIN_REPLACE=1
bash scripts/install_wordpress_plugins_local.sh "$CANDIDATE"
```

Requires `home` and `siteurl` of `http://localhost:10059`. Install prior package set first when certifying an upgrade path.

## Rollback preflight and code rollback

1. Run `--mode rollback` transition check from current manifest to target older manifest.
2. If preflight passes, reinstall older ZIPs with `install_wordpress_plugins_local.sh` or `wp plugin install <zip> --force`.

**Order index:** code rollback does not revert database schema or READY manifests. Do not drop or truncate manifest tables.

## Reproducibility

Same `source_commit`, tree, and suite manifest yield byte-identical ZIPs (`deterministic_archive_bytes=true`). Dual-build check:

```bash
bash scripts/check_wordpress_plugin_distribution_reproducibility.sh --ref <source_commit>
```

## Not in the release verification tooling

- GitHub Release publication and tag creation, which remain operator actions
- WordPress package downloads or self-updates (WP-SOURCE-08)
- Production WordPress rollout
- Database downgrade migrations

## CI vs manual candidate workflow

| Gate | Purpose |
|------|---------|
| PR `wordpress_plugin_distribution` job | WP-SOURCE-04 + WP-SOURCE-05 tests; never publishes |
| Manual `wordpress-plugin-release-candidate.yml` | Builds candidate, uploads artifact, writes attestations |
