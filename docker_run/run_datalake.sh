#!/bin/bash
set -euo pipefail # Enable strict error handling

SCRIPT_DIR="$(
    cd "$(dirname "$0")"
    pwd -P
)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

# shellcheck source=../docker_build/validate_docker_status.sh
source "$REPO_DIR/docker_build/validate_docker_status.sh"

COMPOSE_CMD="$(get_docker_compose_cmd)"

# The compose files read ${PLATFORM} for every service. Export the detected value so
# the stack runs natively on whatever this machine is, without anyone editing .env.
# An explicit PLATFORM in the environment or in .env still wins.
PLATFORM="$(get_docker_platform)"
export PLATFORM

# Spark 3 and Spark 4 are separate images: ranga-spark keeps the original name so older
# pulls keep working, and ranga-spark4 is the new line. Derive which one this
# SPARK_VERSION wants so the stack starts the matching image without anyone editing
# .env; an explicit SPARK_IMAGE still wins.
if [ -z "${SPARK_IMAGE:-}" ]; then
    case "${SPARK_VERSION:-}" in
    4.*) SPARK_IMAGE="ranga-spark4" ;;
    *) SPARK_IMAGE="ranga-spark" ;;
    esac
fi
export SPARK_IMAGE

# PROFILE=core (default) starts docker-compose.yml.
# PROFILE=all starts docker-compose_all.yml, which adds MySQL, Trino and Jupyter.
PROFILE="${PROFILE:-core}"
case "$PROFILE" in
core) COMPOSE_FILE="$SCRIPT_DIR/docker-compose.yml" ;;
all) COMPOSE_FILE="$SCRIPT_DIR/docker-compose_all.yml" ;;
*)
    echo "Error: Invalid PROFILE '$PROFILE'. Expected 'core' or 'all'."
    exit 1
    ;;
esac

state=${1:-"start"}
state=$(echo "$state" | tr '[:upper:]' '[:lower:]')

compose() {
    # Word splitting on COMPOSE_CMD is intentional: it is either "docker compose" or "docker-compose".
    # shellcheck disable=SC2086
    $COMPOSE_CMD -f "$COMPOSE_FILE" "$@"
}

start_datalake() {
    echo "Starting Datalake services ($PROFILE profile)..."
    compose up -d
    echo "Datalake services are started."
}

stop_datalake() {
    echo "Stopping Datalake services ($PROFILE profile)..."
    # --remove-orphans: a plain "down" leaves behind any container whose service has
    # since been deleted from the compose file. Those keep running, keep their ports and
    # keep their image pinned, so a removed component looks removed in git and is still
    # up in Docker.
    compose down --remove-orphans
    echo "Datalake services are stopped."
}

restart_datalake() {
    stop_datalake
    start_datalake
}

status_datalake() {
    compose ps
}

logs_datalake() {
    shift || true
    compose logs -f --tail=100 "$@"
}

validate_datalake() {
    echo "Validating $COMPOSE_FILE ..."
    compose config -q
    echo "OK: $COMPOSE_FILE is a valid compose project."
}

case $state in
start)
    validate_datalake
    start_datalake
    ;;
stop)
    stop_datalake
    ;;
restart)
    restart_datalake
    ;;
status | ps)
    status_datalake
    ;;
logs)
    logs_datalake "$@"
    ;;
validate | config)
    validate_datalake
    ;;
*)
    echo "Error: Invalid state '$state'. Usage: $0 {start|stop|restart|status|logs [service...]|validate}"
    echo "       Set PROFILE=all to include MySQL, Trino and Jupyter."
    exit 1
    ;;
esac
