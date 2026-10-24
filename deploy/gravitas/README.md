# Gravitas deployment

Spacetime is served at https://spacetime.gravitas.cool. The Flutter bundle and Go sync/invitation/CalDAV server share one image and origin. The web app reuses an available Gravitas browser session. Signed-out visitors can dismiss the first-open login modal and continue offline; Settings retains login and Gravitas registration buttons. Connected accounts autosync after login and each saved calendar operation while the app is visible, with manual Sync now available. Incoming changes also refresh hourly. Hidden tabs and paused apps start no sync work; returning syncs queued operations. Transient failures use bounded foreground retry backoff. Web login and Settings hide server addresses and use the app origin.

The deployment uses the existing `do-tor1-gravitas-k8s-services` DigitalOcean cluster, `spacetime` namespace, a ClusterIP service, and the shared Traefik ingress/load balancer. The RSS/Office deployment owns shared ingress, DNS, and the wildcard TLS certificate. This application does not install another ingress controller, load balancer, DNS provider, or certificate issuer.

`bootstrap.json` creates the restricted namespace and namespace-scoped GitHub deployment role. An administrator applies it once. `resources.json` defines a 5Gi `do-block-storage-retain` PVC, one replica with `Recreate`, health probes, a non-root container with a read-only root filesystem, equal CPU/memory requests and limits, and a network policy admitting only Traefik traffic. Egress permits cluster DNS, Traefik's private TLS port for IAM, and public HTTPS on TCP 443/8443 for server-owned calendar sources. Private, loopback, link-local, metadata and reserved ranges remain excluded from the public rule. The source HTTP client additionally filters resolved addresses and verifies TLS; other source ports require an explicit policy change. Database files are on `/data`, never in the image or repository. No demo accounts are seeded.

Gravitas login is enabled by `GRAVITAS_ISSUER=https://gravitas.cool`, `PUBLIC_URL=https://spacetime.gravitas.cool` and `GRAVITAS_GATEWAY_ADDR=traefik.traefik.svc.cluster.local:443`. Register the app-side initiation URL `/auth/gravitas/start` in the Gravitas service catalog if a dashboard launch link is desired. The exact callback is `/auth/gravitas/callback`; it accepts only state-bound one-use flows. IAM must advertise `browser_initiation_endpoint` at `/.well-known/iam-configuration` and support username-less `/oauth/start`, including `prompt=none` with state-bound `login_required` or `consent_required` errors. IAM must also advertise `session_check_endpoint` and return `session_check_token`, `session_check_expires_in`, and `session_id` during code exchange. Store a persistent 32-byte base64 key in Secret `spacetime-gravitas/session-key`; deployment injects it as `GRAVITAS_SESSION_KEY`. Configured Gravitas authentication always checks the browser family on every protected request. Missing encryption configuration fails startup; there is no legacy federated fallback. Foreground clients also check every 15 seconds and on resume. Do not deploy before the coordinated IAM protocol rollout is ready.

The app pins issuer and all discovery endpoints to the configured HTTPS origin. Server-side connections use the private ingress address while preserving certificate and hostname verification. PKCE verifiers and pending browser bindings live in bbolt for ten minutes and survive a pod replacement. Code exchange and profile fetch happen only during login; IAM access/refresh tokens are not persisted or exposed to Flutter. The app requests only `profile.name` and maps `(issuer, sub)` to an independent calendar account. Existing local accounts are not implicitly linked by name. Secure `__Host-` cookies prevent sibling subdomains from planting app sessions. Older browser cookies need one new sign-in when enabling SSO; bearer-token clients remain compatible. A confirmed app-session 401 during foreground sync, or a foreground resume check returning 401, can start a passive PKCE login when the shared `__Secure-gravitas_signed_in=1` cookie is present. The auth-config endpoint exposes only this untrusted boolean with `Cache-Control: no-store`; the marker never authorizes API or CalDAV access. Redirect attempts are limited to one per two minutes per tab across reloads (using session storage, so separate tabs do not block each other), stop when hidden or explicitly disconnected, and never open interactive consent from the recovery handler. Pending edits and account-scoped invite responses survive expiry and reconnection. IAM must deploy its rotating, host-only refresh session and marker contract before enabling this recovery release.

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

The script checks the exact cluster API address and validates all resources with a server dry-run before applying them. `smoke.py` validates HTTPS, health, the Flutter JavaScript and bundled CanvasKit renderer, unauthenticated API/CalDAV protection, cross-origin rejection, and rejection of missing/incorrect registration keys. It expects the server's registration key to be configured. Its checks create no accounts or events.

Automatic deployment from `main` requires the GitHub `gravitas` environment secret `GRAVITAS_KUBECONFIG` containing only this namespace's deployment credential. Successful main pushes automatically deploy after the checks pass. Never put cluster administrator credentials in GitHub. The deployment role cannot read application Secrets or operate in another namespace. Rotate its credential before expiry. A missing or invalid deployment credential fails the release rather than completing an undeployed backend release.

The bbolt database has one writer: do not increase replicas or use a rolling update. A retained PVC protects against accidental claim deletion but is not a backup. Before destructive maintenance, stop the deployment and take a DigitalOcean volume snapshot or copy `/data/spacetime.db` while the server is stopped; restore to a separate claim before replacing production data. Do not copy a live bbolt file. Restore service afterward with the recorded image digest and the existing claim. Rollback uses an earlier tested image digest with the same retained PVC; inspect schema compatibility before downgrading.

## Private shared deployment tooling

The deployment job checks out `jeethsuresh/gravitas-deploy` at a full commit SHA,
using this repository’s read-only tooling key from the main-only `gravitas`
environment. `.gravitas/deploy.json` selects this app’s existing release script;
its migrations, manifests and public checks remain in this repository. The shared
action checks namespace permissions, exact image digest, readiness and HTTPS,
and removes its temporary kubeconfig on failure or success. Build/test jobs are
unchanged. Review a new tooling pin before updating it. New-app onboarding is
documented in the private tooling repository.
