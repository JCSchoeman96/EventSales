SHELL := /usr/bin/env bash
.SHELLFLAGS := -euo pipefail -c

.DEFAULT_GOAL := ready

MIX := mise exec -- mix

HEX_HTTP_TIMEOUT ?= 180
HEX_HTTP_CONCURRENCY ?= 1

export HEX_HTTP_TIMEOUT
export HEX_HTTP_CONCURRENCY

.PHONY: ready ready-local doctor sync toolchain deps infra db db-test quality test index index-check reset-db stop-db logs-db dev dev-doctor dev-status dev-stop catalogue-dry-run catalogue-dry-run-fresh

dev:
	@bash scripts/dev_local.sh

dev-doctor:
	@bash scripts/dev_local.sh doctor

dev-status:
	@bash scripts/dev_local.sh status

dev-stop:
	@bash scripts/dev_local.sh stop

catalogue-dry-run:
	@bash scripts/dev_local.sh catalogue-dry-run

catalogue-dry-run-fresh:
	@bash scripts/dev_local.sh catalogue-dry-run --fresh

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
	@echo "=== 6. Fetching and Compiling Elixir Dependencies ==="
	@$(MIX) deps.get
	@$(MIX) deps.compile
	@MIX_ENV=test $(MIX) deps.compile

infra:
	@echo ""
	@echo "=== 7. Starting EventSales PostgreSQL and Redis ==="
	@docker compose --env-file /dev/null up -d --wait

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

index:
	@$(MIX) project.index

index-check:
	@$(MIX) project.index --check

reset-db:
	@echo ""
	@echo "=== Resetting EventSales Dev Postgres ==="
	@echo "Use an explicitly approved database maintenance workflow; no reset is provided here."
	@exit 1

stop-db:
	@echo ""
	@echo "=== Stopping EventSales PostgreSQL and Redis ==="
	@docker compose --env-file /dev/null down

logs-db:
	@docker compose --env-file /dev/null logs postgres
