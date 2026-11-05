# Two images from one file, picked with --target:
#
#   serve  the Cloud Run service. job/serve-entrypoint.sh copies the built data
#          product out of the bucket onto local disk, then runs sal serve.
#   job    the Cloud Run job (the default). sal, a Docker daemon for sal to run
#          the geoconnex salmodule on, and this project's RDF. `sal build` runs
#          a SAL module by building and running its container, so the daemon
#          lives in this image and job/entrypoint.sh starts it before building.
#
ARG SAL_IMAGE=ghcr.io/cgs-earth/sal:latest
FROM ${SAL_IMAGE} AS serve

RUN apt-get update && apt-get install -y --no-install-recommends curl jq \
    && rm -rf /var/lib/apt/lists/*
COPY job/serve-entrypoint.sh /app/serve-entrypoint.sh
RUN chmod +x /app/serve-entrypoint.sh
EXPOSE 8080
ENTRYPOINT ["/app/serve-entrypoint.sh"]


FROM ${SAL_IMAGE} AS job

# Docker CE from Docker's own apt repository rather than Debian's docker.io, so
# the daemon's API is new enough for the client sal links in. iptables is what
# dockerd uses to give the module container a route to the internet.
RUN apt-get update && apt-get install -y --no-install-recommends \
        curl gnupg iptables jq procps \
    && install -m 0755 -d /etc/apt/keyrings \
    && curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc \
    && echo "deb [signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian bookworm stable" \
        > /etc/apt/sources.list.d/docker.list \
    && apt-get update && apt-get install -y --no-install-recommends \
        docker-ce docker-ce-cli containerd.io \
    && rm -rf /var/lib/apt/lists/*

COPY data/ /app/project/data/
COPY job/pins/ /app/pins/
COPY job/runc-capfix /usr/local/bin/runc-capfix
COPY job/entrypoint.sh /app/entrypoint.sh
RUN chmod +x /app/entrypoint.sh /usr/local/bin/runc-capfix

ENTRYPOINT ["/app/entrypoint.sh"]
