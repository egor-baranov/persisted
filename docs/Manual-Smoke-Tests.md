# Manual smoke tests

This checklist covers real macOS behavior that simulated tests cannot establish. Record the app revision, macOS version, Mac model, signing identity, installed path, display models/connections, and the result of each scenario. Mark each case **passed**, **failed**, or **not exercised**; retain explanations for failures and unavailable hardware.

## Verification already performed

- `swift build` passed on Apple Swift 6.3.3, Command Line Tools, macOS 26.7.
- The automated test suite passed **153 tests across 10 suites** with controlled fakes and event ordering.
- A read-only diagnostic observed three online outputs, three usable surfaces, lid open, ambiguous unnumbered outputs, and Accessibility trust false.
- A later read-only desktop diagnostic detected nine ordinary desktops on two displays (three and six), with topology-read and private move symbols available. The diagnostic executable lacked Accessibility trust. No desktop mutation was attempted; available move symbols do not verify successful movement.
- Real AX window mutation, physical display transitions, signed installation, login registration, notarization, and the full-Xcode build/test flow were not established by those checks.

## Prepare the installed application

- [ ] Build using `./Scripts/build-app.sh debug`; confirm both application bundles exist.
- [ ] Copy Persisted to `/Applications` and launch that copy. Confirm only one copy is running.
- [ ] Confirm the menu bar icon appears before opening any window, the popover is compact, and Persisted has no permanent Dock icon.
- [ ] Confirm first-run onboarding shows current displays and honest lid state.
- [ ] Before granting Accessibility, try saving or applying: expect readable permission guidance, no window movement, and no saved-data loss.
- [ ] Choose Enable Accessibility explicitly. Grant access in System Settings, return to the app, and confirm access refreshes asynchronously.
- [ ] Exercise Manage layouts, Settings, Save current layout, and window close/reopen behavior. Closing those windows must leave the menu bar utility running.

## Controlled real-window fixture

Launch the separate fixture:

```sh
open build/PersistedHarness.app
```

It opens two windows titled **Duplicate document**, with distinct AX identifiers; a window with an enforced **480 × 300** minimum size; and a purple delayed window after eight seconds. **Change title** alters a fixture window’s title.

- [ ] Arrange fixture windows across available displays, save a named layout, and select a subset of windows. Confirm the saved list and preview match the chosen membership.
- [ ] Move those windows and apply the layout. Confirm only included windows move; unrelated apps and extra windows remain unchanged.
- [ ] Apply again without moving anything. Expect already-positioned results rather than unnecessary writes.
- [ ] Exercise the minimum-size window on a smaller usable work area. Expect an honest constrained result with a reachable title bar.
- [ ] Change a title and retry. Verify stable identifier evidence or an explicit unresolved result; do not accept an arbitrary duplicate-title swap.
- [ ] Quit and relaunch the fixture. Confirm old process references are not blindly reused. Repeat title matching and explicit assignment after restart.
- [ ] Close a saved window and apply. Confirm missing-window reporting. Reopen/relaunch, then retry or assign a live window.
- [ ] Exercise delayed creation both within and after the bounded restore session. Late windows after that session must not trigger indefinite correction.
- [ ] Disable Launch missing applications, quit the fixture, and apply: no automatic launch. Enable it and repeat: opening the app must not force additional instances or claim missing windows were recreated.
- [ ] Begin dragging a fixture window as automatic restoration starts. Expect deferral/cancellation for that window, without repeated correction against the user.

## Display matrix

Use the same named layouts throughout where possible. “Zero external” means laptop-only or a desktop’s available ordinary setup; a separate no-usable-display scenario is listed below.

| Configuration | Checks | Result |
| --- | --- | --- |
| Zero external displays | Save, manual apply, automatic return, usable-area clamping | Not exercised |
| One external | Laptop open and supported closed-lid operation; return to laptop-only | Not exercised |
| Two external | Save distinct arrangements; disconnect/reconnect; primary changes | Not exercised |
| Three external | Negative coordinates, mixed placement, mapping each surface | Not exercised |
| Four external | Dynamic enumeration and preview; no fixed display-slot limit | Not exercised |
| Different desks with equal counts | Distinct physical identities select their own preferences | Not exercised |
| Same monitors through another dock | Durable identity is reused when available; ambiguity prompts otherwise | Not exercised |
| Identical unnumbered monitors | Reorder connections; mapping is confirmed, never guessed silently | Not exercised |
| Mirroring | Physical inventory retained; one placement surface per mirror group | Not exercised |
| Portrait and mixed scaling | Logical-point placement, reachable windows, accurate previews | Not exercised |
| Virtual or wireless display | Honest available metadata, bounded stabilization | Not exercised |

