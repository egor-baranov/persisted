# Persisted

Persisted is a native macOS menu bar utility that saves application window arrangements and Mission Control desktop assignments for recognized display setups. Window placement uses public Accessibility APIs; experimental desktop support also uses private macOS Spaces APIs and Mission Control Accessibility controls. The app uses SwiftUI, AppKit, Core Graphics, ColorSync, IOKit, and ServiceManagement, and requires macOS 14 or later. Desktop capabilities depend on the macOS version and available system interfaces.

The menu bar panel is the main interface. It shows every saved layout across all display setups, with arrangement thumbnails, window, app, and captured-desktop counts, and individual Apply buttons. Save, rename, reorder, duplicate, update, import, export, configure shortcuts, manage display profiles, and schedule layouts without opening the management window. The application runs without a permanent Dock icon.

## Build and run

Install a Swift 6 toolchain through Xcode or the Xcode Command Line Tools, then run from this repository:

```sh
./Scripts/build-app.sh debug
open build/Persisted.app
```

The build script produces `build/Persisted.app` and the separate integration fixture `build/PersistedHarness.app`. Use `./Scripts/build-app.sh release` for an optimized local build. Quit both build-directory apps before building, and reopen them afterward. The script refuses to replace a running bundle and prepares signed, verified bundles in a staging directory before publishing them. Local builds use ad hoc signing; distribution signing is a separate step. `PERSISTED_BUILD_DIRECTORY` selects the bundle output directory and is shared by the build, release, website-packaging, and integration-check scripts. Version, build number, and minimum macOS version come from `Config/Base.xcconfig`.

For everyday use, copy the application to `/Applications`, launch that copy, and keep using that location. Keep a single running copy while testing. Launch at login uses the installed main application through `SMAppService.mainApp`.

You can also open `Persisted.xcodeproj` and use its shared Persisted and PersistedHarness schemes. With full Xcode selected:

```sh
xcodebuild -project Persisted.xcodeproj -scheme Persisted \
  -configuration Debug build CODE_SIGNING_ALLOWED=NO

xcodebuild -project Persisted.xcodeproj -scheme Persisted \
  -configuration Debug test CODE_SIGNING_ALLOWED=NO
```

The Swift package builds the same implementation:

```sh
swift build
./Scripts/test.sh
```

`Scripts/test.sh` runs isolated release-tooling tests, then supplies the Swift Testing framework search paths needed by Command Line Tools installations. Prefer the packaged `.app` for permission, menu bar, and launch-at-login checks; running an executable directly does not reproduce an installed application’s identity and lifecycle.

The default bundle identifier is `app.persisted.Persisted`, configured by `PERSISTED_BUNDLE_IDENTIFIER` in `Config/Base.xcconfig` or the same environment variable for the bundle script. Keep it stable across development builds. Changing the identifier, signing identity, or installed location can change macOS permission association. Ad hoc rebuilds may require granting access to the rebuilt application again. To retain permission across updates, use a consistent development or Developer ID signing identity, bundle identifier, and installation location; configure signing in Xcode or use the distribution flow below.

## First use

1. Open Persisted from the menu bar. The welcome window explains window placement and displays the detected setup.
2. Choose **Enable Accessibility**, then enable Persisted in **System Settings → Privacy & Security → Accessibility**. Return to Persisted so it can recheck access.
3. Arrange ordinary application windows and choose **Save current layout…**.
4. Name the layout and select applications or individual windows to include.
5. Repeat for other desks and display combinations. Multiple layouts can share one setup.

Accessibility prompting happens only after an explicit button press. Persisted does not need Screen Recording, Full Disk Access, or Input Monitoring. If access is revoked, window writes stop and saved data is retained.

If System Settings shows Accessibility enabled but Persisted still reports it missing, first quit Persisted from its menu bar menu and reopen the exact app you enabled. An older process can remain running after its app bundle has been rebuilt, leaving the running code and the approved on-disk app out of sync. If access is still missing after relaunch, remove Persisted's old entry from the Accessibility list, add the current app with **+**, and enable it again. This can be necessary after an ad hoc rebuild. Keep only one Persisted copy running while checking access.

Onboarding lets you choose whether automatic switching starts after the first save. Launch at login, Remember adjustments, and launching missing applications start off.

## Layout workflows

**Auto mode (off by default):** Turn on **Auto** in the menu footer or Settings to automatically remember and restore configurations for each physical display setup. A new setup gets a name such as “Laptop only” or “Two displays and laptop.” Auto uses the chosen preset for a known setup, restores it after displays settle, and then saves later window and desktop changes in its remembered revision. It preserves the explicit saved arrangement and keeps recent revision history. Different monitors remain separate setups even when their counts match.

