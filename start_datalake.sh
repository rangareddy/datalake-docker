#!/bin/bash
set -euo pipefail  # Enable strict error handling

docker-compose down

rm -rf data logs

docker-compose up -d
