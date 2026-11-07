import AppKit
import Photos
import SwiftUI
import UniformTypeIdentifiers

/// Marks a dragged item as coming from the grid, so sidebar albums can accept
/// it. Finder ignores this and uses the file promise on the same item.
nonisolated enum AssetDragPayload {
    private static let prefix = "phototool-asset:"

    static func encode(id: String) -> String {
        prefix + id
    }

    static func decode(_ strings: [String]) -> [String] {
        strings.filter { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
    }
}

/// The photo grid. `NSCollectionView` is used over `LazyVGrid` because it stays
/// fast at hundreds of thousands of items and has native marquee selection and
/// drag and drop.
struct AssetGridView: NSViewRepresentable {
    let browser: BrowserModel
    let thumbnailSize: CGFloat
    let square: Bool

    func makeCoordinator() -> AssetGridCoordinator {
        AssetGridCoordinator(browser: browser)
    }

    func makeNSView(context: Context) -> NSScrollView {
        context.coordinator.makeScrollView(thumbnailSize: thumbnailSize, square: square)
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.update(thumbnailSize: thumbnailSize, square: square)
    }
}

/// Adds the keyboard, double-click, and context menu behavior AppKit leaves to apps.
final class AssetCollectionView: NSCollectionView {
    var onOpen: ((Int) -> Void)?
    var onMove: ((_ delta: Int, _ extend: Bool) -> Void)?
    var onSelectionChanged: (() -> Void)?
    var onToggleFavorite: (() -> Void)?
    var onRemoveFromAlbum: (() -> Void)?
    var menuProvider: (() -> NSMenu?)?
    var columns: () -> Int = { 1 }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        guard event.clickCount == 2 else { return }
        let point = convert(event.locationInWindow, from: nil)
        if let indexPath = indexPathForItem(at: point) {
            onOpen?(indexPath.item)
        }
    }

    override func keyDown(with event: NSEvent) {
        let extend = event.modifierFlags.contains(.shift)
        switch event.specialKey {
        case .leftArrow: onMove?(-1, extend)
        case .rightArrow: onMove?(1, extend)
        case .upArrow: onMove?(-columns(), extend)
        case .downArrow: onMove?(columns(), extend)
        case .carriageReturn, .enter: openFirstSelected()
        // These two have no modifier, so they live here and not in the menu
        // bar, where they could fire while the user types in a text field.
        case .delete: onRemoveFromAlbum?()
        default:
            switch event.charactersIgnoringModifiers {
            case " ": openFirstSelected()
            case ".": onToggleFavorite?()
            default: super.keyDown(with: event)
            }
        }
    }

    override func selectAll(_ sender: Any?) {
        super.selectAll(sender)
        onSelectionChanged?()
    }

    private func openFirstSelected() {
        if let first = selectionIndexPaths.map(\.item).min() {
            onOpen?(first)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        guard let indexPath = indexPathForItem(at: point) else { return nil }
        if !selectionIndexPaths.contains(indexPath) {
            selectionIndexPaths = [indexPath]
            onSelectionChanged?()
        }
        return menuProvider?()
    }
}

/// A dragged asset. It's a file promise for Finder and other apps, and also
/// carries the asset ID for drops on sidebar albums.
final class AssetDragItem: NSFilePromiseProvider {
    override func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        super.writableTypes(for: pasteboard) + [.string]
    }

    override func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        if type == .string, let asset = userInfo as? PHAsset {
            return AssetDragPayload.encode(id: asset.localIdentifier)
        }
        return super.pasteboardPropertyList(forType: type)
    }
}

