#!/bin/bash

KAFKA_HOSTNAME=${KAFKA_HOSTNAME:-"kafka"}
KAFKA_PORT=${KAFKA_PORT:-29092}
KAFKA_TOPIC_NAME=${KAFKA_TOPIC_NAME:-"hudi-test-topic"}
STOCKS_DATA_FILE=stocks_data.json
EVENTS_FILE=${EVENTS_FILE:-"kafka_input_events"}
NUM_OF_RECORDS=${NUM_OF_RECORDS:-10}
NUM_OF_BATCHES=${NUM_OF_BATCHES:-2}
NUM_OF_HUDI_PARTITIONS=${NUM_OF_HUDI_PARTITIONS:-3}

numHudiPartitions=$NUM_OF_HUDI_PARTITIONS
numBatch=$NUM_OF_BATCHES
numRecords=$NUM_OF_RECORDS
recordKey=${recordKey:-volume}
partitionField=${partitionField:-date}
recordValue=0

# Generate kafka messages from raw records
# Each records with unique keys and generate equal messages across each hudi partition
partitions={}
for ((i = 0; i < ${numHudiPartitions}; i++)); do
  partitions[$i]="partition_"$i
done

for ((i = 1; i <= numBatch; i++)); do
  rm -rf ${EVENTS_FILE}
  echo "Sending messages to Kafka in batch $i on $date..."
  batchRecordSeq=0
  for (( ; ; )); do
    while IFS= read line; do
      for partitionValue in "${partitions[@]}"; do
        echo $line | jq --arg recordKey $recordKey --arg recordValue $recordValue --arg partitionField $partitionField \
          --arg partitionValue $partitionValue -c '.[$recordKey] = $recordValue | .[$partitionField] = $partitionValue' >>${EVENTS_FILE}
        ((recordValue = recordValue + 1))
        ((batchRecordSeq = batchRecordSeq + 1))

        if [ $batchRecordSeq -eq $numRecords ]; then
          break
        fi
      done

      if [ $batchRecordSeq -eq $numRecords ]; then
        break
      fi
    done <"$STOCKS_DATA_FILE"

    if [ $batchRecordSeq -eq $numRecords ]; then
      date
      echo "Record key until $recordValue"
      sleep 20
      break
    fi
  done

  echo "Publishing stock data to Kafka topic ${KAFKA_TOPIC_NAME}..."
  grep -v '^$' ${EVENTS_FILE} | kafkacat -b "${KAFKA_HOSTNAME}:${KAFKA_PORT}" -t "${KAFKA_TOPIC_NAME}" -T -P
done
