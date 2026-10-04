# WP-SOURCE-05 — WordPress release provenance and upgrade/rollback certification

**Plan ID:** wp-plugin-release-lifecycle

**Plan version:** v1

**Status:** active

**Scope:** Suite release identity, deterministic archive bytes, release candidates, attestations, transition preflight (JC-318)

**Authority:** This file is the active contract for WP-SOURCE-05. WP-SOURCE-04 (`docs/development/wp-plugin-distribution.plan.md`) remains authoritative for package contents, git-object guards, and distribution format; this plan extends it without weakening those checks.

**Last updated:** 2026-10-04

**Change summary (v1):** Initial release lifecycle, deterministic ZIP, candidate workflow, transition rules, deferred self-update boundary.

### Revision log

- `v1` — release candidate identity, deterministic archives, manifest schema, ancestry proof, attestation workflow, upgrade/rollback preflight, WP-SOURCE-06 decision record.

## Goal

Close the WP-SOURCE-04 gap (`DETERMINISTIC_ARCHIVE_BYTES = NO`) and add operator-safe release-candidate provenance, GitHub artifact attestations, and pure upgrade/rollback preflight. No production release, no self-updater, no plugin marketing version changes in this slice.

## Accepted base

- **Issue:** JC-318
- **Branch:** `parallel/wp-release-provenance`
- **Worktree:** `/home/jcschoeman96/projects/worktrees/EventSales-wp-release-provenance`
- **Base SHA:** `59e7dc2a9e0510ab902280050c39d8c6d83689bb` (`origin/main` at worktree creation)
- **Base tree:** `0c29ed1b582d6413e1de271e4eb97c291fbf1d35`

## Suite release identity (independent of plugin marketing versions)

| Field | Contract |
|-------|----------|
| `suite_release_id` | `YYYY.MM.DD.N` — four-digit year, month `01`–`12`, valid calendar day, `N` positive integer (no leading-zero requirement) |
| `suggested_tag` | `eventsales-wp-<suite_release_id>` (example for tests only: `eventsales-wp-2026.10.04.1`) |

Plugin header marketing versions stay independent. Creating a release candidate does not bump plugin versions.

## Git tag naming

Tags are **not** created in JC-318. Future promotion may apply `suggested_tag` to the exact `source_commit` recorded in `release-manifest.json`.

## Deterministic ZIP algorithm

Implemented in `scripts/lib/build_deterministic_wordpress_zip.py` and invoked from `scripts/build_wordpress_plugins.sh`:

- Members sorted lexicographically by archive path
- Fixed DOS date/time (1980-01-01)
- `ZIP_STORED` (no zlib/host compression variance)
- Unix `create_system`, external mode from git mode (`100644` → `0644`, `100755` → `0755`)
- UTF-8 paths, no absolute paths
- Does not use host filesystem mtimes

WP-SOURCE-04 git mode/type validation remains mandatory before archive generation.

## Distribution contract update (after tests)

| Claim | Value |
|-------|-------|
| `deterministic_source_content` | `true` |
| `deterministic_archive_bytes` | `true` |

## Release manifest schema (`release-manifest.json`)

Format version `1`. Safe fields only:

- `release_manifest_format_version`, `suite_release_id`, `suggested_tag`
- `source_commit`, `source_tree`, `canonical_main_at_build`
- `suite_manifest_git_path`, `distribution_format_version`
- `requires_wordpress`, `requires_php`
- `plugins[]`: slug, main_file, marketing_version, public contract fields, archive_filename, archive_sha256
- `deterministic_source_content`, `deterministic_archive_bytes`

No secrets, endpoints, credentials, or operator filesystem paths.

## Candidate source authority

