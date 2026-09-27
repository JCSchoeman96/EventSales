#!/usr/bin/env bash
set -euo pipefail

readonly CONTAINER_NAME="eventsales-postgres-dev"
readonly VOLUME_NAME="eventsales-postgres-dev-data"
readonly POSTGRES_USER_VALUE="postgres"
readonly POSTGRES_DB_VALUE="event_sales_test"
readonly PORT_MAPPING="127.0.0.1:5432:5432"

usage() {
  echo "Usage: scripts/dev_postgres.sh {start|stop|status|logs}"
  echo "Legacy reset and creation of new containers are disabled; existing data is preserved."
}

container_exists() {
  docker container inspect "${CONTAINER_NAME}" >/dev/null 2>&1
}

container_running() {
  [[ "$(docker inspect -f '{{.State.Running}}' "${CONTAINER_NAME}" 2>/dev/null || true)" == "true" ]]
}

start_container() {
  if container_running; then
    echo "Dev Postgres already running."
    wait_for_ready
    return 0
  fi

  if container_exists; then
    docker start "${CONTAINER_NAME}" >/dev/null
    echo "Started existing dev Postgres container."
    wait_for_ready
    return 0
  fi

  echo "Legacy container creation is disabled; only an existing container can be started." >&2
  return 2
}

wait_for_ready() {
  local attempts=30

  for _ in $(seq 1 "${attempts}"); do
    if docker exec "${CONTAINER_NAME}" pg_isready -U "${POSTGRES_USER_VALUE}" -d "${POSTGRES_DB_VALUE}" >/dev/null 2>&1; then
      echo "Dev Postgres is ready."
      return 0
    fi

    sleep 1
  done

  echo "Problem: Dev Postgres did not become ready within ${attempts}s." >&2
  return 1
}

stop_container() {
  if ! container_exists; then
    echo "Dev Postgres container does not exist."
    return 0
  fi

  if container_running; then
    docker stop "${CONTAINER_NAME}" >/dev/null
  fi

  echo "Stopped dev Postgres container; container and volume are retained."
}

reset_container() {
  echo "Legacy database reset is disabled to preserve the existing container and volume." >&2
  return 2
}

status_container() {
  docker ps -a \
    --filter "name=^/${CONTAINER_NAME}$" \
    --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"

  if docker volume inspect "${VOLUME_NAME}" >/dev/null 2>&1; then
    echo "Volume: ${VOLUME_NAME} (present)"
  else
    echo "Volume: ${VOLUME_NAME} (missing)"
  fi
}

logs_container() {
  if ! container_exists; then
    echo "Dev Postgres container does not exist."
    exit 1
  fi

  docker logs -f "${CONTAINER_NAME}"
}

main() {
  local command="${1:-}"

  case "${command}" in
    start)
      start_container
      ;;
    stop)
      stop_container
      ;;
    reset)
      reset_container
      ;;
    status)
      status_container
      ;;
    logs)
      logs_container
      ;;
    *)
      usage
      exit 2
      ;;
  esac
}

main "$@"
