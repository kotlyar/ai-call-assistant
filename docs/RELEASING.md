# Release runbook

This project publishes macOS and Windows packages from the same immutable Git
tag. Only maintainers with release permission should follow these steps.

## 1. Prepare the tag

1. Update the version in `Info.plist` and the notes in `CHANGELOG.md`.
2. Run `swift test` and the Windows test suite before tagging.
3. Merge the release commit to `main`, confirm CI is green, then create and push
   an annotated `vMAJOR.MINOR.PATCH` tag.

## 2. Build macOS artifacts

On a trusted macOS machine at the tagged commit, run:

```bash
git switch --detach vMAJOR.MINOR.PATCH
AI_CALL_ASSISTANT_CODE_SIGN_IDENTITY="Developer ID Application: …" \
  ./Scripts/build-app.sh
shasum -a 256 dist/Callya.dmg dist/Callya.zip
```

`Scripts/build-app.sh` creates and verifies the universal `Callya.dmg` and
`Callya.zip`. A public distribution build should use Developer ID signing and
Apple notarization. If an ad-hoc build is published while the project is still
in preview, state that clearly in the release notes.

Create a draft release for the exact tag and attach the two verified macOS
artifacts:

```bash
gh release create vMAJOR.MINOR.PATCH \
  dist/Callya.dmg dist/Callya.zip \
  --draft --verify-tag --generate-notes
```

## 3. Attach the Windows artifact

Run the `Windows` workflow from the default branch and pass the existing release
tag as `release_tag`. The release job checks out that tag, verifies that `HEAD`
matches it, restores and tests the solution, builds the x64 ZIP, scans the
package for obvious credentials, and uploads the ZIP plus its SHA-256 file to
the draft release.

```bash
gh workflow run windows.yml --ref main -f release_tag=vMAJOR.MINOR.PATCH
gh run watch
```

## 4. Publish and verify

Download every asset from the draft release, verify the checksums, smoke-test
both applications on clean supported systems, and then publish the draft:

```bash
gh release edit vMAJOR.MINOR.PATCH --draft=false
```

Confirm that the stable `releases/latest/download/...` links in `README.md` and
the landing page resolve to the new assets.
