# Quality Gates

Slice 0.1 adds the first local and CI guardrails for EventSales. These checks are intentionally limited to the current Phoenix scaffold and do not pull future-slice Ash, Oban, Redis, or service-backed checks forward.

## Local Commands

- `mix quality.fast`
  - Runs `mix format --check-formatted`
  - Runs `mix compile --warnings-as-errors`
  - Verifies `mix.lock` has no unused dependencies with `mix deps.unlock --check-unused`
  - Runs `./scripts/check_no_web_woocommerce_refs.sh`
- `mix quality`
  - Runs `mix quality.fast`
  - Runs `mix credo --strict`
  - Runs `mix sobelow`
- `mix quality.ci`
  - Runs `mix deps.get --check-locked`
  - Runs `mix format --check-formatted`
  - Runs `mix compile --warnings-as-errors`
  - Verifies `mix.lock` has no unused dependencies with `mix deps.unlock --check-unused`
  - Runs `./scripts/check_no_web_woocommerce_refs.sh`
  - Runs `mix credo --strict`
  - Runs `mix sobelow`
  - Runs `mix deps.audit`
  - Runs `mix hex.audit` in a fresh Mix invocation
  - Runs `mix test`
  - Runs `mix dialyzer`

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
  - Runs the current ExUnit suite
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

- Ash-specific checks
- Ash, Oban, or Redis dependencies
- Database-backed or Redis-backed CI services
- Coverage thresholds
- Business-logic checks outside the current scaffold baseline

## Emergency Bypass

Emergency-only bypasses exist, but they should be rare and explained in the PR:

- `git commit --no-verify`
- `git push --no-verify`

Use them only when the hook itself is the problem, not to skip a real failure.
