# Signed Android releases

Spacetime uses the same release process as the other Gravitas Android apps. Signing runs on GitHub-hosted runners; a local machine never needs the private key.

Increase both the stable version and Android version code in `frontend/pubspec.yaml`, then merge or push to `main`. **Signed Android release** automatically tests, builds, verifies and publishes the new version. An already published version is skipped. Existing tags, drafts and published assets are never overwritten. A lower version or non-increasing version code fails before signing.

The `android-release` GitHub environment is restricted to the `main` branch. It contains four encrypted secrets: `RELEASE_KEYSTORE_BASE64`, `RELEASE_STORE_PASSWORD`, `RELEASE_KEY_ALIAS`, and `RELEASE_KEY_PASSWORD`. Preserve the original key and certificate when restoring these secrets. They are loaded only after tests pass and removed before artifacts are uploaded; they are never committed or included in releases. Keep the protected original key backup separately.

The workflow can also run manually from `main`. Leave **publish_release** enabled to publish an unused version, or disable it to build and verify an artifact without changing releases. If publishing fails after uploading a draft, inspect that draft instead of overwriting it.

Every release includes the signed APK, `SHA256SUMS`, and `release-manifest.json` with the source commit, package, version/code, certificate and APK digest. GitHub's uploaded asset digests and sizes must match before the draft is published. `android-release.json` pins the app identity; the workflow pins its build tools and GitHub actions.

Package: `com.jeethsuresh.spacetime`. Permanent certificate SHA-256: `f5714ad3d2b3d82b283efd61b2d99f5eaad5ec9efe67b644a62efc79fec94582`.
