# WP-SOURCE-04 — WordPress plugin distribution and install certification

**Plan ID:** wp-plugin-distribution

**Plan version:** v1

**Status:** active

**Scope:** Reproducible ZIP packages, provenance, local install certification (JC-316)

**Authority:** This file is the active contract for WP-SOURCE-04.

**Last updated:** 2026-10-02

**Change summary (v1):** Initial distribution, provenance, and install certification contract.

### Revision log

- `v1` — plugin list, packaging rules, compatibility floor, reproducibility, and certification workflow locked.

## Goal

Turn the four EventSales WordPress integrations into git-ref–pinned installable ZIP artifacts with SHA-256 provenance, exclusion guarantees, and a documented local install/rollback path. Not production rollout, not an updater, not transport changes.

## Accepted base

- **Issue:** JC-316
- **Branch:** `parallel/wp-plugin-distribution-readiness`
- **Worktree:** `/home/jcschoeman96/projects/worktrees/EventSales-wp-plugin-distribution`
- **Base SHA:** `eebb9a83563e2ce0e40dd9a4e069567d89acd28f` (`origin/main` at worktree creation)
- **Base tree:** `489dc3843679d7477f706a5ab24de1b0310f8674`

## Plugin suite (four independent plugins)

| Slug | Main file | Marketing version |
|------|-----------|-------------------|
| `eventsales-tickera-catalog-feed` | `eventsales-tickera-catalog-feed/eventsales-tickera-catalog-feed.php` | `0.1.0` |
| `eventsales-woo-order-index-feed` | `eventsales-woo-order-index-feed/eventsales-woo-order-index-feed.php` | `0.2.0` |
| `eventsales-woo-order-line-identity` | `eventsales-woo-order-line-identity/eventsales-woo-order-line-identity.php` | `0.1.0` |
| `eventsales-integration-health` | `eventsales-integration-health/eventsales-integration-health.php` | `0.1.0` |

Canonical expected-source contract: `integrations/wordpress/eventsales-plugin-suite.json`.

## Locked public contract versions (must not change in this slice)

| Plugin | Field | Value |
|--------|-------|-------|
| Catalog | `catalog_schema_version` | `2026-08-07.v3` |
| Catalog | `canonical_contract_version` | `source_risk.v3` |
| Catalog | `producer_version` | `2026-08-07.1` |
| Catalog | `telemetry_version` | `2026-10-02.v1` |
| Order index | `order_index_schema_version` | `2026-08-12.v1` |

## Marketing version policy

Do not bump marketing versions for packaging-only changes. Header additions for `Requires PHP` / `Requires at least` document support floor without changing runtime behaviour; versions stay at the table above.

## PHP and WordPress requirement decision

**Decision B — uniform EventSales suite runtime floor** (one declared minimum for all four plugins).

| Requirement | Value | Evidence |
|-------------|-------|----------|
| **Requires PHP** | `8.0` | Production `eventsales-woo-order-index-manifest-store.php` uses `str_contains()`. Order-line identity and integration health use `declare(strict_types=1)` (compatible below 8.0 but suite aligns to the highest real floor). |
| **Requires at least** | `6.4` | REST routes under `eventsales/v1`, Site Health `site_status_tests` / `debug_information` filters, and WooCommerce integration patterns used by the suite match WordPress 6.4+ APIs exercised on local `http://localhost:10059`. |

**Not in this slice:** `Requires Plugins`, `Update URI`, WooCommerce/Tickera dependency headers.

## Package include / exclude rules

**Include** (per plugin tree at git path `integrations/wordpress/<slug>/`):

- `*.php` at plugin root
- `*.php` under `includes/` (integration health only)
- `README.md` at plugin root when present

**Exclude:**

- `tests/` and all test fixtures
- `.git/`, `.github/`, editor state, `.env*`, `wp-config.php`, dumps, coverage, `node_modules`, Elixir app source, repo-level docs

**Archive safety:** no `../`, no absolute paths, no Windows drive prefixes, no unexpected symlinks.

## Package provenance

Builder: `scripts/build_wordpress_plugins.sh --ref <git-ref>`.

1. Resolve `source_commit` and `source_tree` via `git rev-parse`.
2. If `source_commit` equals current `HEAD`, fail when any suite plugin path has staged/unstaged diffs vs `HEAD` or untracked files under those directories.
3. Materialise each plugin with `git archive` (bytes from the tree, not the working tree).
4. Emit four ZIPs and `manifest.json` + `SHA256SUMS` under `tmp/wordpress-plugin-dist/<commit>/`.

**Distribution format version:** `1`

## Archive naming

`<slug>-<marketing_version>.zip` (deterministic).

ZIP interior: exactly one root folder `<slug>/` with main file `<slug>/<slug>.php`.

## Reproducibility

| Claim | Value |
|-------|-------|
| `DETERMINISTIC_SOURCE_CONTENT` | **YES** — same commit yields same included relative paths and file bytes |
| `DETERMINISTIC_ARCHIVE_BYTES` | **NO** — ZIP stores platform-dependent metadata/timestamps; provenance uses per-archive SHA-256 |

Second builds into a separate output directory must match file sets and per-file digests when comparing extracted contents.

## Local installation guard

Script: `scripts/install_wordpress_plugins_local.sh` (optional certification, not part of default CI).

Requires `EVENTSALES_WP_ROOT` and `EVENTSALES_ALLOW_LOCAL_WP_PLUGIN_REPLACE=1`. WordPress `home` and `siteurl` must both be `http://localhost:10059` (trailing slash normalised). Installs from built ZIPs via WP-CLI.

## Activation order

No hard WordPress `Requires Plugins` between EventSales siblings. Recommended operational order:

1. EventSales Tickera Catalog Feed
2. EventSales Woo Order Index Feed
3. EventSales Woo Order Line Identity
4. EventSales Integration Health

Integration Health must remain able to report `ABSENT` / `INACTIVE` for siblings.

## Upgrade / replace behaviour

`wp plugin install <zip> --force` replaces plugin files only. Order-index custom tables and READY manifests must survive; activation remains additive/idempotent (no destructive schema rollback in this slice).

## Rollback

Restore prior ZIP artifacts and reinstall with `--force`. **Warning:** order-index plugin code rollback is not database rollback — do not drop manifest tables or mutate READY state.

## Site Health certification

After ZIP install/activate, exercise registered Site Health tests and debug section via WP-CLI/runtime. Configuration may legitimately show `DISABLED`, `MISCONFIGURED`, `DEPENDENCY_UNAVAILABLE`, or `READY`. Certification asks whether install and observability are truthful, not whether every feature is READY.

## Generated output location

```text
tmp/wordpress-plugin-dist/<source_commit>/
```

Ignored via repository `/tmp/` boundary. Never commit ZIPs or checksum files.

## Verification

- `scripts/verify_wordpress_plugin_packages.sh <dist-dir>`
- `integrations/wordpress/tests/plugin-distribution-test.php` (source + package assertions)

## Non-goals (WP-SOURCE-04)

Custom updater, GitHub release wiring, new REST routes, new live senders, compact order webhook, M5/analytics work.