/// Writes promised files. AppKit calls this off the main thread.
nonisolated final class AssetPromiseDelegate: NSObject, NSFilePromiseProviderDelegate {
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.qualityOfService = .userInitiated
        return queue
    }()

    func filePromiseProvider(_ provider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        guard let asset = provider.userInfo as? PHAsset else { return "Untitled" }
        let originalName = AssetFiles.originalName(for: asset)
        guard let resource = AssetFiles.resources(for: asset, version: .current).first else { return originalName }
        return ExportSelection.fileName(resourceName: resource.originalFilename, originalName: originalName)
    }

    func filePromiseProvider(
        _ provider: NSFilePromiseProvider,
        writePromiseTo url: URL,
        completionHandler: @escaping @Sendable ((any Error)?) -> Void
    ) {
        guard let asset = provider.userInfo as? PHAsset,
              let resource = AssetFiles.resources(for: asset, version: .current).first else {
            completionHandler(CocoaError(.fileNoSuchFile))
            return
        }
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        PHAssetResourceManager.default().writeData(for: resource, toFile: url, options: options, completionHandler: completionHandler)
    }

    func operationQueue(for provider: NSFilePromiseProvider) -> OperationQueue {
        queue
    }
}

final class AssetGridCoordinator: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegate, NSCollectionViewPrefetching, AssetGridControlling {
    private let browser: BrowserModel
    private let layout = UniformGridLayout()
    private let collectionView = AssetCollectionView()
    private let imageManager = PHCachingImageManager()
    private let promiseDelegate = AssetPromiseDelegate()
    private var square = true
    /// Where a Shift-selection range starts.
    private var anchorIndex: Int?
    /// The item the arrow keys move from.
    private var focusIndex: Int?

    init(browser: BrowserModel) {
        self.browser = browser
        super.init()
        browser.grid = self
    }

    func makeScrollView(thumbnailSize: CGFloat, square: Bool) -> NSScrollView {
        self.square = square
        layout.targetSide = thumbnailSize

        collectionView.collectionViewLayout = layout
        collectionView.register(AssetGridItem.self, forItemWithIdentifier: AssetGridItem.identifier)
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.prefetchDataSource = self
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = true
        collectionView.allowsEmptySelection = true
        collectionView.backgroundColors = [.clear]
        collectionView.registerForDraggedTypes([.fileURL])
        collectionView.setDraggingSourceOperationMask([.copy], forLocal: false)
        collectionView.setDraggingSourceOperationMask([.copy, .move], forLocal: true)
        collectionView.setAccessibilityLabel("Photos")

        collectionView.columns = { [weak layout] in layout?.metrics.columns ?? 1 }
        collectionView.onOpen = { [weak browser] in browser?.openViewer(at: $0) }
        collectionView.onMove = { [weak self] delta, extend in self?.moveFocus(by: delta, extend: extend) }
        collectionView.onSelectionChanged = { [weak self] in self?.syncSelection() }
        collectionView.onToggleFavorite = { [weak browser] in
            if browser?.hasTargets == true { browser?.toggleFavorite() }
        }
        collectionView.onRemoveFromAlbum = { [weak browser] in
            if browser?.hasTargets == true { browser?.removeTargetsFromCurrentAlbum() }
        }
        collectionView.menuProvider = { [weak browser] in
            browser.map { NSMenu(entries: $0.assetMenuEntries) }
        }

        let scrollView = NSScrollView()
        scrollView.documentView = collectionView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.contentView.postsBoundsChangedNotifications = false
        return scrollView
    }

    func update(thumbnailSize: CGFloat, square: Bool) {
        let squareChanged = self.square != square
        guard layout.targetSide != thumbnailSize || squareChanged else { return }

        // Keep the same photo at the top as the grid reflows.
        let firstVisible = layout.metrics.indexRange(in: collectionView.visibleRect).lowerBound
        let isSizeChange = layout.targetSide != thumbnailSize
        self.square = square
        layout.targetSide = thumbnailSize
        imageManager.stopCachingImagesForAllAssets()
        collectionView.layoutSubtreeIfNeeded()
        refreshVisibleItems()
        if isSizeChange, firstVisible < (browser.fetchResult?.count ?? 0) {
            collectionView.scrollToItems(at: [IndexPath(item: firstVisible, section: 0)], scrollPosition: .top)
        }
    }