Choose **Use this preset** in layout details or the **Auto preset** in display profiles to select the configuration for a setup. Turn off **Use in Auto mode** to pause that preset without deleting it, or turn off **Remember changes in Auto mode** to restore a fixed arrangement. App checkboxes and **Include this desktop** control both learning and restoration; excluded content stays saved. Desktop slots remain ordered, so an excluded earlier desktop may still be created to reach a later included one. Closed apps keep their saved windows. Incomplete captures, failed placements, unavailable desktop inventory, and ambiguous display identities do not overwrite the saved arrangement. Auto uses a short debounce plus a 10-second fallback check for desktop edits.

The older **Restore-only switching** setting only restores existing layouts and is suspended while Auto mode is on. Both modes use the existing Accessibility and experimental desktop capabilities; neither changes macOS security settings.

**Work from the menu bar:** All saved layouts remain in their saved order in a scrolling card list, including layouts for disconnected displays. Search by layout or application name. Use **⌘F** to focus search, **↑/↓** and **Return** to choose a result, or **⌘1–9** to apply the first nine layouts while the panel is open. Manual Apply detects clear display matches even when the connected setup has changed; the display-mapping sheet opens only when a destination still needs review.

**Edit a layout:** Click its name, preview, or chevron. Details include its name, icon, order, application inclusion, global shortcut, display-specific Apply actions, update controls, and saved revisions. Per-layout app exclusions leave those apps alone during apply, retry, learning, and undo; exclusions in Settings remain global.

**Edit the saved arrangement:** Choose **Edit arrangement** in layout details. Select a saved display and desktop, then drag or resize windows in the preview, enter point coordinates, or use **Arrange** presets. Assign windows to another saved display or desktop with the placement pickers. Desktop controls move ordinary desktops earlier/later with their windows, choose the active desktop, add desktops, or remove empty ones. Full-screen Spaces are preserved. Editing also works for disconnected displays and without Accessibility permission.

Edits stay in a draft until **Save changes**; **Cancel** leaves the layout unchanged. Saving archives the previous saved and remembered revisions and does not move live windows. Apply the layout when ready. Automatic learning pauses while an editor is open and, for an edited preset, until a full successful restore on its original setup. Partial applies and unsuccessful restores keep those edits protected. Existing Auto, app, and desktop inclusion preferences are preserved.

**Quick switch from anywhere:** **⇧⌘L** opens the same compact interface. Each layout can also have a custom global shortcut, recorded in its details. Shortcuts require Command or Control, or a function key; conflicts are reported. The recorder temporarily suspends Persisted's own bindings. Global shortcuts use the public Carbon hotkey API and do not require Input Monitoring.

**Schedules:** Open **Schedule** in the panel, choose a layout, weekdays, and a start/end time. The layout applies once in that local-time window when permission and matching displays are available. Overnight windows belong to their starting weekday. Overlaps use the first matching schedule; manual changes are left alone after a window has fired. Each schedule has its own enable switch, independent of display-driven automatic switching.

**Display profiles:** Click the display indicator in the footer to name your setups and choose their preferred layouts. Display aliases and conservative mapping rules continue to apply.

**Capture one display:** The inline save page can select all displays or one display, then individual applications and windows. A layout's detail page can apply only one of its saved displays; unrelated windows and applications are not moved or launched.

**Remember desktops:** New captures include the count and order of ordinary Mission Control desktops, the active desktop for each display, and available desktop assignments for included windows. Empty desktops are retained in the setup snapshot even when only some windows are selected. Open a layout's **Desktops** section to see its ordered desktops and included apps. Existing layouts need an explicit update to capture this information; their previous window arrangements remain usable.

**Restore desktops:** Window-to-desktop movement currently requires macOS 26 and the supported system interfaces. Persisted checks this before any desktop creation, movement, or activation. On unsupported systems, it explains the limitation and restores window geometry while leaving desktops unchanged; desktop-dependent edits remain protected from Auto learning. Turn off Restore desktops for a geometry-only layout. **Restore desktops (experimental)** starts enabled for layouts with desktop information and can be disabled per layout. Applying creates missing ordinary desktops when possible, assigns matched eligible windows to the saved desktop positions, and restores window geometry. Saved desktops are mapped by display and order. When several saved monitors map to one monitor, their desktop groups are placed consecutively. Extra current desktops are preserved and reported, so the resulting count may exceed the saved count. Single-display Apply limits desktop work to that saved display. Mission Control can appear while desktops are created or activated. Desktop results are shown separately from window-geometry results, including unavailable capabilities and incomplete assignment restoration.

