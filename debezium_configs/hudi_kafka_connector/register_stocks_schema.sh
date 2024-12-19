#!/bin/bash

KAFKA_TOPIC_NAME=hudi-test-topic
STOCKS_SCHEMA_FILE=stocks.avsc
KAFKA_SCHEMA_REGISTRY_PORT=8081
KAFKA_SCHEMA_REGISTRY_HOSTNAME=kafka-schema-registry

# Setup the schema registry
STOCKS_SCHEMA=$(sed 's|/\*|\n&|g;s|*/|&\n|g' ${STOCKS_SCHEMA_FILE} | sed '/\/\*/,/*\//d' | jq tostring)

curl -X POST -H "Content-Type: application/vnd.schemaregistry.v1+json" \
  --data "{\"schema\": $STOCKS_SCHEMA}" http://$KAFKA_SCHEMA_REGISTRY_HOSTNAME:$KAFKA_SCHEMA_REGISTRY_PORT/subjects/${KAFKA_TOPIC_NAME}/versions

curl -X GET http://$KAFKA_SCHEMA_REGISTRY_HOSTNAME:$KAFKA_SCHEMA_REGISTRY_PORT/subjects/${KAFKA_TOPIC_NAME}/versions/latest
