# macOS beta releases

Beta builds go only to users who enable **Settings → About → Get beta versions**.
The stable feed (`personal/version.json`) is separate from the beta feed
(`personal/version-beta.json`). A GitHub prerelease label alone does not control
in-app updates.

## Versioning

The currently installed updater understands a single-letter prerelease suffix:
`1.1.6 < 1.2.0a < 1.2.0b < 1.2.0`. Use `1.2.0a` for the first 1.2.0 beta and
increment the build number for every build. Final 1.2.0 outranks every 1.2.0 beta.
Turning beta updates off stops future beta offers; it does not downgrade an
already installed beta.

## Prepare and publish

1. Update `release/macos-beta.json`. Run `swift test --package-path macos`.
2. Build with the existing release signing identity in `RS_SIGN_ID`:
   `RS_VERSION_JSON="$PWD/release/macos-beta.json" bash macos/build_app.sh`.
   Additional Swift flags may be passed to this script for isolated build environments.
3. Package the app: `bash macos/package_beta.sh /tmp/ns-beta-dist`.
   The script verifies the app signature and identifier, then verifies the DMG checksum.
4. Check the packaged version/build and source tree. Commit and push all source
   and release metadata; keep the worktree clean.
5. Publish: `python3 scripts/publish_macos_beta.py /tmp/ns-beta-dist/NormalSwitcher-1.2.0a.dmg`.

The publisher pins a prerelease to the pushed source commit, uploads to a draft,
checks GitHub's asset digest, publishes without changing Latest, and then writes
only the beta feed. It can resume an interrupted publication with matching
source and asset; it refuses to replace an existing published asset. It uses
`GH_TOKEN` or the existing Git credential helper and does not store credentials.

After publication, verify the public asset/download, both update feeds and the
release flags. Mirror the published beta feed into the development branch so
merging that branch cannot restore an inherited or deleted feed.

## Testing and promotion

Technical checks happen before beta publication. Beta testers then exercise
capture, task editing, clipboard paste focus, keyboard shortcuts, persistence,
upgrade and normal typing in actual applications. Offscreen tests and signature
checks do not establish that these interactions work on every supported macOS.

After the user's explicit approval for stable release, merge the tested changes,
build/sign the final version and use the stable publication process. A beta
publication must never write `release/macos.json`, `version.json` or mark itself
Latest. Keep the beta feed optional; clients always prefer a newer stable final.
