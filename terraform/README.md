# Deploying geoconnex-salproject on Google Cloud

Started from `sal terraform`, then changed so the graph is built on Google Cloud. It creates:

- a Cloud Storage bucket holding the built data product (`sal upload` writes it);
- an Artifact Registry repository with two images, built from the `Dockerfile` in the project root;
- a **Cloud Run job** (`geoconnex-salproject-sal-build`) that runs `sal build` on `data/geoconnex.ttl`,
  which declares the `geoconnex-salmodule` harvester task, then `sal upload`s the result to the bucket
  and asks the service for a new revision;
- a **Cloud Run service** that copies the bucket onto local disk when an instance starts and runs
  `sal serve` over the copy: `/sparql`, `/stac/catalog.json`, `/blobs`;
- a service account for each, with only the bucket access it needs.

## First deploy

The service cannot start until the job has put something in the bucket, so it is applied last.

```sh
# set project in terraform.tfvars, then
make registry                                     # Artifact Registry repository
make images                                       # Cloud Build builds and pushes the two images
make infra                                        # bucket, job, service accounts (no service yet)
make job-run                                      # build the graph and upload it (hours)
make apply                                        # now create the service
```

For a quick end-to-end check first, set `include_sitemaps = "ref:dams"` in `terraform.tfvars`,
`terraform apply -var deploy_service=false`, and `make job-run`; clear it for the full build.

After that, every `make job-run` rebuilds, uploads, and rolls the service onto the new data.

## Things to know

- **The job runs its own Docker daemon.** `sal build` runs a SAL module by building and running its
  container. Cloud Run jobs have no daemon, so `job/entrypoint.sh` starts `dockerd` in the job. This
  has only been tested with `docker run --privileged`, not on Cloud Run, whose containers are not
  privileged. If the job logs that no daemon could be started, point it at one with the `docker_host`
  variable, or run the same steps in Cloud Build.
- **Memory.** Cloud Run's filesystem is in memory. The job's working copy of the table, Docker's
  images, and DuckDB share `job_memory` (32Gi is the most a job gets), and each service instance
  holds a full copy of the table in `memory`. About 9 GB of compressed JSON-LD is harvested, so
  size both from a real run, and drop big sitemaps with `exclude_sitemaps` if needed
  (`usgs:national_geologic_map` is over half of it).
- **Cold start.** A service instance copies the whole data product before it listens;
  `startup_failure_threshold` (10 seconds each) bounds how long that may take. Keep `min_instances = 1`
  if cold starts matter.
- `terraform.tfvars` sets `with_ui = true`, whose `/api/sql` runs arbitrary DuckDB statements on a
  public service. Remove it unless that is intended.
- Terraform ignores the service's `data-version` label; the job sets it to force a new revision.

## Vocabulary pins

`sal build` validates against each vocabulary the project uses, and fetches any it hasn't pinned from
its publisher. `purl.org` (the `dcterms` vocabulary, hosted by the Internet Archive) timed out from
Cloud Run, so `job/pins/` holds the pins and documents (`config.jsonld` and `blobs/`) from a local
build, and the job copies them into place after `sal init`. This also fixes the vocabulary and
harvester versions the build uses. A vocabulary the pins don't cover is still fetched at build time.

To refresh them (new vocabularies, or a newer `geoconnex-salmodule`), build the job image, run it
locally with `docker run --privileged` and `-e BUCKET=file:///out -e INCLUDE_SITEMAPS=ref:dams`
(`mkdir /out` first; stop before `rm`), then copy `/work/.sal/config.jsonld` and
`/work/.sal/data/blobs` out of the stopped container into `job/pins/`.