- [ ] Position displays above, below, and left of the primary. Verify capture and restore, including negative coordinates.
- [ ] Change the primary display, resolution, scaling, and arrangement. Confirm compatible layouts reproject without duplicate setup creation.
- [ ] Move or auto-hide the Dock. Confirm current usable areas are respected.
- [ ] Give monitors persistent labels. Confirm labels survive relaunch and mapping controls remain identifiable.
- [ ] Apply a laptop-only layout with an external display connected. Expect direct placement on the built-in display with no mapping sheet. Confirm the saved layout and automatic preference are unchanged.
- [ ] Apply a layout with ambiguous destinations. Expect clear matches to be preselected, choose the unresolved sources, skip one source, and confirm skipped windows stay untouched.
- [ ] Save a mapped result as a new layout. Confirm the original layout and its saved geometry remain intact.
- [ ] For ambiguous identical monitors, relaunch Persisted and reconnect them in another order. Expect reconfirmation even if a previous mapping is displayed as a starting point.

## Lid, sleep, sessions, and unstable transitions

- [ ] Save distinct open-lid and closed-lid layouts using the same external monitors. Confirm lid state is independent of built-in display activity.
- [ ] Test unavailable lid information through a controlled fake or hardware that lacks it. Expect unknown, never inferred closed. Confirm exact unknown matching and explicit ignore-lid policy.
- [ ] On desktop hardware with supporting evidence, verify not-applicable lid state.
- [ ] Rapidly disconnect and reconnect a dock while a restore is queued. Verify stale generations stop and the final stable setup wins.
- [ ] Sleep during docking, then wake. Confirm grace/stabilization precedes writes; no learning of collapsed positions.
- [ ] Exercise screen sleep/wake and fast user switching. Confirm suspension and stable reconciliation on return. Test locking separately; session notifications must not be assumed to cover every lock transition.
- [ ] Reach a no-usable-display state where supported. Expect waiting/suspension and no attempted placement.
- [ ] Repeated identical notifications must not create a restore loop. During an unstable transition, wait for the recoverable waiting state, then trigger a fresh valid change.
- [ ] Turn Automatic switching off during queued automatic work. Confirm cancellation; turn it on and confirm one stable reconciliation.
- [ ] Select another layout manually during queued automatic work. Confirm manual selection wins and its preferred-layout setting is unchanged.

## Data protection and undo

- [ ] Save an explicit multi-monitor layout; note its revision and positions. Disconnect monitors while windows collapse. Reconnect and verify the explicit revision remains unchanged.
- [ ] Enable Remember adjustments, move only an included window, and wait for stable learning. Confirm saved membership stays fixed and unavailable entries survive.
- [ ] Repeat during a partial capture, partial restoration, and display transition. Confirm these states do not replace saved or remembered geometry.
- [ ] Discard remembered adjustments and apply. Confirm the explicit saved version returns.
- [ ] Restore a previous revision. Verify this changes saved data and requires Apply to move windows.
- [ ] Recover a stable snapshot in Settings. Confirm it becomes a new layout.
- [ ] Apply a layout with mixed success, then Undo. Surviving changed windows should return to pre-apply positions; unrelated windows remain unchanged.
- [ ] Change display geometry before Undo. Expect refusal with an explanation.
- [ ] Exclude one window and then its application. Confirm exclusions affect capture, apply, learning, and undo; remove them in Settings.

## Permissions and application boundaries

- [ ] Revoke Accessibility during a multi-window restore. Confirm subsequent writes stop and saved data remains available.
- [ ] Restore permission and verify the app recovers without prompting in a loop.
- [ ] Minimize, hide, and fullscreen saved windows; exercise Split View. Confirm their state is preserved and skipped operations are explained.
- [ ] Disable **Restore desktops (experimental)** for a layout and apply while using multiple Spaces. Confirm no deliberate desktop creation, reassignment, or switching.
- [ ] Use Stage Manager and verify unsupported cases are explained without repeated window correction.
- [ ] Exercise Finder, a browser with several windows, an editor, and a terminal. Include changing titles and duplicate document titles.
- [ ] Exercise an unresponsive test application. Expect bounded timeout reporting while other applications continue.

## Experimental Mission Control desktops

Use the supplied fixture windows and record the starting desktop counts, order, active desktops, and membership before each test. The checks below are **not exercised** until results are recorded for the exact packaged build and macOS version. Leave SIP and other system security settings unchanged.

