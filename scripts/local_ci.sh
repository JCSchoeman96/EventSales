#!/usr/bin/env bash

set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

echo "==> Checking git worktree"
git diff --check

echo "==> Formatting"
mix format --check-formatted

echo "==> Compiling"
mix compile --warnings-as-errors

echo "==> WooCommerce web boundary"
bash scripts/check_no_web_woocommerce_refs.sh

echo "==> Ash codegen dry-run"
MIX_ENV=test mix ash.codegen --dry-run

echo "==> Migration/resource snapshot cleanliness"
git diff --exit-code priv/repo/migrations priv/resource_snapshots

echo "==> Tests and quality gate"
mix quality.pr

echo "==> Dialyzer"
mix dialyzer

echo "==> Done"
