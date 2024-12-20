#!/bin/bash
set -e

export SPARK_HOME=${SPARK_HOME:-/opt/spark}
export SPARK_MASTER_PORT=${SPARK_MASTER_PORT:-7077}
export SPARK_MODE=${SPARK_MODE:-"master"}
export SPARK_LOG_DIR=${SPARK_LOG_DIR:-/var/log/spark}

echo "SPARK_MODE: $SPARK_MODE"

# Function to start Spark Standalone Master
start_spark_master() {
  echo "Starting the Spark Master..."
  export SPARK_MASTER_WEBUI_PORT=${SPARK_MASTER_WEBUI_PORT:-8080}
  start-master.sh >>"${SPARK_LOG_DIR}/spark-master.log" 2>&1
}

# Function to start Spark Standalone Worker
start_spark_worker() {
  echo "Starting the Spark Worker..."
  export SPARK_WORKER_CORES=${SPARK_WORKER_CORES:-2}
  export SPARK_WORKER_MEMORY=${SPARK_WORKER_MEMORY:-4G}
  export SPARK_MASTER_HOST=${SPARK_MASTER_HOST:-"spark-master"}
  export SPARK_MASTER_URL=${SPARK_MASTER_URL:-"spark://$SPARK_MASTER_HOST:$SPARK_MASTER_PORT"}
  export SPARK_WORKER_WEBUI_PORT=${SPARK_WORKER_WEBUI_PORT:-8081}
  start-worker.sh "$SPARK_MASTER_URL" >>"${SPARK_LOG_DIR}/spark-worker.log" 2>&1
}

# Function to start Spark Connect Server
start_spark_connect() {
  echo "Starting the Spark Connect Server..."
  start-connect-server.sh >>"${SPARK_LOG_DIR}/spark-connect-server.log" 2>&1
  bash /opt/check_service_status_utility.sh "Spark" "SparkConnectServer"
  if [ $? -ne 0 ]; then
    echo "Spark Connect Server are not started. Please check the Spark logs."
    exit 1
  fi
  echo "Spark Connect Server started."
}

# Function to start Spark History Server
start_spark_history_server() {
  echo "Starting the Spark History Server..."
  export SPARK_HISTORY_SERVER_PORT=${SPARK_HISTORY_SERVER_PORT:-18080}
  export SPARK_HISTORY_OPTS="-Dspark.history.fs.logDirectory=$SPARK_HOME/spark-events -Dspark.history.ui.port=$SPARK_HISTORY_SERVER_PORT"
  start-history-server.sh >>"${SPARK_LOG_DIR}/spark-history-${SPARK_HISTORY_UI_PORT}.log" 2>&1
  sleep 5
  bash /opt/check_service_status_utility.sh "Spark" "HistoryServer"
  if [ $? -ne 0 ]; then
    echo "Spark History Server are not started. Please check the Spark logs."
    exit 1
  fi
  echo "Spark History Server started on ${SPARK_HISTORY_UI_PORT}."
}

if [ "$SPARK_MODE" == "master" ]; then
  start_spark_master
  start_spark_history_server
elif [ "$SPARK_MODE" == "worker" ]; then
  start_spark_worker
elif [ "$SPARK_MODE" == "history" ]; then
  start_spark_history_server
elif [ "$SPARK_MODE" == "connect" ]; then
  start_spark_connect
fi

while true; do sleep 1000; done
