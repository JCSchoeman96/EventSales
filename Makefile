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

ready: doctor toolchain deps infra db quality test
	@echo ""
	@echo "🚀 EventSales workspace validated and ready for the agent."

ready-local: doctor toolchain deps infra db quality test
	@echo ""
	@echo "🚀 EventSales local workspace validated. No git sync was performed."

doctor:
	@echo "=== 0. Checking Required Tools ==="
	@command -v git >/dev/null || { echo "Missing: git"; exit 1; }
	@command -v bash >/dev/null || { echo "Missing: bash"; exit 1; }
	@command -v mise >/dev/null || { echo "Missing: mise"; exit 1; }

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
	@echo "=== 7. Checking workstation shared infrastructure ==="
	@bash scripts/dev_local.sh doctor

db:
	@echo ""
	@echo "=== 9. Preparing Development Database ==="
	@bash scripts/dev_local.sh migrate

db-test:
	@echo ""
	@echo "=== Test databases are prepared by the isolated local test runner ==="
	@echo "Run make test to create and migrate a unique database on PostgreSQL TEST."

quality:
	@echo ""
	@echo "=== 11. Running Fast Quality Checks ==="
	@$(MIX) precommit

test:
	@echo ""
	@echo "=== 12. Running Full Test Suite ==="
	@bash scripts/dev_local.sh test

index:
	@$(MIX) project.index

index-check:
	@$(MIX) project.index --check

reset-db:
	@echo ""
	@echo "=== EventSales development database reset is disabled ==="
	@echo "Use an explicitly approved database maintenance workflow; no reset is provided here."
	@exit 1

stop-db:
	@echo ""
	@echo "=== Shared PostgreSQL and Redis are externally owned ==="
	@echo "No workstation infrastructure was stopped."

logs-db:
	@echo "Database container logs are owned by the workstation dev-core stack."
	@echo "This repository does not control that lifecycle."
