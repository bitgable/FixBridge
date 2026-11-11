# FixBridge Architecture

## Responsibilities

- **Models** define locations, routes, input parsing and validation, playback state, and iAP2 message encoding. Window creation and network requests live outside the model layer.
- **Services** handle USB and Bluetooth transport, local authentication, persistence, terrain elevation lookups, and external tools. They enforce input and size limits, apply timeouts, and translate low-level errors.
  - `Services/Native` contains the USB bridging header, the USB transport implementation, and the standalone Bluetooth helper. Swift services use these C and Objective-C interfaces to access the underlying platform APIs.
- **ViewModels** publish UI state on the main thread and coordinate services and app operations. Views request changes through their view models.
- **Views** handle presentation, focus, dialogs, navigation, and native controls. AppKit bridges are scoped to platform UI and input behavior.
- **Resources** contains app icons, bundled license texts, and the shared English About credits. English UI strings are defined in source. Simplified Chinese and Traditional Chinese for Hong Kong and Taiwan each have their own `.lproj` directory.

### Key view models

| Type | Responsibility |
| --- | --- |
| `FixBridgeViewModel` | Device selection, connection checks, session start and stop, status, and sent location history |
| `TargetLocationViewModel` | Coordinate entry, map selections, elevation lookups, and management of saved locations |
| `SavedLocationEditorViewModel` | Draft state, submission validation, and errors for a single location editor |
| `GPXRouteViewModel` | Route library, GPX import, confirmation before looking up missing elevations, and playback state |
| `RouteEditorViewModel` | Transaction boundaries for renaming, saving, canceling, and deleting routes |
| `RouteMapViewModel` | Coordinate projection, marker sampling, map bounds, and regional alignment suggestions for route previews |
| `MapPointPickerViewModel` | Place search, search results, and search task lifetime |

## Invariants

1. Use `LocationInput` to parse and validate input from the main window and the saved location editor. Keep the original text in the fields and parse it on submission. Define numeric limits in one place.
2. Editors retain an original snapshot and validate the current draft. Compare the stored contents against the snapshot before overwriting or deleting a record. An unchanged ID can still refer to newer content. Canceling discards only the editor's draft. If saving fails, retain the draft so the user can retry.
3. Preserve the preference keys and Codable fields for saved locations, and the route library's version and storage path. Keep existing data readable when renaming types. Publish saved state only after persistence succeeds.
4. Elevation lookups, map region requests, device discovery, and session callbacks each have their own lifetime. Results can arrive after cancellation. Only the current request or window may publish results or clear its loading state.
5. The window owns Bluetooth discovery. Briefly switching connection modes reuses an in-flight lookup. Closing the window cancels discovery and invalidates pending results. Perform accessory authentication separately for paired devices.
6. Apply route coordinate projection only to the preview. Preserve the original GPX coordinates for storage and transmission to the iPhone. **Automatic** suggests an alignment based on the route's region. It has no access to MapKit's active basemap provider.
7. When a GPX file is missing elevations, wait for the user's confirmation before looking up the affected points. Import them only after obtaining all missing elevations.
8. A packet acknowledgment confirms delivery over the connection. Verify location adoption on the iPhone itself. Report protocol, transport, UI state, and physical-device location checks separately.

## Verification

- `Tests/run.sh` covers input, editor transactions, saving, cancellation and deletion, persistence conflicts, out-of-order async results, window reopening, route playback, and certificate and protocol edge cases. It uses temporary storage and test doubles, with no access to real keys or an iPhone.
- `python3 Tests/check_sources.py` checks Xcode source registration and localization references.
- `xcrun swift-format lint --strict --recursive FixBridge Tests` checks Swift formatting.
- A full Xcode build and `codesign --verify --deep --strict` verify compilation, linking, and signing. Check the UI and physical-device behavior separately.

Add new Swift files to the appropriate Xcode Sources build phase. Also register any new test dependencies in `Tests/run.sh`. Keep the user-facing version at 1.0.0 unless the user requests a change. Increment the build number as usual.