- `source_commit`: 40-char lowercase hex commit
- Commit must exist; must **not** accept tree/blob objects
- Fetch canonical main with a full ref update (`git fetch origin +refs/heads/main:refs/remotes/origin/main`) — never `--depth=1` on the authority ref; fetch failure must abort (no stale fallback)
- `git merge-base --is-ancestor "$source_commit" refs/remotes/origin/main` after fetch
- `SOURCE_SHA == origin/main HEAD` is **not** required; ancestor of current `main` is sufficient
- Record `canonical_main_at_build` separately from `source_commit`

## Canonical-main reachability proof

Use real Git ancestry (`merge-base --is-ancestor`), not branch-name string checks. CI/candidate workflows use `fetch-depth: 0` or sufficient fetch before proof.

## Release checksums

`RELEASE_SHA256SUMS` covers exactly:

- all four plugin ZIPs
- `manifest.json`
- `release-manifest.json`

It does not include itself (no circular self-hash).

## Candidate output

```text
tmp/wordpress-plugin-release/<source_commit>/<suite_release_id>/
```

Generated assets remain ignored; never commit ZIPs or one-off candidate manifests.

## Candidate retention / promotion

Promote the **exact attested candidate bytes** (or rebuild and require byte-identical SHA-256 match against the reviewed `release-manifest.json` before publication). Never publish assets whose hashes differ from the reviewed candidate.

Do not instruct operators to “re-run the builder when ready to publish” without a deterministic-byte or hash-match gate.

## GitHub artifact attestation

Manual workflow `wordpress-plugin-release-candidate.yml`:

- `permissions`: `contents: read`, `id-token: write`, `attestations: write` (intentionally **no** `contents: write`)
- Attest candidate bytes only: four ZIPs, `manifest.json`, `release-manifest.json`, checksum files
- Do not create/move tags or GitHub Releases in this slice

Operators verify with `gh attestation verify` against this repository.

## Immutable GitHub releases

JC-318 does not enable repository settings. Before production publication, a repository administrator should confirm whether **immutable releases** are enabled. When enabled: draft → attach exact reviewed assets → verify → publish.

## Upgrade preflight (`check_wordpress_plugin_release_transition.sh --mode upgrade`)

- Same four canonical slugs
- Target marketing version ≥ source for every plugin; at least one strict increase
- Valid manifest structure and SHA-256 fields
- **Fail:** same marketing version + different `archive_sha256`
- **Fail:** same marketing version + different public contract fields
- On version increase, **report** (not auto-approve) changes to catalog/order-index contract fields and runtime floors

## Rollback preflight (`--mode rollback`)

- Same slugs; target ≤ source; at least one strict decrease
- **Fail:** same version + different archive SHA
- Code rollback only — not database downgrade
- **Fail:** order-index `order_index_schema_version` mismatch (until explicit backward-compatibility metadata exists in a future slice)
- **Fail:** catalogue schema/contract/producer identity change without explicit review policy

Never DROP/TRUNCATE tables or mutate READY manifests from this tooling.

## Future self-update boundary (WP-SOURCE-06 — not implemented)

WordPress-native third-party update APIs (`Update URI`, `update_plugins_{$hostname}`) require WordPress **5.8+**. The suite floor stays **5.6** for JC-318; do not ship a self-updater or raise the floor merely to enable updates.

WP-SOURCE-06 must explicitly decide:

- Whether to raise WordPress minimum to ≥ 5.8
- Update URI origin/hostname
- Release metadata source and runtime authentication
- Package SHA/signature verification before install
- Auto-update vs manual-only
- Failure and rollback behaviour

WP-SOURCE-05 must not pre-decide these via updater code.

## Local upgrade certification

Optional when `EVENTSALES_WP_ROOT` points at `http://localhost:10059` (`home` and `siteurl`). Not required for slice completion if unavailable.

## Success criteria

- Deterministic archive bytes proven by dual independent builds
- Release candidate builder + verifier + transition checker with automated tests
- Manual attestation workflow defined (no production release)
- WP-SOURCE-04 guards unchanged
- No runtime plugin PHP or marketing version changes
