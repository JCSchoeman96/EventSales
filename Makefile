SHELL := /usr/bin/env bash
.SHELLFLAGS := -euo pipefail -c

.DEFAULT_GOAL := ready

MIX := mise exec -- mix

HEX_HTTP_TIMEOUT ?= 180
HEX_HTTP_CONCURRENCY ?= 1

export HEX_HTTP_TIMEOUT
export HEX_HTTP_CONCURRENCY

.PHONY: ready ready-local doctor sync toolchain deps infra db db-test quality test reset-db stop-db logs-db

ready: doctor sync toolchain deps infra db db-test quality test
	@echo ""
	@echo "🚀 EventSales workspace synced, validated, and ready for the agent."

ready-local: doctor toolchain deps infra db db-test quality test
	@echo ""
	@echo "🚀 EventSales local workspace validated. No git sync was performed."

doctor:
	@echo "=== 0. Checking Required Tools ==="
	@command -v git >/dev/null || { echo "Missing: git"; exit 1; }
	@command -v bash >/dev/null || { echo "Missing: bash"; exit 1; }
	@command -v mise >/dev/null || { echo "Missing: mise"; exit 1; }
	@command -v docker >/dev/null || { echo "Missing: docker"; exit 1; }

sync:
	@echo ""
	@echo "=== 1. Checking Git Sync Safety ==="
	@bash scripts/sync_with_origin_main.sh --check

	@echo ""
	@echo "=== 2. Syncing with origin/main ==="
	@bash scripts/sync_with_origin_main.sh --sync

toolchain:
	@echo ""
	@echo "=== 3. Installing Pinned Toolchain ==="
	@mise install

	@echo ""
	@echo "=== 4. Verifying Toolchain ==="
	@mise exec -- elixir --version
	@mise exec -- erl -eval 'erlang:display(erlang:system_info(otp_release)), halt().' -noshell

deps:
	@echo ""
	@echo "=== 5. Installing Hex/Rebar ==="
	@$(MIX) local.hex --force
	@$(MIX) local.rebar --force

	@echo ""
	@echo "=== 6. Fetching Elixir Dependencies ==="
	@$(MIX) deps.get
	@$(MIX) deps.compile

infra:
	@echo ""
	@echo "=== 7. Starting EventSales Dev Postgres ==="
	@bash scripts/dev_postgres.sh start

	@echo ""
	@echo "=== 8. Checking EventSales Dev Postgres Status ==="
	@bash scripts/dev_postgres.sh status

db:
	@echo ""
	@echo "=== 9. Preparing Development Database ==="
	@$(MIX) ecto.create
	@$(MIX) ecto.migrate

db-test:
	@echo ""
	@echo "=== 10. Preparing Test Database ==="
	@MIX_ENV=test $(MIX) ecto.create
	@MIX_ENV=test $(MIX) ecto.migrate

quality:
	@echo ""
	@echo "=== 11. Running Fast Quality Checks ==="
	@$(MIX) precommit

test:
	@echo ""
	@echo "=== 12. Running Full Test Suite ==="
	@$(MIX) test

reset-db:
	@echo ""
	@echo "=== Resetting EventSales Dev Postgres ==="
	@bash scripts/dev_postgres.sh reset
	@bash scripts/dev_postgres.sh start
	@$(MIX) ecto.create
	@$(MIX) ecto.migrate
	@MIX_ENV=test $(MIX) ecto.create
	@MIX_ENV=test $(MIX) ecto.migrate

stop-db:
	@echo ""
	@echo "=== Stopping EventSales Dev Postgres ==="
	@bash scripts/dev_postgres.sh stop

logs-db:
	@bash scripts/dev_postgres.sh logs