**Apply a layout:** Select it in the popover, or choose **Apply layout** in Manage layouts. Clear display matches apply directly, including a saved laptop display while an external monitor is connected. Persisted recognizes built-in displays, unique monitor identities and hardware hints, and unambiguous remaining destinations. If only one display is available, it can receive the saved windows. Ambiguous choices open a mapping sheet with clear matches already selected and a projected monitor preview: assign the remaining displays or skip their windows. At least one display must be mapped. You can save the result as a new layout for the current setup.

**Choose automatic behavior:** In Manage layouts, choose **Make preferred** for the layout to use when its setup returns. A manually selected layout remains selected through compatible resolution and arrangement changes, until the actual setup identity changes. Turning automatic switching off cancels pending automatic work. Turning it on reconciles the stable setup once.

**Update saved contents:** **Update saved layout** explicitly captures the current eligible windows and replaces the layout’s saved membership, geometry, and captured desktop setup. To control membership while updating, use **Save current layout…** and choose the existing layout in **Save to**. An incomplete capture cannot silently replace an existing layout.

**Remember adjustments:** Enable this separately for a layout to learn stable placement changes for its existing windows. It does not add or remove windows. Learning is paused around reconfiguration, sleep, restoration, temporary incompatible mappings, and incomplete captures. **Discard remembered adjustments** returns to the explicitly saved arrangement. Previous revisions are available from the layout detail view.

**Recover a partial restoration:** Results distinguish restored windows from missing, ambiguous, unsupported, timed-out, or cancelled entries. Use **Assign window…** to select a live window when identity is ambiguous, or retry unavailable entries. Matching preferences support automatic matching, exact titles, and title substrings. Assignments to live windows are limited to the current application instance.

**Undo:** **Undo last apply** restores surviving eligible windows changed by the most recent apply, including their captured desktop membership when available. The current display arrangement must still match the arrangement at application time. Undo does not close applications, recreate vanished windows, or delete desktops created during an apply; desktop recovery issues are reported separately.

**Exclude windows:** A saved window’s options menu can exclude that window or its entire application. Exclusions apply to capture, learning, restoration, and undo. Remove exclusions in Settings.

**Import and export:** Manage layouts’ sidebar menu imports or exports JSON. Import first displays a selectable preview; imported layouts remain inactive until their display mappings and automatic behavior are reviewed. An export contains window titles and may contain document paths or URLs. Treat it as private data.

## Displays and restoration boundaries

Setup matching uses durable display identity hints, built-in participation, lid policy, and mirror grouping. Display positions, primary display, logical sizes, scaling, rotation, and usable work areas are geometry context. Resolution or primary-display changes normally adapt the layout without creating another setup. Window placement uses logical points and current work areas, accounting for the Dock, menu bar, and screen safe areas.

The display inventory is separate from placement surfaces: a mirror group contributes one usable surface. Enumeration is dynamic and has no fixed laptop-plus-monitor slots. Virtual and wireless displays are handled according to the identity and geometry exposed by macOS.

Identical monitors without useful serial numbers can be ambiguous even when macOS supplies UUIDs. Persisted keeps their display labels and saved mappings, but requires fresh confirmation after reconfiguration or application restart when identity remains ambiguous. This can make automatic restoration deliberately wait for a mapping decision.

Lid state is read independently from built-in-display activity. It can be open, closed, unknown, or not applicable. An inactive built-in display does not imply a closed lid. A layout with an unknown lid state can match that state explicitly; **Match this setup regardless of lid state** permits topology-based matching across lid states.

Persisted restores ordinary application windows exposed through Accessibility. Hidden and minimized windows, native fullscreen/Split View spaces, and windows assigned to all desktops are preserved. Experimental desktop restoration maps ordinary desktops to ordered slots; it does not delete extra desktops or rearrange native fullscreen spaces. It restores captured window membership rather than changing an app's Dock **Assign To** policy for future windows. It does not change monitor hardware settings or recreate documents, browser tabs, terminal sessions, and unsaved windows. Launching an application is an optional per-layout action and may not recreate its saved windows. Stage Manager and applications with incomplete Accessibility support can produce skipped or constrained results.

