#!/bin/bash

if [ $# -lt 2 ]; then
    echo "Please specify <SERVICE>, <GREP_STRING>";
    exit 1;
fi

export SERVICE=$1
export EGREP_STR=$2
export MAX_ATTEMPTS=5

IFS='|';
read -ra SERVICE_JPS <<< "$EGREP_STR"
unset IFS;

SERVICE_COUNT=${#SERVICE_JPS[@]}

ATTEMPT_COUNT=0
while [ $ATTEMPT_COUNT -lt $MAX_ATTEMPTS ]
do
	sleep 5;
  JPS_SERVICE_COUNT=$(jps -m | egrep -w "$EGREP_STR" | grep -v egrep | grep -v jps | wc -l)
  if [ "$JPS_SERVICE_COUNT" -eq "$SERVICE_COUNT" ]; then
    #echo "$SERVICE service(s) started.";
    break;
  fi
  ATTEMPT_COUNT=$(expr $ATTEMPT_COUNT + 1)
done

if [ "$ATTEMPT_COUNT" -eq $MAX_ATTEMPTS ]; then
	echo "The $SERVICE service(s) are not started. Please check the logs for errors.";
	exit 1;
fi