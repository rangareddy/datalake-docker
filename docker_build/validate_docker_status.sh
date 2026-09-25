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

# Architecture of the machine the images will actually run on, as a bare arch
# ("amd64" or "arm64"). Nothing here is hardcoded: builds and the Compose stack both
# derive their platform from this, so an Apple Silicon machine builds and runs arm64
# natively and an Intel machine amd64, with no file to edit.
#
# The daemon is asked first, because that is what will execute the container and it is
# correct even when the CLI runs somewhere else. uname is the fallback.
get_docker_architecture() {
    local arch=""
    arch="$(docker version --format '{{.Server.Arch}}' 2>/dev/null || true)"

    if [ -z "$arch" ]; then
        case "$(uname -m)" in
        x86_64 | amd64) arch="amd64" ;;
        arm64 | aarch64) arch="arm64" ;;
        esac
    fi

    case "$arch" in
    amd64 | arm64)
        echo "$arch"
        return 0
        ;;
    esac

    echo "Unsupported Docker architecture: '${arch:-unknown}'. Expected amd64 or arm64." >&2
    return 1
}

# The same answer as a Docker platform string, which is what --platform and the Compose
# `platform:` keys want. PLATFORM from the environment always wins, so a cross-build
# stays possible: PLATFORM=linux/amd64 ./docker_build/build_docker_images.sh
get_docker_platform() {
    if [ -n "${PLATFORM:-}" ]; then
        echo "$PLATFORM"
        return 0
    fi
    local arch
    arch="$(get_docker_architecture)" || return 1
    echo "linux/${arch}"
}

check_docker_installed
check_docker_running
