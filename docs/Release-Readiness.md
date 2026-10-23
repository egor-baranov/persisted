# Release readiness

Persisted is a development preview. Automated checks do not establish that every window manager, display, or macOS version behaves correctly with the native integration.

## Code safeguards

- Library reads, writes, and exports enforce the same 25 MB encoded-size limit. An oversized edit is rejected before changing the active library or either saved file. A rejected capture or import keeps its draft available.
- Desktop restoration checks runtime support before creating desktops, assigning windows, or activating desktops. Unsupported systems can still restore window positions and sizes. Desktop-dependent edits remain protected from automatic learning until a successful supported restore.
- The experimental desktop movement integration currently targets macOS 26. Availability also depends on the system interfaces present. Earlier and future macOS versions keep their desktops unchanged. The rest of the app targets macOS 14 or later.
- Local build and release tools share the build directory, version, build number, and minimum macOS version. Website packaging selects a specific app and derives its metadata rather than assuming release status.

## Automated verification

Run `./Scripts/test.sh` from the source directory. The 23 October 2026 run passed 254 Swift tests across 14 suites and 10 release-tooling tests, including save-size boundaries and backup preservation, unsupported desktop restoration and undo, editing protection, cancellation, and Auto behavior with simulated displays and windows. Tooling tests use temporary fixtures and fake signing commands; they do not sign or submit software.

`swift build -c release` also passed on 23 October 2026. Full Xcode build and test commands are documented in the main README. This verification did not replace the running app or republish the downloadable archives.

## Native verification still required

Before public distribution, test the exact candidate application on supported Mac and macOS configurations:

1. Pass `./Scripts/integration-check.sh` with Accessibility granted to the candidate. The checker only manipulates its bundled test fixture and returns those windows to their original positions.
2. Verify desktop creation, window reassignment, active-desktop restoration, exclusions, and Undo. Keep ordinary windows, full-screen Spaces, and windows assigned to all desktops distinct.
3. Exercise Auto across laptop/external-display changes, reconnects, sleep/wake, and permission revocation. Confirm failed or incomplete operations do not overwrite saved arrangements.
4. Test installation, first launch, Accessibility association across an update, and launch at login using the intended distribution build.

The previous controlled native checker stopped because Accessibility was unavailable; this is not a passing native restore test. Desktop movement and physical Auto transitions do not yet have a recorded passing acceptance run. The full scenarios are in [Manual smoke tests](Manual-Smoke-Tests.md).

## Distribution artifact

The website's `downloads/manifest.json` records the selected app's version, build number, minimum macOS version, architectures, signature type, notarization verification, and archive hashes. A valid local signature alone does not establish Developer ID or Gatekeeper approval. Production credentials and a completed signed/notarized distribution workflow remain separate from these code checks.
