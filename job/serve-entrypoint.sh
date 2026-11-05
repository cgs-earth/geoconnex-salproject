#!/usr/bin/env bash
#
# Cloud Run service entrypoint: copy the built data product from the bucket onto
# local disk, make that a minimal sal project, then serve it. Runs once per instance start, so a new revision (or
# a new instance) always starts from what the bucket holds at that moment.
#
# Cloud Run's filesystem is in memory, so the copy counts against the
# instance's memory limit. Nothing listens on 8080 until the copy is done.
#
# Environment:
#   BUCKET_NAME   the bucket sal upload wrote the data product to (required)
#   PROJECT_DIR   where the minimal sal project is made (default /project)
#   WITH_UI       set to 1 to pass --with-ui to sal serve
#   PARALLEL      concurrent downloads (default 16)
#   STORAGE_API / METADATA_URL  override the Google endpoints (for testing)
set -euo pipefail

: "${BUCKET_NAME:?BUCKET_NAME must be set}"
PROJECT_DIR="${PROJECT_DIR:-/project}"
DATA_DIR="$PROJECT_DIR/.sal/data"
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
rm -rf "$PROJECT_DIR"
mkdir -p "$DATA_DIR"
list_objects | tee /tmp/objects.txt | tr '\n' '\0' | xargs -0 -n1 -P "$PARALLEL" bash -c 'download "$1"' _
count="$(wc -l </tmp/objects.txt)"
if [ "$count" -eq 0 ]; then
	log "gs://$BUCKET_NAME is empty: run the build job first (make job-run)"
	exit 1
fi
log "copied $count files ($(du -sh "$DATA_DIR" | cut -f1))"

# sal upload to a bucket root keeps the layout of .sal/data:
#   <project>/triples/{metadata,data}   blobs/   stac/   config.jsonld
# Make that a sal project: sal finds the table through the git remote's name,
# and finds the pinned vocabularies (what the UI's Vocabularies tab lists) in
# .sal/config.jsonld, which the build job uploads beside the data; images
# older than that fall back to the pins baked into this one.
meta="$(find "$DATA_DIR" -type d -name metadata -not -path "$DATA_DIR/blobs/*" -not -path "$DATA_DIR/stac/*" \
	-exec sh -c 'ls "$1"/*.metadata.json >/dev/null 2>&1' _ {} \; -print | head -n1)"
if [ -z "$meta" ]; then
	log "no Iceberg table (a metadata/ directory with *.metadata.json) found under $DATA_DIR:"
	find "$DATA_DIR" -maxdepth 3 | head -n 40 >&2
	exit 1
fi
table="$(dirname "$meta")"
project_name="$(basename "$(dirname "$table")")"
log "serving $table"

cd "$PROJECT_DIR"
git init -q -b main
git remote add origin "https://github.com/cgs-earth/$project_name.git"
if [ -f "$DATA_DIR/config.jsonld" ]; then
	mv "$DATA_DIR/config.jsonld" .sal/config.jsonld
else
	log "no config.jsonld in the bucket; using the pins baked into the image"
	cp /app/pins/config.jsonld .sal/config.jsonld
fi

# sal upload wrote gs:// paths into the table's Iceberg metadata. Queries read
# the local copy anyway, but the UI's storage layout view follows those paths
# and has no credentials for the bucket (403). Point the copy at itself.
/app/sal rewrite --new-table-root "$table"

exec /app/sal serve ${WITH_UI:+--with-ui}