    /// Thumbnail sizes snap to steps, so the slider doesn't re-request images
    /// on every tick and the cache can be reused across sizes.
    private var targetSize: CGSize {
        let scale = collectionView.window?.backingScaleFactor ?? 2
        let pixels = max(layout.metrics.side, 1) * scale
        let step: CGFloat = 128
        let snapped = (pixels / step).rounded(.up) * step
        return CGSize(width: snapped, height: snapped)
    }

    private var contentMode: PHImageContentMode {
        square ? .aspectFill : .aspectFit
    }

    private func refreshVisibleItems() {
        guard let result = browser.fetchResult else { return }
        for indexPath in collectionView.indexPathsForVisibleItems() where indexPath.item < result.count {
            if let item = collectionView.item(at: indexPath) as? AssetGridItem {
                item.configure(asset: result.object(at: indexPath.item), manager: imageManager, targetSize: targetSize, fill: square)
            }
        }
    }

    // MARK: AssetGridControlling

    func reloadAll(selecting ids: Set<String>) {
        imageManager.stopCachingImagesForAllAssets()
        anchorIndex = nil
        focusIndex = nil
        collectionView.reloadData()
        guard !ids.isEmpty, let result = browser.fetchResult else {
            syncSelection()
            return
        }
        var indexPaths = Set<IndexPath>()
        result.enumerateObjects { asset, index, _ in
            if ids.contains(asset.localIdentifier) {
                indexPaths.insert(IndexPath(item: index, section: 0))
            }
        }
        collectionView.selectionIndexPaths = indexPaths
        syncSelection()
    }

    func apply(_ details: PHFetchResultChangeDetails<PHAsset>) {
        let removed = details.removedIndexes ?? []
        let inserted = details.insertedIndexes ?? []
        // A huge batch animates badly and is slower than reloading.
        guard removed.count + inserted.count < 1000 else {
            reloadAll(selecting: [])
            return
        }
        if !removed.isEmpty || !inserted.isEmpty || details.hasMoves {
            collectionView.performBatchUpdates {
                if !removed.isEmpty { collectionView.deleteItems(at: Self.indexPaths(removed)) }
                if !inserted.isEmpty { collectionView.insertItems(at: Self.indexPaths(inserted)) }
                details.enumerateMoves { from, to in
                    self.collectionView.moveItem(
                        at: IndexPath(item: from, section: 0),
                        to: IndexPath(item: to, section: 0)
                    )
                }
            } completionHandler: { [weak self] _ in
                self?.syncSelection()
            }
        }
        // `changedIndexes` refers to positions after the update above.
        if let changed = details.changedIndexes, let result = browser.fetchResult {
            for index in changed where index < result.count {
                if let item = collectionView.item(at: IndexPath(item: index, section: 0)) as? AssetGridItem {
                    item.configure(asset: result.object(at: index), manager: imageManager, targetSize: targetSize, fill: square)
                }
            }
        }
    }

    func reveal(index: Int) {
        let indexPath = IndexPath(item: index, section: 0)
        collectionView.selectionIndexPaths = [indexPath]
        anchorIndex = index
        focusIndex = index
        collectionView.scrollToItems(at: [indexPath], scrollPosition: .nearestHorizontalEdge)
        syncSelection()
    }

    func clearSelection() {
        collectionView.selectionIndexPaths = []
        anchorIndex = nil
        focusIndex = nil
        syncSelection()
    }

    func focusGrid() {
        collectionView.window?.makeFirstResponder(collectionView)
    }

    private static func indexPaths(_ indexes: IndexSet) -> Set<IndexPath> {
        Set(indexes.map { IndexPath(item: $0, section: 0) })
    }

    private func syncSelection() {
        browser.gridSelectionChanged(IndexSet(collectionView.selectionIndexPaths.map(\.item)))
    }

