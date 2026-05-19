# Quality Gates

Slice `0.2` established the Postgres-backed test baseline required for `EventSales.Repo` and Oban to start in `:test`. Slice `0.4` keeps those guardrails and adds the Ash ecosystem proof surface under `EventSales.AshBaseline`.

## Local Commands

- `mix quality.fast`
  - Quick local/pre-commit guard only; not sufficient before opening a PR
  - Runs `mix format --check-formatted`
  - Runs `mix compile --warnings-as-errors`
  - Verifies `mix.lock` has no unused dependencies with `mix deps.unlock --check-unused`
  - Runs `./scripts/check_no_web_woocommerce_refs.sh`
- `mix quality.pr`
  - Minimum gate before opening or updating a meaningful PR
  - Runs `mix format --check-formatted`
  - Runs `mix compile --warnings-as-errors`
  - Verifies `mix.lock` has no unused dependencies with `mix deps.unlock --check-unused`
  - Runs `./scripts/check_no_web_woocommerce_refs.sh`
  - Runs `mix ash.codegen --dry-run`
  - Verifies Ash-generated migrations and resource snapshots are unchanged
  - Runs `mix credo --strict`
  - Runs `mix test`
- `mix quality`
  - Runs `mix quality.fast`
  - Runs `mix credo --strict`
  - Runs `mix sobelow`
- `mix quality.ci`
  - Final CI-equivalent gate before marking a PR ready for review or pre-merge
  - Runs `mix deps.get --check-locked`
  - Runs `mix format --check-formatted`
  - Runs `mix compile --warnings-as-errors`
  - Verifies `mix.lock` has no unused dependencies with `mix deps.unlock --check-unused`
  - Runs `./scripts/check_no_web_woocommerce_refs.sh`
  - Runs `mix ash.codegen --dry-run`
  - Verifies Ash-generated migrations and resource snapshots are unchanged
  - Runs `mix credo --strict`
  - Runs `mix sobelow`
  - Runs `mix deps.audit`
  - Runs `mix hex.audit` in a fresh Mix invocation
  - Runs `mix test`
  - Runs `mix dialyzer`

### Local full PR gate (`scripts/local_ci.sh`)

Run before pushing a meaningful PR update so GitHub CI confirms success instead of discovering failures after a cold start.

```bash
bash scripts/local_ci.sh
```

The script runs these steps in order:

1. `git diff --check`
2. `mix format --check-formatted`
3. `mix compile --warnings-as-errors`
4. `bash scripts/check_no_web_woocommerce_refs.sh`
5. `MIX_ENV=test mix ash.codegen --dry-run`
6. `git diff --exit-code priv/repo/migrations priv/resource_snapshots`
7. `mix quality.pr`
8. `mix dialyzer`

**When to use it:** before opening or updating a meaningful PR on GitHub.

**When not to use it:** during active coding. Prefer `mix quality.fast` and focused `mix test path/to/relevant_test.exs` for quick feedback.

**What it covers:** the core GitHub jobs `format_compile`, `test`, `ash_codegen`, and `dialyzer`. It does not run Sobelow, `mix deps.audit`, or `mix hex.audit` (those are in `mix quality.ci` and the CI `lint_security` job).

**Still required before merge-ready:** `mix quality.ci` (full local CI parity). The pre-push hook runs `mix quality.ci` when repo hooks are installed.

Steps 2–6 partially overlap with step 7 (`mix quality.pr`) so failures surface with clear section labels before the full PR alias runs.

Postgres must be reachable for Ash codegen, tests, and Dialyzer. Start local Postgres with `bash scripts/dev_postgres.sh start` when needed.

## Slice 0.4 Ash Baseline Checks

Slice `0.4` adds proof-only Ash verification on top of the existing local commands:

- `MIX_ENV=test mix ash.codegen --dry-run`
  - Confirms the Ash/AshPostgres proof resources and snapshots are in sync
  - Is required as part of Slice `0.4` verification
  - Is enforced by `mix quality.ci`
  - Is enforced in the CI test job after `mix ecto.migrate`
  - Is also enforced by the dedicated CI `ash_codegen` job for a clear GitHub status signal
- `git diff --exit-code priv/repo/migrations priv/resource_snapshots`
  - Confirms Ash-related checks did not leave generated migrations or resource snapshots unstaged
  - Is enforced by `mix quality.ci`
  - Is enforced after Ash dry-run in both the CI `test` and `ash_codegen` jobs
