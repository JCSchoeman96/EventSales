# WordPress plugin distribution (WP-SOURCE-04)

Operational runbook for building, verifying, installing, and rolling back the four EventSales WordPress plugin ZIP artifacts.

## Plugins

| Plugin | Slug | Marketing version |
|--------|------|-------------------|
| EventSales Tickera Catalog Feed | `eventsales-tickera-catalog-feed` | `0.1.1` |
| EventSales Woo Order Index Feed | `eventsales-woo-order-index-feed` | `0.2.1` |
| EventSales Woo Order Line Identity | `eventsales-woo-order-line-identity` | `0.1.1` |
| EventSales Integration Health | `eventsales-integration-health` | `0.1.1` |

Expected-source contract: `integrations/wordpress/eventsales-plugin-suite.json`.

## Build

From a clean git tree at the intended release commit:

```bash
bash scripts/build_wordpress_plugins.sh --ref HEAD
```

Output directory:

```text
tmp/wordpress-plugin-dist/<source_commit>/
```

Artifacts:

- four `<slug>-<version>.zip` files
- `manifest.json` (commit, tree, per-plugin SHA-256)
- `SHA256SUMS`

The builder refuses `--ref HEAD` when the suite manifest or plugin paths have staged, unstaged, or untracked changes. Archives materialise allowed paths from the resolved commit using `git ls-tree` (mode/type validation), rejecting symlinks and gitlinks, then `git show` for file bytes.

## Verify

```bash
bash scripts/verify_wordpress_plugin_packages.sh tmp/wordpress-plugin-dist/<source_commit>
```

This runs `integrations/wordpress/tests/plugin-distribution-test.php` and `php -l` on every packaged PHP file.

## Inspect provenance

```bash
cat tmp/wordpress-plugin-dist/<source_commit>/manifest.json
sha256sum -c tmp/wordpress-plugin-dist/<source_commit>/SHA256SUMS
unzip -l tmp/wordpress-plugin-dist/<source_commit>/eventsales-tickera-catalog-feed-0.1.1.zip
```

## Local install (certification only)

Requires WP-CLI and the locked local WordPress site (`http://localhost:10059`).

```bash
export EVENTSALES_WP_ROOT=/path/to/wordpress
export EVENTSALES_ALLOW_LOCAL_WP_PLUGIN_REPLACE=1
bash scripts/install_wordpress_plugins_local.sh tmp/wordpress-plugin-dist/<source_commit>
```

The script reads `home` and `siteurl` from WordPress before replacing plugins. It installs from ZIP archives, not symlinks.

### Activation order

1. EventSales Tickera Catalog Feed
2. EventSales Woo Order Index Feed
3. EventSales Woo Order Line Identity
4. EventSales Integration Health

## Site Health

After install, confirm Site Health registers EventSales direct tests and the **EventSales integrations** debug section. States may legitimately be `DISABLED`, `MISCONFIGURED`, `DEPENDENCY_UNAVAILABLE`, or `READY` depending on local configuration.

## Rollback

1. Build or locate a prior distribution directory with known `manifest.json`.
2. Re-run `install_wordpress_plugins_local.sh` against that directory (or `wp plugin install <zip> --force` per plugin).

**Order index warning:** rolling back plugin PHP does **not** roll back database schema or READY manifests. Do not drop manifest tables, truncate them, or destructively downgrade schema. Plugin code rollback and data rollback are separate operations.

## Reproducibility

Same git commit yields the same included source files and bytes (`DETERMINISTIC_SOURCE_CONTENT=YES`). ZIP file digests may differ between builds (`DETERMINISTIC_ARCHIVE_BYTES=NO`); compare `manifest.json` archive SHA-256 for a specific build output.

## Not in this slice

Automatic updates, `Update URI`, custom release feeds, and production rollout belong to WP-SOURCE-05 and WP-SOURCE-06.
