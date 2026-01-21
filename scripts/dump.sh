#!/bin/bash
#
# SPDX-FileCopyrightText: luk1337
# SPDX-License-Identifier: MIT
#
# Modified by: spike0en

# === Configuration ===
# Exit immediately if a command exits with a non-zero status
set -e

# Get number of available CPU cores and limit for optimal performance
DETECTED_CORES=$(nproc)
# Limit cores to a reasonable number, e.g., 32 or 44, based on typical CI runners or user machines
CORES=$((DETECTED_CORES > 44 ? 44 : DETECTED_CORES))
echo "Detected $DETECTED_CORES CPU cores, using $CORES cores for parallel processing (max 44)"

# Set thread limits for various operations
ARIA2C_CONNECTIONS=$((CORES > 16 ? 16 : CORES))  # aria2c max 16 connections per server
PARALLEL_JOBS=$CORES                             # GNU parallel jobs
COMPRESSION_THREADS=$CORES                       # 7z compression threads

echo "Thread allocation - ARIA2C: $ARIA2C_CONNECTIONS, PARALLEL: $PARALLEL_JOBS, 7Z: $COMPRESSION_THREADS"

# Set environment variables for parallelism
export PARALLEL="-j$PARALLEL_JOBS"

# Store original working directory and create absolute paths for critical files
ORIGINAL_DIR=$(pwd)
OTA_EXTRACTOR="$ORIGINAL_DIR/bin/ota_extractor"
DEVICES_JSON="$ORIGINAL_DIR/devices.json"
OUTPUT_DIR="$ORIGINAL_DIR/out"

# Ensure output directory exists
mkdir -p "$OUTPUT_DIR"

# Optimize memory usage with 32GB RAM limit for 7z
if command -v free >/dev/null 2>&1; then
    AVAILABLE_RAM=$(free -m | awk 'NR==2{print $7}')
    MAX_RAM_LIMIT=32768  # 32GB in MB

    # Use either available RAM/2 or 32GB limit, whichever is smaller
    MEMORY_LIMIT=$((AVAILABLE_RAM < MAX_RAM_LIMIT ? AVAILABLE_RAM / 2 : MAX_RAM_LIMIT / 2))
    export _7Z_MEMORY_LIMIT="${MEMORY_LIMIT}M"

    echo "Available RAM: ${AVAILABLE_RAM}MB, Setting 7z memory limit to $_7Z_MEMORY_LIMIT"
fi

# === Helper Functions ===

# Download ota file using gdown (for Google Drive links)
download_with_gdown() {
    echo "Downloading with gdown: $1"
    gdown --fuzzy "$1" -O ota.zip
}

# Download OTA using aria2c
download_with_aria2c() {
    local url="$1"
    local connections splits

    if [[ "$url" == *"android.googleapis.com"* || "$url" == *"gvt1.com"* ]]; then
        connections=3
        splits=3
        echo "Google OTA detected – using $connections connections and $splits splits"
    else
        connections=$ARIA2C_CONNECTIONS
        splits=$ARIA2C_CONNECTIONS
        echo "Normal URL – using $connections connections"
    fi

    rm -f ota.zip.aria2  # cleanup stale state

    aria2c -x"$connections" -s"$splits" --retry-wait=5 --max-tries=3 --continue=true \
        "$url" -o ota.zip \
    || {
        echo "aria2c failed – falling back to curl"
        curl -L --fail --retry 10 --retry-delay 5 -o ota.zip "$url"
    }
}

# Determine the correct download method based on URL and calls it
download_file() {
    local url="$1"
    echo "Processing URL: $url"

    if [[ "$url" == *"drive.google.com"* ]]; then
        download_with_gdown "$url"
    else
        download_with_aria2c "$url"
    fi
}

# === Initial Validation ===
# Check if at least one URL is provided
if [ -z "$1" ]; then
    echo "Error: No OTA URL provided." >&2
    exit 1
fi

# Extract the post-build fingerprint string from metadata
extract_fingerprint() {
    unzip -p ota.zip META-INF/com/android/metadata | grep "^post-build=" | cut -d'=' -f2 || echo "InvalidFingerprint"
}

# Extract the version_name from metadata
extract_version() {
    unzip -p ota.zip META-INF/com/android/metadata | grep "^version_name=" | cut -d'=' -f2 || echo "UnknownVersion"
}