Desktop capture and window reassignment use private SkyLight interfaces. Creation and activation use the Dock's Mission Control Accessibility controls. These interfaces are experimental and can change with macOS updates; availability is checked and incomplete operations are reported. The implementation does not disable System Integrity Protection, inject code into the Dock, or change system security settings. The SIP-enabled window-move technique is based on [yabai's Tahoe work](https://github.com/asmvik/yabai/issues/2788); Mission Control's Accessibility structure is also used by [Hammerspoon](https://www.hammerspoon.org/docs/hs.spaces.html). Those upstream results do not establish that every desktop operation has passed on the user's Mac; see [Verification](docs/Release-Readiness.md).

## Local data and recovery

The library is stored under:

```text
~/Library/Application Support/Persisted/
  Library.json
  Library.previous.json
  Library.corrupt-<identifier>.json   # created only when preserving unreadable data
```

A single repository actor serializes writes, validates the schema and geometry, writes atomically, and retains a separately validated previous library. Reads, writes, and exports share a 25 MB encoded-size limit. Oversized changes are rejected before replacing the active library, primary file, or backup; capture and import drafts remain available after rejection. A damaged primary file is preserved before recovery from a valid backup. A library created by a newer unsupported schema is protected from overwrite.

Desktop snapshots use library format 2. Existing format-1 libraries migrate on load and retain their saved geometry; desktop membership remains unavailable until a layout is updated. Writes and exports use format 2, which older Persisted builds cannot safely edit.

Explicit layouts, remembered adjustments, recent stable recovery snapshots, and the pre-apply undo state have separate responsibilities. Recovery snapshots appear in **Settings → Recovery** and can be recovered as new layouts. Revision and recovery history are bounded. Undo is an in-memory operation for the current application session.

Titles and document identifiers remain local. Routine logs report transitions, counts, and outcomes without window titles or document paths. Quit Persisted before manually inspecting or replacing its library, and keep a copy of the entire directory before recovery work.

## Verification status

The implementation has been compiled with Apple Swift 6.3.3 from Command Line Tools on macOS 26.7. `Scripts/test.sh` passes **254 Swift tests across 14 suites and 10 release-tooling tests**. Tests use controlled displays, window descriptors, permission changes, failures, and clocks; they cover matching, coordinate conversion, desktop planning and schema migration, learning protection, persistence limits and backups, cancellation, automatic selection, partial results, offline editing, and undo. Tooling tests use temporary fixtures and fake signing commands. See [Release readiness](docs/Release-Readiness.md) for current verification and the remaining native checks.

A read-only native diagnostic observed three online outputs and three usable placement surfaces, lid open, and ambiguous unnumbered outputs. Accessibility trust was false. No real application windows were moved during that diagnostic. Native onboarding was also launched and inspected. The packaged integration checker was executed after rebuilding; it reported Accessibility unavailable and correctly targeted zero windows.

The later desktop diagnostic read **9 ordinary desktops on 2 displays (3 + 6)** and resolved the private move capability. This establishes inventory reading and symbol availability only. Its executable was not trusted for Accessibility, and desktop creation, movement, and activation were not exercised.

Physical docking, zero through four external-display configurations, real permission revocation during writes, fullscreen, multiple Spaces, Stage Manager, third-party window behavior, and launch-at-login registration still require the [manual smoke tests](docs/Manual-Smoke-Tests.md). Full Xcode and distribution signing/notarization credentials were unavailable in the implementation environment, so the Xcode build/test and signed release flow require verification on a configured Mac. The observed desktop topology is not evidence that the hardware transition matrix was exercised.

## Controlled native integration check

After building and granting Accessibility to that exact app build, run:

```sh
./Scripts/integration-check.sh
```

This opens the supplied fixture and starts a separate Persisted check process. Only windows from `app.persisted.Persisted.Harness` are eligible for mutations. The check verifies stable live references for duplicate titles, no-op placements, move/resize readback, application minimum sizes, and reachable constrained placement. It attempts to restore every fixture window’s original frame before writing `build/native-integration-<timestamp>.json`. It never changes the layout library and never prompts for permission. A permission-denied result is a failed positive integration check, even though its safe refusal is expected. Quit the fixture when finished.

## Release

For direct distribution, the application uses Hardened Runtime with App Sandbox disabled. Supply your own Developer ID identity and an existing notarytool keychain profile; credentials are not stored in the repository:

```sh
SIGNING_IDENTITY='Developer ID Application: Your Organization (TEAMID)' \
NOTARY_PROFILE='persisted-notary' \
./Scripts/release.sh
```

The release script builds, signs, verifies, submits for notarization, and staples the application when those credentials are supplied. It derives the release archive name from the built app’s version and uses the same resolved build directory throughout. Add `--package-site` to refresh the website’s download from that exact release artifact after verification; the download URL remains stable. Validate the resulting application on a clean account or Mac, including Accessibility and launch-at-login approval, before distribution.

See [Architecture](docs/Architecture.md) for component boundaries and [Manual smoke tests](docs/Manual-Smoke-Tests.md) for the hardware and native-integration checklist.

## Website

The static landing page lives in [site/](site/README.md). Preview it with `python3 -m http.server 4173 --bind 127.0.0.1 --directory site`, then open `http://127.0.0.1:4173`. Its screenshots render native views with sample data; preview and source archives are generated by `python3 Scripts/package-site.py`.
