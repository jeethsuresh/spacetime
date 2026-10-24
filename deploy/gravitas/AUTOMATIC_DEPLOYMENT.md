# Automatic deployment to Gravitas

Successful pushes to `main` test and publish an immutable image, then deploy that digest to the `spacetime` namespace and verify rollout, the deployed image, and public HTTPS. Pull requests run checks without deploying. Deployments are serialized and are not cancelled mid-release.

The administrator applies `ci-access.json` once, provisions the namespace's `github-deployer` credential as the `gravitas` GitHub environment secret `GRAVITAS_KUBECONFIG`; successful main pushes deploy automatically. The credential has no application Secret or cross-namespace permissions. Cluster administrator credentials must never be stored in GitHub. Rotate the dedicated credential through the same secure setup process; do not commit it or put it in command arguments or logs.

The application Secret, persistent data, shared ingress controller and TLS infrastructure are managed separately. The release script preserves the existing one-replica deployment strategy and verifies the cluster API endpoint before applying application resources. Failed checks or failed rollout/HTTPS verification fail the workflow; database downgrades are not performed automatically.

The declared application manifests are authoritative: server-side apply transfers conflicting fields from historical manual releases to `gravitas-deploy`, including the container image. Make future application configuration changes in these manifests. Namespace/RBAC and runtime Secrets are excluded from the rendered release, and PVC contents are never modified by apply.

If the user explicitly requests an incident pause, disable the deployment workflow in GitHub Actions and re-enable it when the incident is resolved. To deploy or roll back manually, run `deploy/gravitas/deploy.sh` with a tested, schema-compatible image digest and the intended Kubernetes context. Appstore CI sets `KUBE_CONTEXT=gravitas`; other manual use defaults to the existing administrator context.
