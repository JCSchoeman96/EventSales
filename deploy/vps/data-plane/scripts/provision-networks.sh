#!/usr/bin/env bash
set -euo pipefail

DATA_NETWORK=eventsales-prod_eventsales_data
EDGE_NETWORK=eventsales-prod_eventsales_edge

if (($# != 0)); then
  printf 'Usage: %s\n' "$0" >&2
  exit 2
fi

if ! command -v docker >/dev/null 2>&1; then
  printf 'STOP=DOCKER_CLI_UNAVAILABLE\n' >&2
  exit 127
fi

network_exists() {
  local expected_name=$1
  local listed_names listed_name

  if ! listed_names=$(docker network ls --format '{{.Name}}'); then
    printf 'STOP=NETWORK_LIST_FAILED\n' >&2
    return 2
  fi

  while IFS= read -r listed_name; do
    if [[ "$listed_name" == "$expected_name" ]]; then
      return 0
    fi
  done <<<"$listed_names"

  return 1
}

validate_network() {
  local expected_name=$1
  local expected_internal=$2
  local metadata actual_name actual_driver actual_internal

  if ! metadata=$(docker network inspect --format '{{.Name}}|{{.Driver}}|{{.Internal}}' "$expected_name"); then
    printf 'STOP=NETWORK_INSPECT_FAILED name=%s\n' "$expected_name" >&2
    return 1
  fi

  if [[ "$metadata" == *$'\n'* ]]; then
    printf 'STOP=NETWORK_INSPECT_RETURNED_MULTIPLE_RECORDS name=%s\n' "$expected_name" >&2
    return 1
  fi

  IFS='|' read -r actual_name actual_driver actual_internal <<<"$metadata"
  if [[ "$actual_name" != "$expected_name" || "$actual_driver" != bridge || "$actual_internal" != "$expected_internal" ]]; then
    printf 'STOP=NETWORK_CONFLICT name=%s driver=%s internal=%s expected_driver=bridge expected_internal=%s\n' \
      "$actual_name" "$actual_driver" "$actual_internal" "$expected_internal" >&2
    return 1
  fi
}

check_network() {
  local name=$1
  local expected_internal=$2
  local lookup_status

  if network_exists "$name"; then
    validate_network "$name" "$expected_internal" || return 1
    NETWORK_STATE=present
  else
    lookup_status=$?
    if [[ "$lookup_status" -ne 1 ]]; then
      return "$lookup_status"
    fi
    NETWORK_STATE=absent
  fi
}

provision_network() {
  local name=$1
  local expected_internal=$2
  local state=$3

  if [[ "$state" == absent ]]; then
    if [[ "$expected_internal" == true ]]; then
      docker network create --driver bridge --internal "$name" >/dev/null || {
        printf 'STOP=NETWORK_CREATE_FAILED name=%s\n' "$name" >&2
        return 1
      }
    else
      docker network create --driver bridge "$name" >/dev/null || {
        printf 'STOP=NETWORK_CREATE_FAILED name=%s\n' "$name" >&2
        return 1
      }
    fi
    state=created
  else
    state=validated
  fi

  validate_network "$name" "$expected_internal" || return 1
  printf 'NETWORK_NAME=%s DRIVER=bridge INTERNAL=%s STATE=%s\n' \
    "$name" "$expected_internal" "$state"
}

check_network "$DATA_NETWORK" true
DATA_NETWORK_STATE=$NETWORK_STATE
check_network "$EDGE_NETWORK" false
EDGE_NETWORK_STATE=$NETWORK_STATE

provision_network "$DATA_NETWORK" true "$DATA_NETWORK_STATE"
provision_network "$EDGE_NETWORK" false "$EDGE_NETWORK_STATE"
