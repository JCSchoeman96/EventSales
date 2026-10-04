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

## Prepare draft GitHub Release (future operator action)

JC-318 does **not** publish releases. When promoting:

1. Repository administrator confirms whether **immutable releases** are enabled for this repo.
2. Create a **draft** release (no tag move in automation).
3. Attach the **exact** candidate bytes (or bytes with identical SHA-256 to the reviewed manifest).
4. Verify attached asset hashes against `release-manifest.json` and `RELEASE_SHA256SUMS`.
5. Publish only after review.

Promotion policy: use the attested candidate artifact bytes, or rebuild and require a byte-identical SHA-256 match before publish. Never publish assets that disagree with the reviewed candidate manifest.

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

## Not in this slice

- GitHub Release publication, tag creation, or `Update URI` self-updates (WP-SOURCE-06)
- Production WordPress rollout
- Database downgrade migrations

## CI vs manual candidate workflow

| Gate | Purpose |
|------|---------|
| PR `wordpress_plugin_distribution` job | WP-SOURCE-04 + WP-SOURCE-05 tests; never publishes |
| Manual `wordpress-plugin-release-candidate.yml` | Builds candidate, uploads artifact, writes attestations |
