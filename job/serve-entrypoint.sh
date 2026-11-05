#!/usr/bin/env bash
#
# Cloud Run service entrypoint: copy the built data product from the bucket onto
# local disk, then serve it. Runs once per instance start, so a new revision (or
# a new instance) always starts from what the bucket holds at that moment.
#
# Cloud Run's filesystem is in memory, so the copy counts against the
# instance's memory limit. Nothing listens on 8080 until the copy is done.
#
# Environment:
#   BUCKET_NAME   the bucket sal upload wrote the data product to (required)
#   DATA_DIR      where to copy it (default /data)
#   WITH_UI       set to 1 to pass --with-ui to sal serve
#   PARALLEL      concurrent downloads (default 16)
#   STORAGE_API / METADATA_URL  override the Google endpoints (for testing)
set -euo pipefail

: "${BUCKET_NAME:?BUCKET_NAME must be set}"
DATA_DIR="${DATA_DIR:-/data}"
PARALLEL="${PARALLEL:-16}"
STORAGE_API="${STORAGE_API:-https://storage.googleapis.com}"
METADATA_URL="${METADATA_URL:-http://metadata.google.internal/computeMetadata/v1}"

log() { printf '==> %s\n' "$*" >&2; }

TOKEN="$(curl -fsS -H 'Metadata-Flavor: Google' \
	"$METADATA_URL/instance/service-accounts/default/token" | jq -r .access_token)"
export TOKEN BUCKET_NAME DATA_DIR STORAGE_API

list_objects() {
	local page="" url resp
	while :; do
		url="$STORAGE_API/storage/v1/b/$BUCKET_NAME/o?maxResults=1000&fields=items(name),nextPageToken"
		[ -z "$page" ] || url+="&pageToken=$page"
		resp="$(curl -fsS -H "Authorization: Bearer $TOKEN" "$url")"
		jq -r '.items[]?.name' <<<"$resp"
		page="$(jq -r '.nextPageToken // empty' <<<"$resp")"
		[ -n "$page" ] || break
	done
}

download() {
	local name="$1" dest="$DATA_DIR/$1"
	# object names are used as file names as they are, the way a FUSE mount
	# shows them; a name containing %3A stays %3A on disk
	case "$name" in */) return 0 ;; esac
	mkdir -p "$(dirname "$dest")"
	curl -fsS --retry 5 -H "Authorization: Bearer $TOKEN" \
		-o "$dest" "$STORAGE_API/storage/v1/b/$BUCKET_NAME/o/$(jq -rn --arg n "$name" '$n|@uri')?alt=media"
}
export -f download

log "copying gs://$BUCKET_NAME into $DATA_DIR"
rm -rf "$DATA_DIR"
mkdir -p "$DATA_DIR"
list_objects | tee /tmp/objects.txt | tr '\n' '\0' | xargs -0 -n1 -P "$PARALLEL" bash -c 'download "$1"' _
count="$(wc -l </tmp/objects.txt)"
if [ "$count" -eq 0 ]; then
	log "gs://$BUCKET_NAME is empty: run the build job first (make job-run)"
	exit 1
fi
log "copied $count files ($(du -sh "$DATA_DIR" | cut -f1))"

# sal serve --data finds the table, blobs/, stac/ and the project's pinned
# vocabularies (config.jsonld, which sal upload puts beside the data) itself.
exec /app/sal serve --data "$DATA_DIR" ${WITH_UI:+--with-ui}