    private func moveFocus(by delta: Int, extend: Bool) {
        let current = focusIndex ?? (delta > 0 ? browser.selection.last : browser.selection.first)
        guard let next = layout.metrics.index(from: current, delta: delta) else { return }
        if extend, let anchor = anchorIndex ?? current {
            anchorIndex = anchor
            let range = min(anchor, next)...max(anchor, next)
            collectionView.selectionIndexPaths = Set(range.map { IndexPath(item: $0, section: 0) })
        } else {
            anchorIndex = next
            collectionView.selectionIndexPaths = [IndexPath(item: next, section: 0)]
        }
        focusIndex = next
        collectionView.scrollToItems(at: [IndexPath(item: next, section: 0)], scrollPosition: .nearestHorizontalEdge)
        syncSelection()
    }

    // MARK: Data source

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        browser.fetchResult?.count ?? 0
    }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: AssetGridItem.identifier, for: indexPath)
        if let item = item as? AssetGridItem, let result = browser.fetchResult, indexPath.item < result.count {
            item.configure(asset: result.object(at: indexPath.item), manager: imageManager, targetSize: targetSize, fill: square)
        }
        return item
    }

    // MARK: Prefetching

    private func assets(at indexPaths: [IndexPath]) -> [PHAsset] {
        guard let result = browser.fetchResult else { return [] }
        return indexPaths.lazy.map(\.item).filter { $0 < result.count }.map { result.object(at: $0) }
    }

    func collectionView(_ collectionView: NSCollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
        imageManager.startCachingImages(for: assets(at: indexPaths), targetSize: targetSize, contentMode: contentMode, options: nil)
    }

    func collectionView(_ collectionView: NSCollectionView, cancelPrefetchingForItemsAt indexPaths: [IndexPath]) {
        imageManager.stopCachingImages(for: assets(at: indexPaths), targetSize: targetSize, contentMode: contentMode, options: nil)
    }

    // MARK: Selection

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        if let index = indexPaths.map(\.item).min() {
            anchorIndex = index
            focusIndex = index
        }
        syncSelection()
    }

    func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) {
        syncSelection()
    }

    // MARK: Dragging out

    func collectionView(_ collectionView: NSCollectionView, canDragItemsAt indexPaths: Set<IndexPath>, with event: NSEvent) -> Bool {
        true
    }

    func collectionView(_ collectionView: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath) -> (any NSPasteboardWriting)? {
        guard let result = browser.fetchResult, indexPath.item < result.count else { return nil }
        let asset = result.object(at: indexPath.item)
        let fileType = AssetFiles.resources(for: asset, version: .current).first?.uniformTypeIdentifier
            ?? UTType.data.identifier
        let item = AssetDragItem(fileType: fileType, delegate: promiseDelegate)
        item.userInfo = asset
        return item
    }

    // MARK: Dropping in

    func collectionView(
        _ collectionView: NSCollectionView,
        validateDrop draggingInfo: any NSDraggingInfo,
        proposedIndexPath proposedDropIndexPath: AutoreleasingUnsafeMutablePointer<NSIndexPath>,
        dropOperation proposedDropOperation: UnsafeMutablePointer<NSCollectionView.DropOperation>
    ) -> NSDragOperation {
        if draggingInfo.draggingSource as? NSCollectionView === collectionView {
            guard browser.canReorderCurrentAlbum else { return [] }
            proposedDropOperation.pointee = .before
            return .move
        }
        let hasFiles = draggingInfo.draggingPasteboard.canReadObject(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        )
        return hasFiles ? .copy : []
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        acceptDrop draggingInfo: any NSDraggingInfo,
        indexPath: IndexPath,
        dropOperation: NSCollectionView.DropOperation
    ) -> Bool {
        if draggingInfo.draggingSource as? NSCollectionView === collectionView {
            browser.reorderCurrentAlbum(moving: browser.selection, toGap: indexPath.item)
            return true
        }
        let urls = draggingInfo.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] ?? []
        guard !urls.isEmpty else { return false }
        browser.importFiles(urls)
        return true
    }
}
