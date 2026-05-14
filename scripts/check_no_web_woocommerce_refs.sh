#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
web_root="${repo_root}/lib/event_sales_web"
mapping_resolver="${repo_root}/lib/event_sales/catalog/mapping_resolver.ex"

declare -a scan_targets=()
declare -a forbidden_patterns=(
  "WooCommerceClient"
  "Req."
  "Tesla."
  "Finch."
  "HTTPoison."
  "/wp-json/wc/"
)

if [[ -d "${web_root}" ]]; then
  scan_targets+=("${web_root}")
fi

if [[ -f "${mapping_resolver}" ]]; then
  scan_targets+=("${mapping_resolver}")
fi

if [[ "${#scan_targets[@]}" -eq 0 ]]; then
  echo "No web-layer scan targets found."
  exit 0
fi

matches_found=0

for pattern in "${forbidden_patterns[@]}"; do
  if rg --line-number --fixed-strings "${pattern}" "${scan_targets[@]}"; then
    matches_found=1
  fi
done

if [[ "${matches_found}" -ne 0 ]]; then
  echo
  echo "Forbidden WooCommerce REST reference found in web layer or MappingResolver."
  echo "Controllers, LiveViews, components, presenters, plugs, and MappingResolver must not call WooCommerce REST."
  exit 1
fi

echo "No forbidden WooCommerce REST references found."
