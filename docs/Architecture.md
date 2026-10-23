# Architecture

Persisted separates deterministic placement decisions from macOS adapters and SwiftUI presentation. The same source modules are used by the Swift package and Xcode project. The minimum deployment target is macOS 14; source uses Swift 6 concurrency.

## Components

| Component | Responsibility |
| --- | --- |
| `PersistedCore/Models.swift` | Codable library, topology, saved geometry, options, revisions, exclusions, mappings, plans, and per-window outcomes |
| `DisplayTopologyService` | NSScreen work areas, online/active CG inventory, ColorSync UUID and hardware hints, mirror groups, display and workspace events |
| `LidStateProvider` | Best-effort IOKit clamshell reads and notifications, explicit unknown and desktop fallbacks |
| `AccessibilityService` | Eligible-window enumeration, live AX-object ownership, observer registration, bounded placement and read-back |
| Desktop models and macOS desktop adapter | Ordered per-display desktop snapshots, window membership, mapped ordinary-desktop slots, capability detection, and verified experimental restoration |
| `CoordinateMapper` | AppKit/AX conversion, source-display selection, normalized adaptation, reachable placement |
| `WindowMatcher` | Conservative deterministic one-to-one matching and ambiguity detection |
| `RestorePlanner` | Pure mapping and matching decisions, intended placements, unresolved entries |
| `RestoreCoordinator` | Serialized application state, stabilization, selection, cancellation, execution, undo, stable recovery, learning, persistence ordering |
| `LearningPolicy` | Pure eligibility checks and geometry-only updates for remembered adjustments |
| `LayoutRepository` | Single actor for versioned validation, atomic writes, backup recovery, import and export |
| `PermissionService` / `LoginItemService` / `ApplicationLauncher` | Explicit AX prompt, actual ServiceManagement state, nonactivating application launch |
| `AppModel` | Observable presentation bridge and explicit user commands |
| `PersistedApp` / `Views` | MenuBarExtra, normal windows, onboarding, capture selection, management, mapping and previews |
| `PersistedHarness` | Separate real AppKit application with controlled standard windows for manual integration checks |

`WindowAccessing`, `TopologyProviding`, `PermissionChecking`, `ApplicationLaunching`, `LibraryStoring`, and `RestoreClock` support controlled fake dependencies in tests.

## Isolation and lifecycle

SwiftUI, AppKit screen enumeration, presentation state, and the coordinator are main-actor isolated. Synchronous AX calls execute on `AccessibilityService`, an actor with a dedicated serial DispatchQueue executor. AX elements and observer registrations remain inside that worker. The UI and core receive immutable, Sendable window descriptors and opaque worker tokens.

The small `MutationGate` is protected by a lock. It lets the synchronous worker recheck the coordinator’s generation immediately before a mutation without hopping to the main actor. The custom executor and gate have narrowly scoped synchronization-based Sendable declarations; live AX objects are not passed between executors.

App initialization starts services before the popover is opened. The menu bar icon awaits startup before opening first-run onboarding. Termination stops callbacks and observers, cancels pending work, and awaits persistence before replying to AppKit’s termination request.

Workspace notifications are registered on `NSWorkspace.shared.notificationCenter`. Session activity notifications are treated as session events, not as a universal screen-lock detector. Observer sources, retained callback contexts, CG callbacks, IOKit resources, timers, and registrations have explicit cleanup paths.

## Display identity and geometry

A topology retains the physical/output inventory independently of usable placement surfaces. Mirrored receivers remain inventory records and reference a source surface. Display identity combines UUID or vendor/model/serial hints with built-in participation, relevant lid state, and mirror groups. Runtime CG display numbers are enumeration handles, not persisted identities.

The setup key is distinct from the geometry key. Geometry includes primary display, positions, logical frames, usable frames, scale, and rotation. An equivalent setup with different geometry can retain its selected layout and adapt windows.

Incomplete or duplicated identity metadata is flagged. Persisted stores labels and explicit mappings, but session approval is invalidated when ambiguous outputs reconfigure. Reconfirmation after restart or reconnect prevents a connection-order guess from moving windows to the wrong indistinguishable screen.

All windows use AX top-left logical-point coordinates. Screen records use AppKit bottom-left logical-point coordinates. The shared conversion is:

