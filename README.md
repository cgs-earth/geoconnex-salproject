# geoconnex-salproject

The [Geoconnex](https://geoconnex.us) graph as a [SAL](https://cgs-earth.github.io/sal/) data product. The
[`geoconnex-salmodule`](https://github.com/cgs-earth/geoconnex-salmodule) harvests every feature's JSON-LD from
the Geoconnex STAC catalog, `sal build` writes it to an Iceberg triples table in a Cloud Storage bucket, and a
Cloud Run service serves it as a SPARQL endpoint.

- **Project:** [`data/geoconnex.ttl`](data/geoconnex.ttl) declares the harvester task. With no filters it
  harvests every sitemap.
- **Build:** an ephemeral Compute Engine VM runs `sal build` and `sal upload`, then rolls the service onto the new data and deletes itself.
  `sal build` runs the module in a container, so the job image starts its own Docker daemon.
- **Serve:** the service copies the bucket onto local disk when an instance starts, then runs `sal serve`.
  Cloud Run's filesystem is in memory, so the table counts against the service's memory.

## Deploy

Needs `gcloud` (logged in) and `terraform`. Set `project` in `terraform/terraform.tfvars`, then:

```sh
make registry    # Artifact Registry repository
make images      # build and push the job and service images
make infra       # bucket, build VM template, service accounts
make job-run     # build the graph and upload it
make apply       # create the service (it can't start until the bucket has data)
```

Every later `make job-run` rebuilds, uploads, and rolls the service. Check it with:

```sh
curl -G "$(terraform -chdir=terraform output -raw sparql_endpoint)" \
  -H 'Accept: application/sparql-results+json' \
  --data-urlencode 'query=SELECT (COUNT(*) AS ?n) WHERE { ?s ?p ?o }'
```

## Configuration

In `terraform/terraform.tfvars`; every variable is in `terraform/variables.tf`.

- `include_sitemaps` / `exclude_sitemaps`: comma separated sitemap IDs, such as `ref:dams,ref:mainstems`.
  `terraform.tfvars` currently sets a small test subset; delete the line for the full build.
- `build_machine_type` / `build_disk_size_gb`: the build VM, which works on its disk. `cpu` / `memory`: the service, which holds the table in memory.
- `min_instances`: `0` by default, so the service scales to zero and a cold start re-copies the bucket.
- `with_ui`: the UI's SQL endpoint runs arbitrary DuckDB statements, so turn it off on a public service if
  that matters.

More detail is in [`terraform/README.md`](terraform/README.md).

## Local use

Needs [`sal`](https://github.com/cgs-earth/sal) and Docker.

```sh
make validate
git add -A && git commit
make build MESSAGE="Build"
make serve        # http://localhost:8080
```
