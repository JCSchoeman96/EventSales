#!/usr/bin/env bash

set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

service="${RAILWAY_SERVICE:-EventSales}"

railway status >/dev/null
railway ssh --service "$service" \
  'env -u PHX_SERVER bin/event_sales eval "EventSales.Maintenance.CutoverDryRun.run!()"'
