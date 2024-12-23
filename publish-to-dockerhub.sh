#!/bin/bash

# Docker Hub username
export DOCKER_HUB_USERNAME="rangareddy1988"

# Function to publish a single Docker image
publish_docker_image() {
    local image_name="$1"
    local image_tag="$2"

    if [[ "$image_name" == "$DOCKER_HUB_USERNAME"* ]]; then
        full_image_name="$image_name:$image_tag"
    else
        full_image_name="$DOCKER_HUB_USERNAME/$image_name:$image_tag"
    fi

    echo "Pushing image $full_image_name to dockerhub..."
    docker push "$full_image_name" || {
        echo "Error pushing image $full_image_name"
        return 1
    }
}

IMAGE_NAME_PATTERN="ranga-"

# Get all local Docker images matching the pattern
image_list=$(docker images --format "{{.Repository}}:{{.Tag}}" | grep "$IMAGE_NAME_PATTERN")

if [[ -z "$image_list" ]]; then
    echo "No images found matching the pattern '$IMAGE_NAME_PATTERN'"
    exit 0
fi

# Iterate through the matching images and publish them
while IFS=: read -r image_name image_tag; do
    publish_docker_image "$image_name" "$image_tag" || exit 1 # Exit on push error
done <<<"$image_list"

echo "Publishing process complete."
