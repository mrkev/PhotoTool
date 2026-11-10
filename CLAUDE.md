# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A sandboxed macOS app for browsing and organizing the system photo library with PhotoKit. Editing photos is deliberately out of scope: it manages the library, but nothing changes pixel data. That includes `revertAssetContentToOriginal`, which is left out on purpose.

## Commands

There is one scheme, `PhotoTool`, and no linter is configured.

```sh
# Build
xcodebuild build -project PhotoTool.xcodeproj -scheme PhotoTool -destination 'platform=macOS'

# Run the unit tests. PhotoToolUITests is still the Xcode template, so leave it out.
xcodebuild test -project PhotoTool.xcodeproj -scheme PhotoTool -destination 'platform=macOS' -only-testing:PhotoToolTests

# Run one suite or one test
xcodebuild test -project PhotoTool.xcodeproj -scheme PhotoTool -destination 'platform=macOS' -only-testing:PhotoToolTests/GridMetricsTests
xcodebuild test -project PhotoTool.xcodeproj -scheme PhotoTool -destination 'platform=macOS' -only-testing:'PhotoToolTests/GridMetricsTests/emptyGridHasNoContent()'
```

`xcodebuild` output doesn't include Swift Testing failure messages. To read them, run `xcrun xcresulttool get test-results summary --path <result>.xcresult` on the bundle in `Logs/Test` under DerivedData.

Editor diagnostics like `Cannot find type 'BrowserModel' in scope` or `No such module 'Testing'` come from SourceKit checking one file at a time. Only trust errors from `xcodebuild`.

## Project settings that affect how code is written

- **Default isolation is `MainActor`**, in Swift 5 mode with approachable concurrency. Mark pure value types and helpers `nonisolated`. The test target doesn't share this default, so anything tests call directly must be `nonisolated`.
- **PhotoKit callbacks arrive on background queues.** Swift 5 mode has no runtime isolation checks, so a closure that wrongly touches main-actor state won't crash. Hop back with `MainThread.run`, and keep `performChanges` blocks in `nonisolated` code.
- **Member import visibility is on.** A file must import the module that defines any member it uses, even if another file already imports it (for example, `import Photos` just to read `PHAsset.isFavorite`).
- **The deployment target is macOS 15.8**, which is what the development Mac runs. APIs newer than that, such as `PHAsset.addedDate`, need `#available` checks.
- **Source folders are synchronized groups**, so new files are picked up without editing `project.pbxproj`.
- **Capabilities are split across two places.** Most entitlements and usage strings are build settings (`ENABLE_RESOURCE_ACCESS_PHOTO_LIBRARY`, `INFOPLIST_KEY_*`). `PhotoTool.entitlements` holds only what build settings can't express: the `scripting-targets` access groups for Photos. Adding a new Photos script command may require a new access group there; check `sdef /System/Applications/Photos.app`.

## Architecture

**State.** There's a single window, and `PhotoToolApp` owns two `@Observable` objects:

- `LibraryStore`: permission status, library availability, and the sidebar tree. The sidebar is built off the main actor as a value snapshot (`SidebarSnapshot`) and refreshed on a debounce, because iCloud sync can deliver many changes quickly.
- `BrowserModel`: the current source, query, `PHFetchResult`, selection, viewer asset, sheets, and alerts. Its action methods are what the menus, toolbar, and grid all call.

**The grid is AppKit, driven imperatively.** `AssetGridView` wraps an `NSCollectionView`, because `LazyVGrid` doesn't scale to large libraries. Library changes don't go through SwiftUI: `BrowserModel` turns each `PHChange` into `PHFetchResultChangeDetails`, updates `fetchResult`, then calls the coordinator through `AssetGridControlling` to apply batch updates. The data source reads `browser.fetchResult` directly, so the two must change together. `UniformGridLayout` exists because flow layout measures every item; its math lives in the pure, tested `GridMetrics`.

**Writes.** All PhotoKit mutations go through `LibraryActions`, and imports through `ImportWriter`. The UI never updates itself after a write: the change observer delivers the result, including when the user cancels the system's confirmation dialog (nothing changes, and `BrowserModel.present` ignores that error).

**Two routes to the library.** PhotoKit is the default. `PhotosAppBridge` scripts Photos.app for what PhotoKit doesn't expose (titles, descriptions, keywords, file sizes, search, duplicating). It's opt-in through Settings, because it opens Photos and triggers an Automation prompt, so nothing may call it until the user has enabled it. It assumes Photos' `media item` IDs equal `PHAsset.localIdentifier`.

**Menus.** `BrowserModel.assetMenuEntries` defines the photo commands once, and they render both as the SwiftUI menu bar and as the grid's `NSMenu`.

## Rules that aren't obvious from the code

- **Don't touch `PHPhotoLibrary` before access is granted.** Registering an observer or fetching triggers the permission prompt. The app waits for the user to click Allow Access, and `start()` on both models guards on this.
- **Tests must not reach the real library or Photos.app.** `PhotosScript` compile checks run `osacompile` in a separate process, and test scripts use fake IDs. Don't compile Photos scripts with `NSAppleScript` inside the test host: concurrent `NSAppleScript` use in one process can make one instance run another's compiled script, which once made a test send real events to Photos.
- **All `NSAppleScript` use in the app stays on `PhotosAppBridge`'s serial queue**, for the same reason. Tests that execute scripts must be `.serialized`.
- **Caller-supplied text in scripts must go through `PhotosScript.literal`** so it can't alter the script.
- **Don't add menu shortcuts without a modifier.** They can fire while the user types in a text field. `.` (favorite) and Delete (remove from album) are handled in the grid's `keyDown` and the viewer's `onKeyPress` instead.
- **PhotoKit never returns hidden assets here**, even with `includeHiddenAssets` or a fetch of the Hidden album (likely because Photos locks that album, which is the default). So Hide is one-way and asks first, there's no Unhide, and the sidebar has no Hidden album.
- **Grid drag destinations don't read the pasteboard.** Each grid drag item is a file promise plus a `.string`, and SwiftUI can't load that string back. The grid and sidebar albums register for `.string` only to match the drag, then read `BrowserModel.draggedAssetIDs`, which is set while a grid drag is in progress.
- **Fetch predicates and sort descriptors can only use keys PhotoKit supports**, which is why `AssetQuery` offers a limited set. An album can only be reordered while showing its unfiltered manual order (`canReorderCurrentAlbum`).
- **Get approval before running anything that changes the real library.** The system library is the only one PhotoKit can see, and it's the user's actual photos.

## Current status

Tested against a real library of about 11,000 items, with changes limited to a throwaway album and test photos. Browsing, sorting, filtering, album and folder management, import, export, grid batch updates, the Photos.app bridge (including matching IDs), and mouse, keyboard, and drag interaction (to albums, within an album, and to Finder) all work. Not yet tested by hand: Live Photo and video playback in the viewer, importing a real Live Photo pair, the Import panel, Show in Photos, and the delete flow.
