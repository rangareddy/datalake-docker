#!/bin/bash

set -euo pipefail # Enable strict error handling

docker-compose down
docker-compose up -d
