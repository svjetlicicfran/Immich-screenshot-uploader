#!/usr/bin/env bash
# Watches a directory and uploads every new image/video to an Immich server.
# Requires: inotify-tools (inotifywait), curl

# ---- Configuration (fill these in, or override via environment) ----
WATCH_DIR="${WATCH_DIR:-$HOME/Pictures/Screenshots}"
IMMICH_URL="${IMMICH_URL:-http://IMMICH_SERVER_IP:2283}"   # no trailing slash
IMMICH_API_KEY="${IMMICH_API_KEY:-YOUR_API_KEY}"
DEVICE_ID="${DEVICE_ID:-screenshot-uploader}"
# --------------------------------------------------------------------

log() { echo "[$1] $(date '+%Y-%m-%d %H:%M:%S') $2"; }

for cmd in inotifywait curl; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "ERROR: '$cmd' not found. Please install it." >&2
        exit 1
    fi
done

if [[ ! -d "$WATCH_DIR" ]]; then
    echo "ERROR: directory '$WATCH_DIR' does not exist." >&2
    exit 1
fi

if [[ "$IMMICH_API_KEY" == "YOUR_API_KEY" || "$IMMICH_URL" == *IMMICH_SERVER_IP* ]]; then
    echo "ERROR: set IMMICH_URL and IMMICH_API_KEY in the script first." >&2
    exit 1
fi

# Upload one file to Immich. Returns 0 on success.
upload_file() {
    local file="$1"
    local filename mtime size created modified device_asset_id response http_code

    filename="$(basename "$file")"
    mtime="$(stat -c %Y "$file")"
    size="$(stat -c %s "$file")"
    created="$(date -u -d "@$mtime" '+%Y-%m-%dT%H:%M:%S.000Z')"
    modified="$created"
    device_asset_id="${filename}-${size}-${mtime}"

    http_code="$(curl -sS -o /tmp/immich_response.$$ -w '%{http_code}' \
        -X POST "${IMMICH_URL}/api/assets" \
        -H "Accept: application/json" \
        -H "x-api-key: ${IMMICH_API_KEY}" \
        -F "deviceAssetId=${device_asset_id}" \
        -F "deviceId=${DEVICE_ID}" \
        -F "fileCreatedAt=${created}" \
        -F "fileModifiedAt=${modified}" \
        -F "assetData=@${file}")"
    local rc=$?
    response="$(cat /tmp/immich_response.$$ 2>/dev/null)"
    rm -f /tmp/immich_response.$$

    if [[ $rc -ne 0 ]]; then
        log ERROR "curl failed for '$filename' (exit $rc)"
        return 1
    fi

    case "$http_code" in
        201) log INFO "Uploaded '$filename' -> $response" ;;
        200) log INFO "Skipped '$filename' (already on server) -> $response" ;;
        *)   log ERROR "Upload of '$filename' failed (HTTP $http_code): $response"; return 1 ;;
    esac
}

log INFO "Watching '$WATCH_DIR', uploading to '$IMMICH_URL'..."

# close_write: file fully written; moved_to: file moved/renamed into the directory
while IFS='|' read -r dir event filename; do
    # Skip temp/hidden files (e.g. "#8995052", ".foo.tmp")
    [[ "$filename" == [#.]* ]] && continue
    # Only react to image/video files
    case "${filename,,}" in
        *.png|*.jpg|*.jpeg|*.webp|*.heic|*.gif|*.mp4|*.mov|*.mkv) ;;
        *) continue ;;
    esac

    log INFO "New file appeared: ${dir}${filename} (event: $event)"
    upload_file "${dir}${filename}"
done < <(inotifywait -m -q -e close_write -e moved_to --format '%w|%e|%f' "$WATCH_DIR")
