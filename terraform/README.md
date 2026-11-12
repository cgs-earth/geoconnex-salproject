# Deploying geoconnex-salproject on Google Cloud

Started from `sal terraform`, then changed so the graph is built on Google Cloud. It creates:

- a Cloud Storage bucket holding the built data product (`sal upload` writes it);
- an Artifact Registry repository with two images, built from the `Dockerfile` in the project root;
- an **instance template** for an **ephemeral Compute Engine VM**. `make job-run` creates a VM from it;
  the VM runs `sal build` on `data/geoconnex.ttl`, which declares the `geoconnex-salmodule` harvester
  task, then `sal upload`s the result to the bucket, asks the service for a new revision, and deletes
  itself. Compute Engine also deletes it after `build_timeout_seconds` whatever it is doing;
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

- **The build runs on a VM, not in Cloud Run.** Cloud Run's filesystem is in memory, so a build there
  needs the whole working copy of the table, Docker's images and DuckDB to fit in one memory limit
  (32Gi at most). The VM works on its boot disk (`build_disk_size_gb`, 500 by default, deleted with the
  VM), so only DuckDB needs memory (`build_machine_type`).
- **The VM runs the job image in a privileged container** with its own Docker daemon, because `sal build`
  runs a SAL module by building and running its container. The work directory and Docker's storage are
  on the VM's disk. The VM gets an ephemeral external IP so it can reach the Geoconnex catalog and the
  vocabulary publishers; `build_network` / `build_subnetwork` choose the network (the `default` network
  must exist, or name another).
- **Logs.** The container logs to Cloud Logging (`resource.type="gce_instance"`, label `instance_name`);
  `make job-run` prints a link. The VM is gone afterwards, so that is where to see whether a build
  succeeded.
- **Stale data.** `sal upload` never deletes objects, so the job empties the bucket after a successful
  build and before uploading, so that nothing from an earlier build is served.
- **Service memory.** Each service instance still holds a full copy of the table in `memory`, because
  Cloud Run's filesystem is in memory. About 9 GB of compressed JSON-LD is harvested, so size it from a
  real run, and drop big sitemaps with `exclude_sitemaps` if needed
  (`usgs:national_geologic_map` is over half of it).
- **Cold start.** A service instance copies the whole data product before it listens;
  `startup_failure_threshold` (10 seconds each) bounds how long that may take. Keep `min_instances = 1`
  if cold starts matter.
- `terraform.tfvars` sets `with_ui = true`, whose `/api/sql` runs arbitrary DuckDB statements on a
  public service. Remove it unless that is intended.
- Terraform ignores the service's `data-version` label; the job sets it to force a new revision.

## Vocabularies

`sal build` validates against each vocabulary the project uses. `purl.org` (the `dcterms` vocabulary,
hosted by the Internet Archive) timed out from Cloud Run, so the job image is built with sal's seeded
vocabularies: at image build time (Cloud Build's network), `sal init` stores 16 common vocabularies
(schema.org, dcterms, geosparql, ...) in `/app/seed`, and the job copies them into `.sal/data/blobs`
before building. They are stored, not pinned; the build pins the ones the data actually uses, without
fetching them. A vocabulary outside that list is still fetched, with retries.

The build's `.sal/config.jsonld` (the pins) is uploaded beside the data, and the service reads it from
there to list the vocabularies in the UI. A bucket uploaded before that existed serves fine but lists
only the built-in vocabularies, and the service logs a warning, until the next `make job-run`.
Refreshing the vocabularies is just `make images`.
