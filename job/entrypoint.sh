#!/usr/bin/env bash
#
# Cloud Run job entrypoint: build the Geoconnex graph with sal and upload it.
#
#   1. start a Docker daemon (sal runs the geoconnex salmodule in a container)
#   2. create the sal project from the RDF baked into the image
#   3. sal build
#   4. sal upload to the bucket
#   5. ask the Cloud Run service for a new revision, whose instances copy the
#      new data from the bucket when they start
#
# Environment:
#   BUCKET              where to upload, e.g. gs://my-bucket/ (required)
#   REPO_URL            git remote sal derives the base IRI from
#   BUILD_MESSAGE       the snapshot message
#   INCLUDE_SITEMAPS    comma separated sitemap_ids; harvest only these (for test runs)
#   EXCLUDE_SITEMAPS    comma separated sitemap_ids to skip
#   DOCKER_HOST         use this daemon instead of starting one (e.g. a remote host)
#   DOCKERD_ARGS        extra dockerd flags
#   SERVICE_URL         Cloud Run Admin API URL of the service to roll (optional)
#   WORK_DIR            where the project is built (default /work)
set -euo pipefail

log() { printf '==> %s\n' "$*" >&2; }

: "${BUCKET:?BUCKET must be set, e.g. gs://my-bucket/}"
REPO_URL="${REPO_URL:-https://github.com/cgs-earth/geoconnex-salproject.git}"
BUILD_MESSAGE="${BUILD_MESSAGE:-Build the Geoconnex graph}"
WORK_DIR="${WORK_DIR:-/work}"
export HOME="${HOME:-/root}"

log "capabilities this job holds: $(awk '/^CapBnd:/{print $2}' /proc/self/status)"

start_dockerd() {
	local args=("$@")
	log "starting dockerd ${args[*]}"
	dockerd --add-runtime capfix=/usr/local/bin/runc-capfix --default-runtime=capfix \
		"${args[@]}" ${DOCKERD_ARGS:-} >/var/log/dockerd.log 2>&1 &
	DOCKERD_PID=$!
	for _ in $(seq 1 60); do
		if docker info >/dev/null 2>&1; then
			log "dockerd is up"
			return 0
		fi
		kill -0 "$DOCKERD_PID" 2>/dev/null || break
		sleep 1
	done
	log "dockerd did not come up; its log:"
	tail -n 40 /var/log/dockerd.log >&2 || true
	kill "$DOCKERD_PID" 2>/dev/null || true
	wait "$DOCKERD_PID" 2>/dev/null || true
	return 1
}

if [ -n "${DOCKER_HOST:-}" ]; then
	log "using the Docker daemon at $DOCKER_HOST"
else
	# vfs because overlayfs on the job's in-memory filesystem is not reliable.
	if ! start_dockerd --storage-driver=vfs; then
		log "retrying without iptables or the default bridge"
		if ! start_dockerd --storage-driver=vfs --iptables=false --ip6tables=false --bridge=none; then
			log "no Docker daemon could be started in this environment."
			log "set DOCKER_HOST to a reachable daemon, or run this build in Cloud Build."
			exit 1
		fi
		log "warning: containers have no network in this mode, so the module cannot reach the Geoconnex catalog"
	fi
fi

# Which vocabulary publishers can this job reach? Only logged, never fatal.
for url in http://purl.org/dc/terms/ https://schema.org/ http://www.opengis.net/ont/geosparql https://w3id.org/sal/salmodule; do
	log "egress check $url: $(curl -sS -m 15 -o /dev/null -L -w '%{http_code} in %{time_total}s' "$url" 2>&1 | tail -1)"
done

log "creating the sal project in $WORK_DIR"
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"
cp -R /app/project/. "$WORK_DIR/"
cd "$WORK_DIR"

# Test and partial runs: add the filters to the task without editing the repo.
if [ -n "${INCLUDE_SITEMAPS:-}" ] || [ -n "${EXCLUDE_SITEMAPS:-}" ]; then
	{
		for kind in INCLUDE EXCLUDE; do
			var="${kind}_SITEMAPS"
			[ -n "${!var:-}" ] || continue
			prop="$(echo "$kind" | tr 'A-Z' 'a-z')Sitemaps"
			vals=""
			IFS=',' read -ra ids <<<"${!var}"
			for id in "${ids[@]}"; do vals+="${vals:+, }\"$id\""; done
			printf '<HarvestGeoconnex> geoconnex:%s %s .\n' "$prop" "$vals"
		done
	} >>data/geoconnex.ttl
fi

git init -q -b main
git remote add origin "$REPO_URL"
git config user.email "geoconnex-sal-job@cgs-earth.org"
git config user.name "geoconnex sal job"
/app/sal init --no-skills --description "A representation of the Geoconnex graph as a SAL project"
# sal fetches each vocabulary the project uses from its publisher unless it has
# a pinned copy, and some publishers (purl.org, hosted by the Internet Archive)
# time out from Cloud Run. job/pins holds the pins and documents a local build
# made, so the build validates against those and needs no vocabulary downloads.
# See terraform/README.md to refresh them; vocabularies a pin does not cover are still
# fetched.
if [ -d /app/pins ]; then
	log "using the vocabulary pins baked into the image"
	cp /app/pins/config.jsonld .sal/config.jsonld
	mkdir -p .sal/data/blobs
	cp -R /app/pins/blobs/. .sal/data/blobs/
fi
git add -A
git commit -qm "Geoconnex SAL project"

log "sal build"
/app/sal build --message "$BUILD_MESSAGE" data/

log "sal upload to $BUCKET"
/app/sal upload --bucket "$BUCKET"

# A running instance keeps the copy it made when it started, so a new revision
# is what makes the service serve this build. Changing a label is enough to
# create one; terraform ignores that label. A failure here leaves the data
# uploaded, so it is a warning rather than a failed job.
if [ -n "${SERVICE_URL:-}" ]; then
	log "rolling a new revision of the service"
	token="$(curl -fsS -H 'Metadata-Flavor: Google' \
		http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token | jq -r .access_token)"
	if ! curl -fsS -X PATCH -H "Authorization: Bearer $token" -H 'Content-Type: application/json' \
		"$SERVICE_URL?updateMask=template.labels" \
		-d "{\"template\":{\"labels\":{\"data-version\":\"$(date -u +%Y%m%d-%H%M%S)\"}}}" >/dev/null; then
		log "warning: could not roll the service; deploy it by hand to pick up the new data"
	fi
fi
log "done"
