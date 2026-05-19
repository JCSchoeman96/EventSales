#!/usr/bin/env bash
set -euo pipefail

readonly CONTAINER_NAME="eventsales-postgres-dev"
readonly VOLUME_NAME="eventsales-postgres-dev-data"
readonly IMAGE_NAME="postgres:16-alpine"
readonly POSTGRES_USER_VALUE="postgres"
readonly POSTGRES_PASSWORD_VALUE="postgres"
readonly POSTGRES_DB_VALUE="event_sales_test"
readonly PORT_MAPPING="5432:5432"

usage() {
  echo "Usage: scripts/dev_postgres.sh {start|stop|reset|status|logs}"
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

  docker run -d \
    --name "${CONTAINER_NAME}" \
    -e POSTGRES_USER="${POSTGRES_USER_VALUE}" \
    -e POSTGRES_PASSWORD="${POSTGRES_PASSWORD_VALUE}" \
    -e POSTGRES_DB="${POSTGRES_DB_VALUE}" \
    -p "${PORT_MAPPING}" \
    -v "${VOLUME_NAME}:/var/lib/postgresql/data" \
    "${IMAGE_NAME}" >/dev/null

  echo "Started new dev Postgres container."
  wait_for_ready
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

  docker rm -f "${CONTAINER_NAME}" >/dev/null
  echo "Stopped and removed dev Postgres container."
}

reset_container() {
  if container_exists; then
    docker rm -f "${CONTAINER_NAME}" >/dev/null
  fi

  docker volume rm -f "${VOLUME_NAME}" >/dev/null 2>&1 || true
  echo "Reset dev Postgres container and deleted volume."
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
