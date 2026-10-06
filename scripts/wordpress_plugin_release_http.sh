#!/usr/bin/env bash

wordpress_plugin_curl_get_limited() {
  local max_bytes="$1"
  local headers_file="$2"
  local body_file="$3"
  local curl_result=0
  local body_size
  local pipefail_was_enabled=0
  shift 3

  [[ "$max_bytes" =~ ^[1-9][0-9]*$ ]] || return 1
  (($# > 0)) || return 1
  : >"$headers_file"
  : >"$body_file"

  if shopt -qo pipefail; then
    pipefail_was_enabled=1
  else
    set -o pipefail
  fi

  if command curl -q --silent --show-error --connect-timeout 10 --max-time 60 \
    --dump-header "$headers_file" --output - "$@" 2>/dev/null \
    | head -c "$((max_bytes + 1))" >"$body_file"; then
    curl_result=0
  else
    curl_result=$?
  fi

  if ((pipefail_was_enabled == 0)); then
    set +o pipefail
  fi

  body_size="$(wc -c <"$body_file")" || return 1
  [[ "$body_size" =~ ^[0-9]+$ ]] || return 1
  ((body_size <= max_bytes)) || return 2
  ((curl_result == 0)) || return 1
}

wordpress_plugin_http_status() {
  local headers_file="$1"
  awk '
    {
      sub(/\r$/, "", $2)
      if (toupper($1) ~ /^HTTP\// && length($2) == 3 && $2 ~ /^[0-9]+$/) {
        status = $2
      }
    }
    END {
      if (status == "") {
        exit 1
      }
      print status
    }
  ' "$headers_file"
}
