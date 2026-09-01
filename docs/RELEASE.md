# Releasing the macOS client

A semantic version tag publishes a matched client and local-agent runtime:

- `ConnectOnionMacClient-<version>.dmg` plus its SHA-256 checksum on GitHub;
- `ghcr.io/openonion/oochat-macos-agent:<version>` for both `linux/amd64` and
  `linux/arm64`, plus the matching major/minor and `latest` tags.

The DMG is ad-hoc signed and is not Apple-notarized. This is a GitHub source
distribution, not a Mac App Store release.

## Prepare

1. Increase `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in the Xcode
   project.
2. Change `ConnectOnionDockerImage` in `ConnectOnionMacClient/Info.plist` to the
   exact same version, for example
   `ghcr.io/openonion/oochat-macos-agent:1.0.1`.
3. Update release-facing documentation, push the commit to `main`, and wait for
   Basic CI and the pre-publication audit to pass.
4. Confirm the GHCR package is public. The release workflow logs out and pulls
   the tagged image anonymously before it builds the DMG; a private package
   therefore blocks publication rather than shipping a client that cannot pull
   its runtime.

## Publish

For version `1.0.1`:

```bash
git tag v1.0.1
git push origin v1.0.1
```

The workflow refuses a malformed tag, a tag that differs from
`MARKETING_VERSION`, or an `Info.plist` image that differs from the tag. Before
publishing it reruns the inherited-data audit, builds the multi-architecture
image, verifies anonymous pull access, and runs the Swift release tests. Only
then does it archive the app, create the DMG/checksum, and create the GitHub
Release. Prerelease tags such as `v1.1.0-rc.1` produce prerelease Releases.

## Manual workflow runs

A manual run builds and pushes only a commit-addressed `sha-*` agent image. It
does not create a DMG or GitHub Release because there is no immutable release
tag to bind them to.

## If a release fails

The GitHub Release is the last step. A failed earlier gate leaves the tag and
diagnostic Actions run but no release. Fix the problem and use the next patch
version; never move a tag after consumers may have fetched it.
