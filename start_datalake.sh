#!/bin/bash

set -euo pipefail # Enable strict error handling

docker-compose down

if [ -d data ]; then
    rm -rf data logs
fi

docker-compose up -d
