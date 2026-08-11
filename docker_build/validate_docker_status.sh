#!/bin/bash
set -e

# Function to check Docker installation
check_docker_installed() {
    if ! command -v docker >/dev/null 2>&1; then
        echo "ERROR: Docker is not installed. Please install docker and rerun."
        exit 1
    fi
    if ! docker compose version >/dev/null 2>&1 && ! command -v docker-compose >/dev/null 2>&1; then
        echo "ERROR: Docker Compose is not installed (neither 'docker compose' nor 'docker-compose')."
        exit 1
    fi
}

# Echo the available Compose command: v2 plugin preferred, v1 binary as fallback.
get_docker_compose_cmd() {
    if docker compose version >/dev/null 2>&1; then
        echo "docker compose"
    else
        echo "docker-compose"
    fi
}

# Function to check Docker running status
check_docker_running() {
    if ! docker info >/dev/null 2>&1; then
        echo "ERROR: The docker daemon is not running or accessible. Please start docker and rerun."
        exit 1
    fi
}

# Function to determine the architecture
get_docker_architecture() {
    local ARCH=""
    SUPPORTED_PLATFORMS=("linux/amd64" "linux/arm64")
    for PLATFORM in "${SUPPORTED_PLATFORMS[@]}"; do
        if docker buildx ls | grep "$PLATFORM" >/dev/null 2>&1; then
            ARCH=$(echo "${PLATFORM}" | cut -d '/' -f2)
            echo "$ARCH" # Return the architecture
            return 0     # Success
        fi
    done

    # If no supported architecture is found, print an error and exit
    echo "Unsupported Docker architecture." >&2
    exit 1
}

check_docker_installed
check_docker_running
