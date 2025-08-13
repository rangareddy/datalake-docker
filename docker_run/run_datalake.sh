#!/bin/bash

SCRIPT_DIR="$(cd $(dirname "$0"); pwd)"

state=${1:-"start"}
#state="${state,,}"
state=$(echo "$state" | tr '[:upper:]' '[:lower:]')

set -euo pipefail # Enable strict error handling

start_datalake() {
    echo "Starting Datalake services..."
    docker-compose -f "$SCRIPT_DIR/docker-compose.yml" up -d
    echo "Datalake services are started."
}

stop_datalake() {
    echo "Stopping Datalake services..."
    docker-compose -f "$SCRIPT_DIR/docker-compose.yml" down
    echo "Datalake services are stopped."
}

restart_datalake() {
  stop_datalake
  start_datalake
}

case $state in
    start)
      start_datalake
      ;;
    stop)
      stop_datalake
      ;;
    restart)
      restart_datalake
      ;;
    *)
      echo "Error: Invalid state '$state'. Usage: $0 {start|stop|restart}"
      exit 1
      ;;
esac

trap "stop_datalake" SIGTERM
