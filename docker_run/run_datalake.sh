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

# PROFILE=core (default) starts docker-compose.yml.
# PROFILE=all starts docker-compose_all.yml, which adds MySQL, Trino, Jupyter, XTable and Flink.
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
    compose down
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
    echo "       Set PROFILE=all to include MySQL, Trino, Jupyter, XTable and Flink."
    exit 1
    ;;
esac
