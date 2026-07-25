# macOS Release Acceptance

ADR 0008 requires a Developer ID signed, Hardened Runtime enabled, notarized
DMG that launches without a source checkout. Passing the development ad-hoc
bundle smoke is necessary but is not release evidence.

## One-time signing setup

Install a `Developer ID Application` identity in the login Keychain. Store
notary credentials in Keychain with Apple's native tool; do not place the
Apple ID password or App Store Connect private key in this repository or a
shell history entry.

```bash
xcrun notarytool store-credentials kubecode-notary
```

The stored profile may use an Apple ID app-specific password or App Store
Connect API key. The release script receives only the Keychain profile name.

## Build and notarize

```bash
KUBECODE_CODESIGN_IDENTITY="Developer ID Application: Name (TEAMID)" \
KUBECODE_NOTARY_PROFILE="kubecode-notary" \
  scripts/release-apple-dmg.sh
```

The pipeline performs these gates in order:

1. Build the Universal app and sign every nested Mach-O before generating the
   Runtime checksum manifest.
2. Seal the containing app with Hardened Runtime and the minimal explicit
   entitlement set, then perform strict signature verification.
3. Submit a ZIP of the app to Apple, require an `Accepted` result, staple the
   app, and run Gatekeeper assessment.
4. Create and sign the install DMG, submit it separately, require an `Accepted`
   result, staple it, and run Gatekeeper assessment.
5. Mount the DMG read-only and run the standalone Runtime smoke directly from
   the mounted app with isolated home, state, workspace, and system-only PATH.

Artifacts are written to `dist/apple/releases/`. The script stops on an
invalid signature, non-accepted notarization result, failed staple validation,
Gatekeeper rejection, checksum mismatch, Runtime protocol failure, or a private
Team MCP route incorrectly protected by the desktop client Bearer middleware.

The offline contract test uses no credentials and must pass on every change to
the release scripts:

```bash
scripts/test-apple-release-pipeline.sh
```

That command separately rejects invalid App and DMG notarization results,
checks sign/staple/validate/Gatekeeper ordering, and runs
`test-apple-dmg-smoke.sh`. The nested smoke contract proves the release DMG is
mounted read-only, contains the `/Applications` install link, validates the
mounted App, runs the standalone bundle smoke, and detaches on both success and
invalid-layout failure. Tool injection exists only for this offline contract;
production defaults remain the system `codesign`, `xcrun`, `spctl`, and
`hdiutil` binaries.

## Clean-machine matrix

Copy the notarized DMG, not the repository or an unpacked app, to each target.
The machine must not have either Kubecode repository. Record the DMG SHA-256,
submission IDs, OS build, architecture, and tester for every row.

| Host | Architecture | Gatekeeper launch | Local Runtime | Project + terminal | Evidence |
| --- | --- | --- | --- | --- | --- |
| macOS 26 | arm64 | Pending | Pending | Pending | Pending |
| macOS 26 | x86_64 | Pending | Pending | Pending | Pending |

For each row:

1. Open the DMG in Finder, drag Kubecode to Applications, eject the DMG, and
   launch the installed app normally without using `xattr` or bypassing
   Gatekeeper.
2. Confirm the Local Server becomes ready, the three Runtime Agent descriptors
   appear, and diagnostics contain no source-checkout paths.
3. Register a temporary local Project through `NSOpenPanel`, open a regular
   terminal, run `pwd`, and confirm it starts in that Project.
4. Quit through the native application menu, confirm no app-owned Local Runtime
   or SSH/tunnel process remains, then relaunch and confirm the Server profile
   and Project restore. Unregister the Project and verify its directory remains
   intact. An HTTPS-attached-only window must quit without a local Runtime
   shutdown warning.

Provider CLIs are intentionally not bundled. Agent execution on a clean host
requires the corresponding user-installed CLI; its absence must produce a
copyable diagnostic rather than blocking Local Runtime startup.