```text
axX = appKitRect.minX
axY = snapshot.primaryFrame.maxY - appKitRect.maxY
width and height are unchanged
```

The primary frame comes from the same topology snapshot, not `NSScreen.main`. Capture selects the source display by largest intersection with a deterministic fallback. Saved windows retain original, source-usable, relative, and normalized rectangles. Unchanged geometry restores the saved placement; changed work areas use normalized adaptation, optionally preserving size in points. Clamping keeps oversized windows’ title bars reachable. SwiftUI previews use this same coordinate module.

## State and event processing

The coordinator has `idle`, `settling`, `restoring`, `suspended`, `permissionRequired`, and recoverable `waiting` states. Display/lid changes, workspace sleep/wake, screen sleep/wake, session activity, application events, window events, permission changes, and explicit commands enter this coordinator.

Reconfiguration invalidates pending work immediately. Stabilization starts with a one-second quiet period, then requires two equivalent observations, 400 milliseconds apart. Wake adds a two-second grace period. Eight observations bound an unstable sequence; fresh events can resume a waiting configuration. These values are injectable through `CoordinatorTiming`.

Every newer request, relevant transition, suspension, or permission failure invalidates a generation. Equivalent notifications do not imply a setup change. Manual commands take precedence over queued automatic work. A manual layout remains active through compatible geometry changes without changing the explicit preferred layout. Unrecognized setups stay untouched.

Window movement schedules debounced observation and learning, not another restore. Permission checks happen on activation, before operations, and before each AX write. A low-frequency trust-only timer supplements those checks because macOS provides no supported AX trust-change notification.

## Capture, plan, execute, verify

1. Verify permission, usable displays, and a stable generation.
2. Capture eligible windows before any launch or placement, preserving pre-apply geometry for undo.
3. Optionally launch absent applications through NSWorkspace without deliberately activating them.
4. Use bounded late-window retries within this restoration session.
5. Match saved windows and build a pure restore plan with mappings, target frames, and unresolved outcomes.
6. Revalidate generation, application instance, identity, capability, state, and geometry in the AX worker.
7. Skip already-positioned windows; use a bounded size–position–size sequence where needed.
8. Read back accepted geometry and report restoration, constraints, missing/ambiguous/unsupported windows, timeouts, or cancellation.

The AX process-wide messaging timeout is configured through the system-wide element, so child elements inherit the process default. Individual applications have finite budgets. A hung application can delay its bounded work but does not prevent later applications from being attempted.

Matching uses validated ephemeral references first, then document evidence, identifiers, or normalized titles with role/subrole. Conflicting known documents reject a title coincidence. Duplicate titles do not receive arbitrary geometry-based tie-breaking. Exact-title and title-contains preferences still expose ambiguity. Process identity includes launch date as well as PID, protecting against reused PIDs.

Geometry placement avoids application activation, raising windows, and state changes for hidden/minimized/fullscreen windows. Experimental desktop restoration is a separate stage and can display Mission Control or activate a desktop. Evidence of an actively moved window stops automatic correction. Undo uses surviving validated live references and requires the same display geometry.

## Experimental desktop capture and restore

`DesktopSnapshot` stores ordered `DesktopDisplay` inventories containing logical `SavedDesktop` records. Each desktop has a local logical ID, zero-based Mission Control ordinal, ordinary/fullscreen kind, optional UUID hint, and active-when-captured flag. Window membership is optional `DesktopAssignment`: one logical desktop or all desktops. Unknown membership remains nil and must not be interpreted as all desktops. An unavailable or incomplete inventory remains nil rather than masquerading as an empty setup. Runtime Space and CG window numbers remain outside persisted layout data.

The snapshot belongs to its geometry revision. `Layout.effectiveDesktopSnapshot` selects the same revision as `effectiveWindows`, including a remembered revision whose snapshot is unavailable. Old libraries decode without a desktop snapshot and remain geometry-only until explicitly updated. `LayoutOptions.restoreDesktops` defaults to true, but has no desktop effect when the layout lacks a snapshot. Captures retain the full desktop inventory, including empty desktops, independently of selected window membership.

