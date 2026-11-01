# AutoOrtho for macOS

The SwiftUI/AppKit app uses the patched AutoOrtho engine from `macos-foundation`.
No Qt windows are created by the native interface. The Python engine, FUSE-T
integration, imagery providers, native DDS libraries, and existing configuration
remain in use.

## Build

Requires Apple Silicon, macOS 14 or later, Apple's current Swift toolchain, and
the Python/PyInstaller environment used to build your existing AutoOrtho bundle.
The build verifies its engine modules against this checkout before packaging.

```sh
python macos/build.py --engine-app /Applications/AutoOrtho.app
open "macos/build/AutoOrtho.app"
```

Use the same Python minor version as the engine bundle. The current local bundle
uses Python 3.14. The builder preserves every existing engine module verbatim,
adds `native_service`, and changes only the executable's entry dispatcher.
The original startup and multiprocessing paths remain available to the helper.
Native library verification compares Mach-O code/data sections because packaging
changes rpaths and embedded signatures.

Quit AutoOrtho before replacing its installed bundle. The builder also accepts
the installed SwiftUI app as its engine source, reusing its embedded engine and
original bootstrap without creating extra engine copies or nested dispatchers.
Do not run two streaming engines at the same time.

## Interface

- Overview: the primary Start/Stop control, the reason streaming can't start
  with the action that fixes it, setup checks, mount status and storage.
- Scenery: installed and available regions with sizes, visible Install
  buttons, inline progress, catalog refresh, removal, seasons, terrain
  restoration, and reflectivity adjustments.
- Flight Plan: SimBrief loading, a native MapKit route/aircraft map, and an
  imagery override inspector. The map display does not change terrain imagery.
- Activity: actual progress and failures from existing scenery operations.
- Diagnostics: searchable/exportable logs and recorded performance reports.
- Settings: user-facing engine settings on ordered pages (General, Imagery,
  Loading, Storage, Scenery, Flight, Advanced, Diagnostics) grouped as in the
  Qt app, with authored descriptions, native toggles, pickers, range-limited
  number fields and folder panels. Internal state keys are hidden; keys the
  app doesn't know yet appear under Advanced. Search covers every page.
  `macos/Sources/SettingsCatalog.swift` defines the layout.

Command-Return starts or stops streaming (Streaming menu). Command-1 through
Command-5 navigate (View menu); Command-comma opens Settings. Command-S applies
settings within that window. The menu-bar item shows status and can start or
stop streaming after the main window closes. Every stop asks for confirmation. Quitting waits for
graceful engine shutdown; an unmount timeout never force-kills it.

Read-only refresh does not load the configuration-writing engine modules.
Saving changes preserves comments and unrelated settings, rejects stale edits
and invalid values, and is disabled while streaming. Existing imagery selection,
cache limits, terrain patches, and user preferences are not reset.

The local control bridge uses inherited pipes, not a listening control server.
The engine's existing map/flight server provides live data. The additional
flight-plan endpoint accepts loopback requests only. Each engine retains its
existing process supervisor and startup diagnostics. Native instances use a
file lock to prevent concurrent starts; mounts owned by another instance are
observed without taking ownership or stopping them.

## Design and verification

The interface uses system navigation, toolbars, semantic fonts, SF Symbols,
standard controls, grouped forms, alerts, directory panels, Settings and native
menus. Appearance and Liquid Glass materials follow the installed OS; no
custom glass rendering, fixed light/dark palette, or animated backgrounds are
used. Accessibility labels accompany icon-only actions and status indicators.
This follows Apple's guidance; it is not Apple certification or App Store
review. A full VoiceOver/keyboard/accessibility-preferences acceptance pass and
flight testing are still required before treating this as a release.

References:

- [Designing for macOS](https://developer.apple.com/design/human-interface-guidelines/designing-for-macos)
- [Liquid Glass](https://developer.apple.com/documentation/technologyoverviews/liquid-glass)
- [Settings](https://developer.apple.com/design/human-interface-guidelines/settings)
- [Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility)

The macOS 27 SDK's `State` macro requires a plugin supplied with full Xcode.
`NativeState` is an alias for Apple's supported `SwiftUI.State` property-wrapper
type so this project also builds using Command Line Tools alone. This does not
implement custom state storage or alter the system controls.

Run bridge contract tests without launching the engine:

```sh
python -m pytest -q -p no:cacheprovider autoortho/tests/test_native_service.py
```

Local builds are ad-hoc signed and verified with `codesign --verify --deep
--strict`. They are not Developer ID signed or notarized. Build products,
logs, screenshots and local verification receipts are excluded from Git.