- Focused proof tests:
  - `mix test test/event_sales/ash_baseline/auth_user_support_test.exs`
  - `mix test test/event_sales/ash_baseline/state_machine_proof_test.exs`
  - `mix test test/event_sales/ash_baseline/paper_trail_proof_test.exs`
  - `mix test test/event_sales_web/ash_admin_access_test.exs`
  - `mix test test/event_sales/ash_resource_smoke_test.exs`

These checks prove ecosystem readiness only. They do not mean the real Accounts, Catalog, Sales, Ingestion, or Audit resources have shipped.

Because the app now starts `EventSales.Repo` and Oban in `:test`, any command that runs `mix test`, `mix ash.codegen --dry-run`, or a test-only smoke check requires a reachable Postgres instance.

`mix sobelow` currently runs without a custom Sobelow config file. Add a config later only if the project needs one.

`mix dialyzer` is pinned to `MIX_ENV=test` via `preferred_envs`, so its PLTs live under the test build path in `_build/`. The first run may take longer because it needs to build PLTs.

## Unused Dependency Check

The current Mix toolchain supports `mix deps.unlock --check-unused`, so Slice 0.1 uses that directly in local aliases and CI.

If the project later runs on a Mix version that does not support `--check-unused`, use this fallback instead:

```bash
mix deps.unlock --unused
git diff --exit-code mix.lock
```

That fallback keeps CI from silently mutating `mix.lock`.

## Web-Layer Boundary Check

`./scripts/check_no_web_woocommerce_refs.sh` scans:

- `lib/event_sales_web/`
- `lib/event_sales/catalog/mapping_resolver.ex`

It fails on these forbidden call-path indicators:

- `WooCommerceClient`
- `Req.`
- `Tesla.`
- `Finch.`
- `HTTPoison.`
- `/wp-json/wc/`

It does not call the network, and it does not block normal webhook receipt or signature-verification wording.

## Git Hooks

Install the repo-local hooks with:

```bash
./scripts/install_git_hooks.sh
```

Hook behavior:

- Pre-commit runs `mix quality.fast`
- Pre-push runs `mix quality.ci`

PR behavior:

- Do not push a meaningful PR update until `bash scripts/local_ci.sh` passes.
- Do not open or update a meaningful PR until `mix quality.pr` passes (included in `local_ci.sh`).
- Do not mark a PR ready for review until `mix quality.ci` passes.
- Do not claim “all checks pass” unless Credo ran explicitly or through `mix quality`, `mix quality.pr`, or `mix quality.ci`.

The installer sets `core.hooksPath` for this repository only.
Because Git worktrees share repository config, that repository-level hooks path also applies to sibling worktrees for the same repo.

## CI Jobs

`/.github/workflows/ci.yml` runs on pull requests to `main` and pushes to `main`.

Jobs:

- `format_compile`
  - Checks formatting
  - Compiles with warnings as errors
  - Verifies no unused locked dependencies
  - Enforces the WooCommerce web-layer boundary script
- `lint_security`
  - Runs Credo
  - Runs Sobelow
  - Runs `mix deps.audit`
  - Runs `mix hex.audit`
- `test`
  - Starts a Postgres service
  - Runs `mix ecto.create`
  - Runs `mix ecto.migrate`
  - Runs `mix ash.codegen --dry-run`
  - Verifies `priv/repo/migrations` and `priv/resource_snapshots` are unchanged
  - Runs the current ExUnit suite
- `ash_codegen`
  - Starts a Postgres service
  - Runs `mix ecto.create`
  - Runs `mix ecto.migrate`
  - Runs `mix ash.codegen --dry-run`
  - Verifies `priv/repo/migrations` and `priv/resource_snapshots` are unchanged
  - Exists so Ash drift reports as an explicit GitHub job failure instead of only a general test failure
- `dialyzer`
  - Runs Dialyzer under `MIX_ENV=test`

## Beam Version Source Of Truth

This repository does not currently include `.tool-versions` or `mise.toml`.

Until one of those files exists, CI is pinned to:

- Elixir `1.19.3`
- OTP `28`

If a version file is added later, treat that file as the CI source of truth and update the workflow to match it.

## Deferred Checks

These are intentionally deferred to later slices:

- broad Ash checks in every CI job
- Redis-backed CI services
- coverage thresholds
- business-logic checks outside the current scaffold baseline

Slice `0.4` does not add Redis to CI, does not add PgBouncer to CI, and does not add broad Ash policy gates beyond the proof-specific checks above.

## Emergency Bypass

Emergency-only bypasses exist, but they should be rare and explained in the PR:

- `git commit --no-verify`
- `git push --no-verify`

Use them only when the hook itself is the problem, not to skip a real failure.
