#!/bin/bash
set -euo pipefail  # Enable strict error handling

# Define constants
CURR_DIR=$(pwd)
export CURRENT_DIR=${CURRENT_DIR:-$CURR_DIR}
export HUDI_DIR="$CURRENT_DIR/hudi"
export HUDI_VERSIONS=("0.15.0" "1.0.0")
export SPARK_MAJOR_VERSION="${SPARK_MAJOR_VERSION:-3.5}"
export SCALA_VERSION=${SCALA_VERSION:-2.12}

# Function to clone the Hudi repository
clone_hudi_repo() {
    if [ ! -d "$HUDI_DIR" ]; then
        echo "Cloning Apache Hudi repository..."
        git clone --quiet https://github.com/apache/hudi.git "$HUDI_DIR"
    fi
}

# Function to checkout the specified Hudi version
checkout_hudi_version() {
	local hudi_version="$1"
    local HUDI_TAG_NAME=$(git tag | grep "$hudi_version" | sort -r | head -n 1)
    if [ -z "$HUDI_TAG_NAME" ]; then
        echo "Error: Hudi version $hudi_version not found."
        exit 1
    fi
    echo "Checking out Hudi tag version: $HUDI_TAG_NAME"
    git checkout "$HUDI_TAG_NAME" --quiet
}

# Function to build Apache Hudi
build_hudi() {
	local hudi_version="$1"
    cd "$HUDI_DIR"
	checkout_hudi_version "$hudi_version"
    echo "Building Apache Hudi..."
    mvn clean package -DskipTests -Dspark"${SPARK_MAJOR_VERSION}" -Dscala-${SCALA_VERSION}
    echo "Build completed successfully."
}

# Function to copy the build jars to target directory.
copy_target_jar_file_to_target_dir() {
    local current_dir="$1"
    local output_dir="$2"

    # Check for 'target' in the current directory
    local target_dir="$current_dir/target"
    if [ -d "$target_dir" ]; then
        for target_file in "$target_dir"/*; do
            if [[ "$target_file" == *.jar ]]; then
                local filename=$(basename "$target_file")
                if [[ "$filename" != *sources* && "$filename" != *tests* && "$filename" != *original* ]]; then
                    output_target_dir="${output_dir}/target"
                    mkdir -p "$output_target_dir"
                    cp "$target_file" "$output_target_dir"
                fi
            fi
        done
    fi

    # Iterate through all subdirectories
    for subdir in "$current_dir"/*; do
        if [ -d "$subdir" ]; then
            local my_current_dir=$(basename "$subdir")
            copy_target_jar_file_to_target_dir "$subdir" "$output_dir/$my_current_dir"  # Recursive call
        fi
    done
}

clone_hudi_repo

# Iterate over each version in the HUDI_VERSIONS array
for HUDI_VERSION in "${HUDI_VERSIONS[@]}"; do
    HUDI_TARGET_VERSION=$(echo "$HUDI_VERSION" | sed 's/\./_/g')
    HUDI_TARGET_DIR="${HUDI_DIR}_${HUDI_TARGET_VERSION}"
    if [ ! -d "$HUDI_TARGET_DIR" ]; then
    	build_hudi "$HUDI_VERSION"
    	copy_target_jar_file_to_target_dir "$HUDI_DIR" "$HUDI_TARGET_DIR"
    fi
done