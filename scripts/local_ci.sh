#!/usr/bin/env bash

set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

echo "==> Checking git worktree"
git diff --check

echo "==> Full CI quality gate on an isolated PostgreSQL TEST database"
bash scripts/dev_local.sh quality-ci

echo "==> Done"
