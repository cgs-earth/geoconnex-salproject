#!/bin/bash
#
# Startup script of the ephemeral build VM (Container-Optimized OS). Runs the
# job image, which does sal build and sal upload, then deletes this VM whatever
# happened. If this script never gets that far, the VM's max run duration
# deletes it anyway (see google_compute_instance_template.build).
#
# The work directory and Docker's storage are on the VM's boot disk, not in
# memory, so the size of the build is bounded by the disk, not by RAM.
#
# Settings arrive as instance metadata attributes: image, bucket,
# include-sitemaps, exclude-sitemaps, service-url.
set -uo pipefail

MD=http://metadata.google.internal/computeMetadata/v1
md() { curl -fsS -H 'Metadata-Flavor: Google' "$MD/$1"; }
attr() { md "instance/attributes/$1" 2>/dev/null || true; }
log() { printf '==> %s\n' "$*"; }

NAME="$(md instance/name)"
ZONE="$(md instance/zone | awk -F/ '{print $NF}')"
PROJECT="$(md project/project-id)"

self_destruct() {
	log "deleting this VM ($NAME)"
	local token
	token="$(md instance/service-accounts/default/token | sed -E 's/.*"access_token":"([^"]+)".*/\1/')"
	curl -fsS -X DELETE -H "Authorization: Bearer $token" \
		"https://compute.googleapis.com/compute/v1/projects/$PROJECT/zones/$ZONE/instances/$NAME" >/dev/null \
		|| log "could not delete the VM; the max run duration will"
}
trap self_destruct EXIT

IMAGE="$(attr image)"
BUCKET="$(attr bucket)"
registry="${IMAGE%%/*}"

export HOME=/var/tmp/home
mkdir -p "$HOME"
docker-credential-gcr configure-docker --registries="$registry" >/dev/null

B=/mnt/stateful_partition/build
rm -rf "$B"
mkdir -p "$B/work" "$B/docker"

# COS mounts the stateful partition noexec. The inner Docker daemon uses the vfs
# storage driver, whose container root filesystems are plain directories under
# /var/lib/docker, so nothing in a container (not even /bin/sh) could run.
log "stateful partition before: $(grep ' /mnt/stateful_partition ' /proc/mounts)"
mount -o remount,exec,suid /mnt/stateful_partition || log "could not remount the stateful partition exec"
log "stateful partition after:  $(grep ' /mnt/stateful_partition ' /proc/mounts)"

log "pulling $IMAGE"
docker pull "$IMAGE" || exit 1

log "running the build ($(df -h "$B" | awk 'NR==2{print $4}') free on disk)"
docker run --rm --privileged --network host --log-driver=gcplogs \
	-v "$B/work:/work" -v "$B/docker:/var/lib/docker" \
	-e BUCKET="$BUCKET" \
	-e INCLUDE_SITEMAPS="$(attr include-sitemaps)" \
	-e EXCLUDE_SITEMAPS="$(attr exclude-sitemaps)" \
	-e SERVICE_URL="$(attr service-url)" \
	-e WORK_DIR=/work/project \
	"$IMAGE"
status=$?
log "build exited with status $status"
exit "$status"
