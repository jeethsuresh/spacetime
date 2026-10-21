# Gravitas deployment

Spacetime is served at https://spacetime.gravitas.cool. The Flutter bundle and Go sync/invitation/CalDAV server share one image and origin. Opening the calendar does not require an account; signing in and synchronizing remain explicit actions.

The deployment uses the existing `do-tor1-gravitas-k8s-services` DigitalOcean cluster, `spacetime` namespace, a ClusterIP service, and the shared Traefik ingress/load balancer. The RSS/Office deployment owns shared ingress, DNS, and the wildcard TLS certificate. This application does not install another ingress controller, load balancer, DNS provider, or certificate issuer.

`bootstrap.json` creates the restricted namespace and namespace-scoped GitHub deployment role. An administrator applies it once. `resources.json` defines a 5Gi `do-block-storage-retain` PVC, one replica with `Recreate`, health probes, a non-root container with a read-only root filesystem, equal CPU/memory requests and limits, and a network policy admitting only Traefik traffic. The application needs no outbound network access. Database files are on `/data`, never in the image or repository. No demo accounts are seeded.

`Dockerfile` pins the existing Flutter SDK revision and includes a Go runtime with embedded time-zone data. GitHub Actions runs both test suites, builds `linux/amd64`, publishes a commit-tagged image to GHCR, and verifies the restricted runtime. Deployments use its immutable `sha256` digest. GHCR must permit anonymous pulls or the namespace must have a separately provisioned read-only image-pull credential.

For manual deployment, select the correct context and run:

```sh
kubectl --context do-tor1-gravitas-k8s-services apply -f deploy/gravitas/bootstrap.json
deploy/gravitas/deploy.sh ghcr.io/jeethsuresh/spacetime@sha256:IMAGE_DIGEST
```

Account creation requires an invite key. Before deploying, an administrator provisions `spacetime-registration` in the `spacetime` namespace, with the expected key in its `invite-key` field. Use an existing protected file containing only the key (no trailing newline); never commit its value or pass it as a command-line literal:

```sh
kubectl --context do-tor1-gravitas-k8s-services -n spacetime create secret generic spacetime-registration \
  --from-file=invite-key=/secure/path/registration-invite-key \
  --dry-run=client -o json | kubectl --context do-tor1-gravitas-k8s-services apply --server-side --field-manager=spacetime-secrets -f -
```

The deployment injects this Secret as `REGISTRATION_INVITE_KEY`. The reference is optional so a missing Secret disables only registration (HTTP 503), leaving existing sign-in, sync and CalDAV available. Missing or incorrect submitted keys return HTTP 403 before creating an account or session. The key is requested only on the registration form and is never stored by the client. Rotate the Secret and restart the deployment to load a new key; normal sign-in never requires it. The GitHub deployment role cannot read or modify the Secret.

The script checks the exact cluster API address before applying resources. `smoke.py` validates HTTPS, health, the Flutter JavaScript and bundled CanvasKit renderer, unauthenticated API/CalDAV protection, cross-origin rejection, and rejection of missing/incorrect registration keys. It expects the server's registration key to be configured. Its checks create no accounts or events.

Automatic deployment from `main` requires the GitHub `gravitas` environment secret `GRAVITAS_KUBECONFIG` containing only this namespace's deployment credential, plus repository variable `GRAVITAS_DEPLOY_ENABLED=true`. Never put cluster administrator credentials in GitHub. The deployment role cannot read application Secrets or operate in another namespace. Rotate its credential before expiry. Until configured, Actions still builds and tests images while deployment remains manual.

The bbolt database has one writer: do not increase replicas or use a rolling update. A retained PVC protects against accidental claim deletion but is not a backup. Before destructive maintenance, stop the deployment and take a DigitalOcean volume snapshot or copy `/data/spacetime.db` while the server is stopped; restore to a separate claim before replacing production data. Do not copy a live bbolt file. Restore service afterward with the recorded image digest and the existing claim. Rollback uses an earlier tested image digest with the same retained PVC; inspect schema compatibility before downgrading.
