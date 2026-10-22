# Gravitas deployment

Spacetime is served at https://spacetime.gravitas.cool. The Flutter bundle and Go sync/invitation/CalDAV server share one image and origin. The web app reuses an available Gravitas browser session. Signed-out visitors can dismiss the first-open login modal and continue offline; Settings retains login and Gravitas registration buttons. Connected accounts autosync after login and each saved calendar operation while the app is visible, with manual Sync now available. Incoming changes also refresh hourly. Hidden tabs and paused apps start no sync work; returning syncs queued operations. Transient failures use bounded foreground retry backoff. Web login and Settings hide server addresses and use the app origin.

The deployment uses the existing `do-tor1-gravitas-k8s-services` DigitalOcean cluster, `spacetime` namespace, a ClusterIP service, and the shared Traefik ingress/load balancer. The RSS/Office deployment owns shared ingress, DNS, and the wildcard TLS certificate. This application does not install another ingress controller, load balancer, DNS provider, or certificate issuer.

`bootstrap.json` creates the restricted namespace and namespace-scoped GitHub deployment role. An administrator applies it once. `resources.json` defines a 5Gi `do-block-storage-retain` PVC, one replica with `Recreate`, health probes, a non-root container with a read-only root filesystem, equal CPU/memory requests and limits, and a network policy admitting only Traefik traffic. Egress is limited to cluster DNS and Traefik's private TLS port for IAM; arbitrary outbound connections remain denied. Database files are on `/data`, never in the image or repository. No demo accounts are seeded.

Gravitas login is enabled by `GRAVITAS_ISSUER=https://gravitas.cool`, `PUBLIC_URL=https://spacetime.gravitas.cool` and `GRAVITAS_GATEWAY_ADDR=traefik.traefik.svc.cluster.local:443`. Register the app-side initiation URL `/auth/gravitas/start` in the Gravitas service catalog if a dashboard launch link is desired. The exact callback is `/auth/gravitas/callback`; it accepts only state-bound one-use flows. IAM must advertise `browser_initiation_endpoint` at `/.well-known/iam-configuration` and support username-less `/oauth/start`, including `prompt=none` with state-bound `login_required` or `consent_required` errors. Do not enable this deployment before the IAM protocol rollout is complete.

The app pins issuer and all discovery endpoints to the configured HTTPS origin. Server-side connections use the private ingress address while preserving certificate and hostname verification. PKCE verifiers and pending browser bindings live in bbolt for ten minutes and survive a pod replacement. Code exchange and profile fetch happen only during login; IAM access/refresh tokens are not persisted or exposed to Flutter. The app requests only `profile.name` and maps `(issuer, sub)` to an independent calendar account. Existing local accounts are not implicitly linked by name. Secure `__Host-` cookies prevent sibling subdomains from planting app sessions. Older browser cookies need one new sign-in when enabling SSO; bearer-token clients remain compatible.

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