`DesktopRestorePlanner` maps ordinary desktop groups through approved display mappings. Target ordinals count ordinary desktops only; native fullscreen entries are tracked separately and preserved. Saved display groups concatenate when several monitors map to one destination. A single-display apply restricts planning to its source display. If several previously active desktops are consolidated onto one monitor, the additional simultaneously active choices are reported because they cannot all remain visible.

The native adapter reads desktop topology and window membership through private SkyLight interfaces. SIP-enabled window reassignment uses the available private move mechanism. Creation and desktop activation use the Dock's Mission Control Accessibility controls. Symbols, runtime data, permission, and operation results require validation; an OS update may remove support without affecting saved data or ordinary geometry placement. No SIP changes, code injection, security-setting modifications, or undocumented Spaces-preference edits are part of this backend.

Restoration creates missing ordinary desktops and maps included eligible windows to ordered target slots. Extra current desktops are preserved and reported, so restoring a layout does not guarantee an exact total when the current setup has extras. Fullscreen/Split View and all-desktop windows keep their native state. Captured membership does not change an application's Dock assignment policy. Undo uses captured pre-apply membership for surviving windows and does not delete desktops created during apply. Desktop status and issues are exposed separately from per-window geometry results; successful rectangle writes must not imply successful desktop restoration. The native behavior remains subject to the explicit manual verification matrix.

## Saved state and recovery

The explicitly saved revision is changed only by a user command. Optional remembered adjustments are separate and change only geometry for confidently matched existing members. Missing windows remain saved. Learning requires a complete capture, matching generation and topology before/after enumeration, a stable selected compatible setup, and no unresolved restoration. Temporary incompatible mappings cannot learn back into the original layout. Persisted’s own writes suppress learning temporarily.

Debounced observations maintain a last-known-stable snapshot. A bounded recovery history is persisted at most once per 30 seconds when eligible events produce a stable capture. This is event-driven observation, not continuous window polling. Reconfiguration, sleep, and suspension freeze pending learning so collapsed post-disconnect positions cannot overwrite the explicit layout. Pre-disconnect capture is best effort; the older valid snapshot is retained when ordering is uncertain.

`LayoutRepository` validates schema version, identities, membership, finite positive geometry, mappings, and bounds. Desktop support uses schema 2; schema-1 libraries migrate on load without invented desktop membership, and all writes/exports use schema 2. It serializes atomic replacements and keeps `Library.previous.json` from previously validated data. Corrupt primary input is copied aside before fallback. Newer unsupported formats and unrecoverable load failures prevent writes. Identical serialized data does not generate another write.

Imports receive fresh layout IDs, require mapping review, and disable Remember adjustments and application launching. Exported JSON includes saved window metadata and must be treated as private. Routine logging omits titles and document paths.

## Verification boundaries

The automated suite exercises pure algorithms and coordinator behavior using fake displays, clocks, windows, permissions, repositories, and failures. Cancellation tests control event ordering; regression tests ensure disconnect or partial capture cannot replace saved geometry.

A native snapshot diagnostic exercised real display, lid, and trust-read APIs on the implementation Mac. It did not mutate windows because Accessibility was not granted. Physical transitions and application-specific AX behavior require the separate harness and the manual checklist. No unit-test result implies hardware docking, fullscreen, Spaces, Stage Manager, or signed installation was verified.

A later read-only desktop diagnostic detected nine ordinary desktops across two displays (three and six). It reported both topology-read and window-move capability available, but move capability means private symbols resolved, not that mutation was tested. The diagnostic executable lacked Accessibility trust and performed no desktop creation, reassignment, or activation.

## Confirmed ambiguous displays

A fresh explicit capture approves its current surface identities only for that connection session. Reconfiguration or restart clears this approval. Geometry learning can use this session approval when all mappings retain their saved surface IDs; nonidentity or incompatible mappings suppress learning back into the original layout. Save the mapped result as a new layout to establish a new explicit arrangement.

### Manual display detection

Explicit Apply requests use a separate complete manual mapping, so a saved laptop-only layout can use the built-in display while external monitors are connected. Partial suggestions populate the mapping sheet when some sources remain ambiguous. Existing approved mappings take precedence. Imported layouts still require review. Automatic setup selection and remembered-adjustment eligibility continue to use strict setup compatibility; detected mappings for another setup remain temporary and never rewrite the saved layout or automatic preference.
