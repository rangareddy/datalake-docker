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
  if ! bash /opt/check_service_status_utility.sh "Spark" "SparkConnectServer"; then
    echo "Spark Connect Server are not started. Please check the Spark logs."
    exit 1
  fi
  echo "Spark Connect Server started."
}

# Function to start Spark History Server
start_spark_history_server() {
  echo "Starting the Spark History Server..."
  export SPARK_HISTORY_SERVER_PORT=${SPARK_HISTORY_SERVER_PORT:-18080}
  export SPARK_HISTORY_OPTS=${SPARK_HISTORY_OPTS:-"-Dspark.history.ui.port=$SPARK_HISTORY_SERVER_PORT"}
  start-history-server.sh >>"${SPARK_LOG_DIR}/spark-history-${SPARK_HISTORY_SERVER_PORT}.log" 2>&1
  sleep 5
  if ! bash /opt/check_service_status_utility.sh "Spark" "HistoryServer"; then
    echo "Spark History Server are not started. Please check the Spark logs."
    exit 1
  fi
  echo "Spark History Server started on ${SPARK_HISTORY_SERVER_PORT}."
}

# Function to start Notebook
#
# This image carries JupyterLab and the Python, Scala (spylon) and Java (IJava) kernels
# already, so the notebook service runs from here rather than from a separate 3.2GB
# jupyter image - and gets a real Spark to talk to instead of a bare Python kernel.
start_jupyter() {
  export PYSPARK_DRIVER_PYTHON=jupyter
  export PYSPARK_DRIVER_PYTHON_OPTS="notebook"
  export JUPYTER_PORT=${JUPYTER_PORT:-8888}
  export NOTEBOOK_DIR=${NOTEBOOK_DIR:-/opt/notebooks}
  mkdir -p "$NOTEBOOK_DIR"
  echo "Starting the Jupyter Lab in $NOTEBOOK_DIR..."
  nohup jupyter-lab --ip=0.0.0.0 --port="$JUPYTER_PORT" --no-browser --allow-root \
    --notebook-dir="$NOTEBOOK_DIR" --NotebookApp.token='' \
    >>"${SPARK_LOG_DIR}/jupyter.log" 2>&1 &
  sleep 5
  if [ -n "$(pgrep -f 'jupyter-lab')" ]; then
    echo "Jupyter Lab started successfully."
  else
    echo "ERROR: Jupyter Lab failed to start. Last lines of ${SPARK_LOG_DIR}/jupyter.log:"
    tail -20 "${SPARK_LOG_DIR}/jupyter.log" 2>/dev/null
    exit 1
  fi
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
elif [ "$SPARK_MODE" == "notebook" ]; then
  start_jupyter
else
  echo "ERROR: unknown SPARK_MODE '$SPARK_MODE'." >&2
  echo "Expected one of: master | worker | history | connect | notebook" >&2
  exit 1
fi

while true; do sleep 1000; done
