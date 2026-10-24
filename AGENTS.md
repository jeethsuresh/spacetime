# Agent instructions

## Pull requests and customer safety

Merging to `main` ships to customers automatically. Shipping bad code to customers is unacceptable. Every pull request must be well-tested before merge.

- Work on a branch and review the final diff before merging.
- Run the relevant tests, analysis/lint, builds, and integration or smoke checks for the changed behavior using the repository's pinned production toolchain. Exercise affected user flows and meaningful failure paths; add regression coverage where it verifies the fix.
- Wait for all required CI checks to pass on the exact final PR commit. After further edits or conflict resolution, rerun the affected checks. Do not merge while required checks are failing, unfinished, or skipped unexpectedly, and do not disable or weaken checks to get a merge through.
- Record what was tested and the results in the PR description. A successful compilation alone does not establish that changed behavior works. Documentation-only changes require accurate instructions, valid referenced commands/paths, and applicable CI.

## Repository validation

Production CI is [.github/workflows/gravitas.yml](.github/workflows/gravitas.yml). It runs the Docker `backend-test` and `frontend-test` targets and smoke-tests the restricted runtime container. Validate affected calendar, sync, recurrence, offline persistence, notification, and authentication behavior when changing those areas. Use the workflow's pinned Flutter SDK.

## Automatic backend deployment

Every successful push to `main` automatically builds and deploys the verified backend/web image to https://spacetime.gravitas.cool. Publishing an image alone is not release completion. Preserve the deployment job's dependency on all test/build prerequisites, its main-branch restriction, immutable image digest, namespace-scoped `gravitas` environment, rollout checks, and public HTTPS verification in [.github/workflows/gravitas.yml](.github/workflows/gravitas.yml). Do not make normal releases require a separate opt-in variable or manual deployment step. Only pause automatic deployment when the user explicitly requests it.

## Automatic Android publishing

Increase both the stable version and Android version code for a new release. A push to `main` with that version must automatically test, sign with the original permanent key, verify, and publish the stable GitHub release and its signed APK/checksums. Confirm the Releases page and APK download work without signing in and that Private Store discovers the new version for updates. A draft release or Actions artifact alone is not completion. Preserve the package, certificate and asset naming expected by Private Store; use the main-only GitHub signing environment. See [ANDROID_RELEASES.md](ANDROID_RELEASES.md).
