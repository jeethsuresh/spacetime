# Private Store release workflow

The optional `store-release.yml` workflow builds a signed APK from `main` and creates a draft GitHub release. Existing release processes remain available. Increase the version name and build number in `pubspec.yaml` before running it. Review and publish the draft to make it available to the private store. Existing release tags are not overwritten.

Configure the GitHub environment `android-release` with `RELEASE_KEYSTORE_BASE64`, `RELEASE_STORE_PASSWORD`, `RELEASE_KEY_PASSWORD`, and `RELEASE_KEY_ALIAS`. Use this app's existing signing key; do not rotate it. No signing material has been uploaded by adding the workflow. Spacetime uses alias `spacetime-release`.

The workflow analyzes/tests with the repository's existing Flutter SDK version, verifies the signed APK's package, version and established certificate, then attaches the APK and SHA256SUMS to a draft release. The private store separately re-verifies APK signatures and pins before serving downloads. Published stable releases trigger ingestion through a signed GitHub webhook or the next polling interval.

Package: `com.jeethsuresh.spacetime`.