- [ ] Load an older library without desktop snapshots. Confirm its window layouts survive unchanged, cards do not invent desktop counts, and details say **Update this layout to capture its desktops**.
- [ ] Arrange fixture windows on two or more ordinary desktops, including an empty desktop. Save a layout. Confirm the captured count, ordered per-monitor desktop list, included apps/window counts, and active-when-saved markers match Mission Control.
- [ ] Save only a subset of windows or choose one monitor in the capture page. Confirm the desktop preview describes the whole captured setup and empty desktops remain represented; only selected windows become layout members.
- [ ] Move a fixture window to a different ordinary desktop, then apply. Confirm desktop membership and geometry both return, and independent desktop/geometry results match the actual state.
- [ ] Remove an unused test desktop, then apply a layout that requires it. Confirm the missing ordinary desktop is created on the mapped monitor, Mission Control closes normally, and the new count and window membership are verified.
- [ ] Add an extra test desktop, then apply a layout with fewer desktops. Confirm the extra desktop is preserved, its unrelated windows stay untouched, and results report the excess rather than claiming an exact count.
- [ ] Undo after moving fixture windows between desktops. Confirm surviving windows return to captured pre-apply membership and geometry; newly created desktops are retained rather than deleted, and partial desktop recovery is reported.
- [ ] Test single-display Apply on a multi-monitor layout. Confirm unrelated monitors' desktops and applications remain unchanged.
- [ ] Map two saved monitors to one available monitor. Confirm ordinary desktop groups concatenate in saved order, and multiple saved active-desktop choices are reported honestly.
- [ ] Test both **Displays have separate Spaces** configurations, including capture on one mode and restore in the other. Confirm unsupported mode changes are explained rather than assigning windows to guessed desktops.
- [ ] Use native fullscreen, Split View, and windows assigned to all desktops. Confirm their native state is preserved and they are never treated as ordinary single-desktop windows.
- [ ] Exclude an app/window, close a captured window, and introduce duplicate window titles on different desktops. Confirm exclusions and conservative matching still apply; ambiguous windows are not moved to arbitrary desktops.
- [ ] Revoke Accessibility or disconnect a monitor during desktop work. Confirm subsequent mutations stop, a cancellation/partial result is shown, and saved snapshots remain unchanged.
- [ ] Simulate an unavailable private symbol or invalid desktop topology in a controlled adapter test. Confirm geometry and desktop results are distinct, and the UI does not report desktop success.
- [ ] Capture after switching desktops, restarting the fixture, and restarting Persisted. Confirm stale runtime Space/window IDs are not reused as persistent identities.
- [ ] Import/export a desktop layout. Confirm logical membership survives export, machine-specific hints do not force assignments on another Mac, and imported mapping review remains required.
- [ ] Observe a scheduled or automatic restore with desktop support enabled. Confirm any Mission Control visibility or active-desktop change matches the documented behavior and occurs only within the bounded restore session.

## Import, corruption recovery, and release

Use a temporary macOS account or a copied Application Support directory for destructive corruption fixtures. Quit Persisted before replacing library files; retain the original directory so it can be restored.

- [ ] Export, preview an import, choose a subset, and cancel once. Confirm cancel leaves the library unchanged.
- [ ] Complete an import. Confirm imported layouts have fresh IDs, remain inactive before mapping review, and do not inherit automatic preference or launching/learning behavior.
- [ ] Feed invalid coordinates, nonfinite values, duplicate identities, and an unsupported future schema. Expect validation errors without overwriting valid data.
- [ ] With a valid previous library, corrupt the primary. Confirm recovery from the previous library and preservation of the corrupt input.
- [ ] With no valid backup, confirm the unreadable library is preserved and writes are protected.
- [ ] Quit after edits, relaunch, and confirm persistence. Verify no extra observer-driven activity remains after quitting.
- [ ] Enable and disable launch at login from an installed signed app. Verify actual ServiceManagement status, approval-required handling, and next-login behavior.
- [ ] Build/test using full Xcode and both shared schemes. Verify architecture/deployment configurations needed for distribution.
- [ ] Run the release script with Developer ID and notarization credentials. Verify code signature, notarization, staple, first launch, Accessibility association, and login-item approval on a clean account or another Mac.
- [ ] Test light/dark appearance, increased contrast, reduced motion, keyboard navigation, and VoiceOver labels in the popover, manager, capture chooser, and mapping/assignment sheets.