# Device model auto detection
detect_model() {
    local detected_model="UnknownModel"

    # Read the entire metadata and payload_properties
    local metadata_content=$(unzip -p ota.zip META-INF/com/android/metadata 2>/dev/null || echo "")
    local properties_content=$(unzip -p ota.zip payload_properties.txt 2>/dev/null || echo "")
    local combined_content="$metadata_content$properties_content"

    # Loop over device codenames
    for codename in $(jq -r '.devices | keys[]' "$DEVICES_JSON"); do
        for model in $(jq -r ".devices[\"$codename\"] | .[]" "$DEVICES_JSON"); do
            if echo "$combined_content" | grep -qi "$model"; then
                detected_model="$codename"
                echo "$detected_model"
                return
            fi
        done
    done

    echo "$detected_model"
}

# === Download and Model Detection ===
echo "Downloading initial OTA package..."
download_file "$1"
echo "Download complete."

echo "Detecting device model..."
MODEL=$(detect_model)
echo "Detected model: $MODEL"

if [ "$MODEL" == "UnknownModel" ]; then
    echo "Error: Auto model detection has failed!" >&2
    rm -f ota.zip
    exit 1
fi

# === Initial Payload Extraction ===
echo "Extracting initial payload..."
# Ensure the ota_extractor binary is executable using absolute path before first use
chmod +x "$OTA_EXTRACTOR"
unzip ota.zip payload.bin || { echo "Failed to unzip payload"; rm -f ota.zip; exit 1; } # Basic cleanup
mv payload.bin payload_working.bin
TAG=$(extract_version)
FINGERPRINT=$(extract_fingerprint)
BODY="[$TAG]($1) (full)"
rm ota.zip

# === Prepare Working Directories ===
echo "Creating required directories..."
mkdir -p ota out dyn boot

# Extract images from the main payload using absolute path for ota_extractor
"$OTA_EXTRACTOR" -output_dir ota -payload payload_working.bin || { echo "Error: Failed to extract initial payload"; rm -f payload_working.bin; exit 1; } # Basic cleanup
echo "Initial payload extracted."
rm payload_working.bin

# === Incremental Updates ===
# Shift arguments to remove the first URL which has been processed
shift
# Process remaining arguments (if any) as incremental URLs
for i in "$@"; do
    echo "Processing incremental OTA: $i"
    download_file "$i"
    unzip ota.zip payload.bin || { echo "Failed to unzip incremental payload"; rm -f ota.zip; exit 1; }
    mv payload.bin payload_working.bin
    TAG=$(extract_version) # Update TAG (release name) to the latest version_name
    FINGERPRINT=$(extract_fingerprint)  # Update fingerprint for the latest incremental
    BODY="$BODY -> [$TAG]($i)"
    rm ota.zip

    mkdir ota_new
    # Apply incremental update using absolute path for ota_extractor
    "$OTA_EXTRACTOR" -input-dir ota -output_dir ota_new -payload payload_working.bin || { echo "Error: Failed to extract incremental payload for $i"; rm -f payload_working.bin; exit 1; }
    rm -rf ota
    mv ota_new ota
    rm payload_working.bin
done

# === Prepare Release Information ===
# Format the final fingerprint for the release body
BODY=$(printf "%s\n\n**Fingerprint:**\n%s" "$BODY" "${FINGERPRINT//|/$'\n'}")

# Append the GitHub Actions run URL to the release body
if [ -n "$GITHUB_RUN_ID" ]; then
    RUN_URL="${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}"
    BODY=$(printf "%s\n\n**Workflow Run**: [Here](%s)" "$BODY" "$RUN_URL")
fi

# === Fetch Partition Information ===
echo "Fetching partition lists for model: $MODEL"

# Map model ID to codename if exists, otherwise use model ID directly
CODENAME=$(jq -r --arg model "$MODEL" '
    .devices | to_entries[] | select(.value | contains([$model])) | .key
' "$DEVICES_JSON" | head -n 1)

# If codename is empty or null, default to MODEL itself
if [ -z "$CODENAME" ] || [ "$CODENAME" == "null" ]; then
    CODENAME="$MODEL"
fi
echo "Resolved codename: $CODENAME"

# Get partition lists dynamically from devices.json using jq with absolute path
BOOT_PARTITIONS=$(jq -r --arg codename "$CODENAME" '.definitions[$codename].boot_partitions | join(" ")' "$DEVICES_JSON")
LOGICAL_PARTITIONS=$(jq -r --arg codename "$CODENAME" '.definitions[$codename].logical_partitions | join(" ")' "$DEVICES_JSON")

# Check if partitions were successfully retrieved
if [ -z "$BOOT_PARTITIONS" ] || [ "$BOOT_PARTITIONS" == "null" ] || [ -z "$LOGICAL_PARTITIONS" ] || [ "$LOGICAL_PARTITIONS" == "null" ]; then
    echo "Error: Could not find partition info for codename '$CODENAME' (model '$MODEL') in $DEVICES_JSON or jq failed." >&2
    # Clean up intermediate files if they exist
    rm -f ota.zip payload_working.bin
    exit 1
fi

echo "Using dynamically fetched partitions for model: $MODEL"
echo "Boot Partitions: $BOOT_PARTITIONS"
echo "Logical Partitions: $LOGICAL_PARTITIONS"

# === Generate Hashes (Optimized for Parallel Processing) ===
echo "Generating file hashes using $PARALLEL_JOBS parallel jobs..."
# Switch to the directory containing extracted images
cd ota

# Sanitize filename for assets (replace ( ) with - and append region)
SAFE_TAG=$(echo "${TAG}_${INPUT_REGION}" | sed 's/(/-/g' | sed 's/)//g' | sed 's/--/-/g' | sed 's/-$//' | sed 's/ /_/g')

# Generate SHA-256 hashes for all extracted image files with parallel processing
echo "--- SHA256 Hashes ---"
ls * | parallel -j $PARALLEL_JOBS "openssl dgst -sha256 -r" 2>/dev/null | sort -k2 -V | tee ../out/${SAFE_TAG}-hash.sha256

# === Organize Images ===
echo "Organizing images..."
# Move boot-related images to `boot` directory
for f in $BOOT_PARTITIONS; do
    [ -f "${f}.img" ] && mv "${f}.img" ../boot
done

# Move logical partition images to `dyn` directory
for f in $LOGICAL_PARTITIONS; do
    [ -f "${f}.img" ] && mv "${f}.img" ../dyn
done

# === Archive Images with Thread Optimization ===
echo "Archiving images using optimized compression settings..."

# Archive boot, firmware (remaining in ota), and logical images in parallel
# Remove source directories after successful archiving
# Perform directory checks before attempting to archive
if [ -d "../boot" ] && [ "$(ls -A ../boot 2>/dev/null)" ]; then
    (cd ../boot && 7z a -mmt$COMPRESSION_THREADS -mx6 ../out/${SAFE_TAG}-image-boot.7z * && rm -rf ../boot) &
fi

if [ -d "../ota" ] && [ "$(ls -A ../ota 2>/dev/null)" ]; then
    (cd ../ota && 7z a -mmt$COMPRESSION_THREADS -mx6 ../out/${SAFE_TAG}-image-firmware.7z * && rm -rf ../ota) &
fi

if [ -d "../dyn" ] && [ "$(ls -A ../dyn 2>/dev/null)" ]; then
    (cd ../dyn && 7z a -mmt$COMPRESSION_THREADS -mx6 -v2000m ../out/${SAFE_TAG}-image-logical.7z * && rm -rf ../dyn) &
fi

wait

# === Set GitHub Actions Outputs ===
echo "Setting GitHub Actions outputs..."
if [ -n "$INPUT_NAME" ]; then
    CLEAN_NAME="${INPUT_NAME%-}"
    RELEASE_TAG_NAME="${CLEAN_NAME}_${INPUT_REGION}"
    echo "Using provided input name '$INPUT_NAME', cleaned to '$CLEAN_NAME', as release tag name."
else
    RELEASE_TAG_NAME="${TAG}_${INPUT_REGION}"
fi

# Output tag name, release name, and release body for the release action
if [ -n "$GITHUB_OUTPUT" ]; then
    {
        echo "release_tag=$RELEASE_TAG_NAME"
        echo "release_name=$RELEASE_TAG_NAME"
        echo "body<<EOF"
        echo "$BODY"
        echo "EOF"
    } >> "$GITHUB_OUTPUT"
fi

echo "Script completed successfully with optimized performance using $CORES CPU cores."
echo "Thread allocation summary - ARIA2C: $ARIA2C_CONNECTIONS, PARALLEL: $PARALLEL_JOBS, 7Z: $COMPRESSION_THREADS"
