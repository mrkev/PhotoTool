import AppKit
import CoreLocation
import Observation
import Photos

/// The grid's AppKit controller, driven imperatively so library changes can be
/// applied as batch updates rather than through SwiftUI's diffing.
protocol AssetGridControlling: AnyObject {
    func reloadAll(selecting ids: Set<String>)
    func apply(_ details: PHFetchResultChangeDetails<PHAsset>)
    func reveal(index: Int)
    func clearSelection()
    func focusGrid()
}

/// A long-running import or export.
@Observable
final class Activity {
    let title: String
    var completed = 0
    var total = 0
    var failures: [String] = []
    @ObservationIgnored var task: Task<Void, Never>?

    init(title: String) {
        self.title = title
    }
}

struct AlertInfo: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

enum ActiveSheet: Identifiable {
    case newAlbum(parentID: String?, assets: [PHAsset])
    case newFolder(parentID: String?)
    case rename(CollectionNode)
    case adjustDate([PHAsset])
    case adjustLocation([PHAsset])
    case addKeywords([PHAsset])
    case dateFilter

    var id: String {
        switch self {
        case .newAlbum: "newAlbum"
        case .newFolder: "newFolder"
        case .rename(let node): "rename-\(node.id)"
        case .adjustDate: "adjustDate"
        case .adjustLocation: "adjustLocation"
        case .addKeywords: "addKeywords"
        case .dateFilter: "dateFilter"
        }
    }
}

/// State and commands for the browser: what's shown, what's selected, and the
/// actions the menus, toolbar, and grid all share.
@Observable
final class BrowserModel {
    let store: LibraryStore

    private(set) var source: LibrarySource = .allPhotos
    private(set) var fetchResult: PHFetchResult<PHAsset>?
    private(set) var selection = IndexSet()
    private(set) var isSearching = false

    var query = AssetQuery() {
        didSet {
            if query != oldValue, !isChangingSource { reload() }
        }
    }
    var searchText = ""
    var viewerAsset: PHAsset?
    var showInspector = true
    var activeSheet: ActiveSheet?
    var alert: AlertInfo?
    var activity: Activity?

    var thumbnailSize: Double {
        didSet { UserDefaults.standard.set(thumbnailSize, forKey: "thumbnailSize") }
    }
    var squareThumbnails: Bool {
        didSet { UserDefaults.standard.set(squareThumbnails, forKey: "squareThumbnails") }
    }

    static let thumbnailRange = 80.0...480.0

    @ObservationIgnored weak var grid: (any AssetGridControlling)?
    @ObservationIgnored private var observer: PhotoLibraryObserver?
    @ObservationIgnored private var isChangingSource = false
    /// Where to return when leaving search results or a burst.
    @ObservationIgnored private var returnSource: LibrarySource = .allPhotos

    init(store: LibraryStore) {
        self.store = store
        let defaults = UserDefaults.standard
        let savedSize = defaults.double(forKey: "thumbnailSize")
        thumbnailSize = savedSize > 0 ? savedSize : 180
        squareThumbnails = defaults.object(forKey: "squareThumbnails") as? Bool ?? true
    }

    // MARK: Loading

    /// Call only once access is granted.
    func start() {
        guard observer == nil, store.isAuthorized else { return }
        let observer = PhotoLibraryObserver(onChange: { [weak self] change in self?.handle(change) })
        self.observer = observer
        PHPhotoLibrary.shared().register(observer as PHPhotoLibraryChangeObserver)
        reload()
    }

    func reload() {
        guard store.isAuthorized else { return }
        fetchResult = makeFetchResult()
        selection = []
        viewerAsset = nil
        grid?.reloadAll(selecting: [])
    }

    func show(_ newSource: LibrarySource) {
        guard newSource != source else { return }
        switch newSource {
        case .allPhotos, .collection: returnSource = newSource
        case .burst, .search: break
        }
        source = newSource

        isChangingSource = true
        if currentAlbumAllowsManualOrder {
            query.sortKey = .albumOrder
            query.ascending = true
        } else if query.sortKey == .albumOrder {
            query.sortKey = .dateTaken
            query.ascending = false
        }
        isChangingSource = false
        reload()
    }

    /// Leaves search results or a burst and returns to the previous source.
    func showPreviousSource() {
        searchText = ""
        show(returnSource)
    }

    /// Falls back to All Photos if the album on screen was deleted.
    func sidebarDidChange() {
        if case .collection(let id) = source, store.hasLoadedSidebar, store.node(id: id) == nil {
            show(.allPhotos)
        }
    }

    private func makeFetchResult() -> PHFetchResult<PHAsset> {
        switch source {
        case .allPhotos:
            return PHAsset.fetchAssets(with: query.fetchOptions())
        case .collection(let id):
            guard let collection = PHAssetCollection.fetchAssetCollections(
                withLocalIdentifiers: [id], options: nil
            ).firstObject else {
                return PHAsset.fetchAssets(withLocalIdentifiers: [], options: nil)
            }
            let includeHidden = collection.assetCollectionSubtype == .smartAlbumAllHidden
            return PHAsset.fetchAssets(in: collection, options: query.fetchOptions(includeHidden: includeHidden))
        case .burst(let id):
            return PHAsset.fetchAssets(withBurstIdentifier: id, options: query.fetchOptions(includeAllBursts: true))
        case .search(_, let ids):
            return PHAsset.fetchAssets(withLocalIdentifiers: ids, options: query.fetchOptions())
        }
    }

    private func handle(_ change: PHChange) {
        guard let current = fetchResult, let details = change.changeDetails(for: current) else { return }
        let previousIDs = details.hasIncrementalChanges ? [] : selectedIDs(in: current)
        fetchResult = details.fetchResultAfterChanges
        if details.hasIncrementalChanges {
            grid?.apply(details)
        } else {
            grid?.reloadAll(selecting: previousIDs)
        }
        reconcileViewer(previous: current)
    }

    /// Keeps the viewer valid after a change, moving on if its asset is gone.
    private func reconcileViewer(previous: PHFetchResult<PHAsset>) {
        guard let asset = viewerAsset, let result = fetchResult else { return }
        let index = result.index(of: asset)
        if index != NSNotFound {
            viewerAsset = result.object(at: index)
            return
        }
        let oldIndex = previous.index(of: asset)
        if oldIndex != NSNotFound, result.count > 0 {
            viewerAsset = result.object(at: min(oldIndex, result.count - 1))
        } else {
            viewerAsset = nil
        }
    }

    private func selectedIDs(in result: PHFetchResult<PHAsset>) -> Set<String> {
        let valid = selection.filter { $0 < result.count }
        return Set(result.objects(at: IndexSet(valid)).map(\.localIdentifier))
    }

    // MARK: Display

    var title: String {
        switch source {
        case .allPhotos: "All Photos"
        case .collection(let id): store.node(id: id)?.title ?? "Album"
        case .burst: "Burst"
        case .search(let query, _): "Search: \(query)"
        }
    }

    var subtitle: String {
        let total = fetchResult?.count ?? 0
        let items = "\(total.formatted()) \(total == 1 ? "item" : "items")"
        return selection.isEmpty ? items : "\(selection.count.formatted()) of \(items) selected"
    }

    var isShowingTemporarySource: Bool {
        switch source {
        case .burst, .search: true
        case .allPhotos, .collection: false
        }
    }

    /// The sidebar row to highlight. Search and burst views have no row.
    var sidebarSelection: LibrarySource? {
        isShowingTemporarySource ? nil : source
    }

    var currentNode: CollectionNode? {
        if case .collection(let id) = source { return store.node(id: id) }
        return nil
    }

    var currentAlbumAllowsManualOrder: Bool {
        guard let node = currentNode, node.kind == .album else { return false }
        return node.canRearrangeContent
    }

    /// PhotoKit can only reorder an album when viewing its full, manual order.
    var canReorderCurrentAlbum: Bool {
        currentAlbumAllowsManualOrder && query.sortKey == .albumOrder && query.isUnfiltered
    }

    // MARK: Selection

    func gridSelectionChanged(_ indexes: IndexSet) {
        if selection != indexes { selection = indexes }
    }

    var selectedAssets: [PHAsset] {
        guard let fetchResult else { return [] }
        return fetchResult.objects(at: IndexSet(selection.filter { $0 < fetchResult.count }))
    }

    /// What commands act on: the photo in the viewer, or else the selection.
    var targetAssets: [PHAsset] {
        viewerAsset.map { [$0] } ?? selectedAssets
    }

    var hasTargets: Bool {
        viewerAsset != nil || !selection.isEmpty
    }

    /// Reads just the first target, so menus stay fast after Select All.
    var firstTarget: PHAsset? {
        if let viewerAsset { return viewerAsset }
        guard let index = selection.first, let fetchResult, index < fetchResult.count else { return nil }
        return fetchResult.object(at: index)
    }

    func deselectAll() {
        grid?.clearSelection()
    }

    // MARK: Viewer

    func openViewer(at index: Int) {
        guard let fetchResult, index >= 0, index < fetchResult.count else { return }
        viewerAsset = fetchResult.object(at: index)
    }

    func closeViewer() {
        if let asset = viewerAsset, let fetchResult {
            let index = fetchResult.index(of: asset)
            if index != NSNotFound { grid?.reveal(index: index) }
        }
        viewerAsset = nil
        grid?.focusGrid()
    }

    func moveViewer(by delta: Int) {
        guard let asset = viewerAsset, let fetchResult else { return }
        let next = fetchResult.index(of: asset) + delta
        guard next >= 0, next < fetchResult.count else { return }
        viewerAsset = fetchResult.object(at: next)
    }

    // MARK: Asset actions

    func toggleFavorite() {
        let assets = targetAssets
        let newValue = !assets.allSatisfy(\.isFavorite)
        perform { try await LibraryActions.setFavorite(assets, newValue) }
    }

    func toggleHidden() {
        let assets = targetAssets
        let newValue = !assets.allSatisfy(\.isHidden)
        perform { try await LibraryActions.setHidden(assets, newValue) }
    }

    func deleteTargets() {
        let assets = targetAssets
        perform { try await LibraryActions.delete(assets) }
    }

    func add(_ assets: [PHAsset], toAlbum albumID: String) {
        perform { try await LibraryActions.add(assets, toAlbum: albumID) }
    }

    /// Handles assets dragged from the grid onto a sidebar album.
    func addDraggedAssets(ids: [String], toAlbum albumID: String) {
        let result = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        let assets = result.objects(at: IndexSet(integersIn: 0..<result.count))
        add(assets, toAlbum: albumID)
    }

    func removeTargetsFromCurrentAlbum() {
        guard let node = currentNode, node.canRemoveContent else { return }
        let assets = targetAssets
        perform { try await LibraryActions.remove(assets, fromAlbum: node.id) }
    }

    func reorderCurrentAlbum(moving indexes: IndexSet, toGap gap: Int) {
        guard canReorderCurrentAlbum, let node = currentNode else { return }
        perform { try await LibraryActions.reorder(albumID: node.id, moving: indexes, toGap: gap) }
    }

    func adjustDates(_ assets: [PHAsset], _ adjustment: DateAdjustment) {
        perform { try await LibraryActions.adjustDates(assets, adjustment) }
    }

    func setLocation(_ assets: [PHAsset], _ location: CLLocation?) {
        perform { try await LibraryActions.setLocation(assets, location) }
    }

    // MARK: Album actions

    func createAlbum(title: String, parentID: String?, assets: [PHAsset]) {
        perform { try await LibraryActions.createAlbum(title: title, parentID: parentID, assets: assets) }
    }

    func createFolder(title: String, parentID: String?) {
        perform { try await LibraryActions.createFolder(title: title, parentID: parentID) }
    }

    func rename(_ node: CollectionNode, to title: String) {
        perform { try await LibraryActions.rename(node, to: title) }
    }

    func delete(_ node: CollectionNode) {
        perform { try await LibraryActions.delete(node) }
    }

    func move(_ node: CollectionNode, toParent parentID: String?) {
        perform { try await LibraryActions.move(node, toParent: parentID) }
    }

    /// Moves a node up (`-1`) or down (`+1`) among its siblings.
    func moveSibling(_ node: CollectionNode, by delta: Int) {
        let siblings = store.siblings(of: node)
        guard let index = siblings.firstIndex(where: { $0.id == node.id }) else { return }
        let destination = index + delta
        guard siblings.indices.contains(destination) else { return }
        perform { try await LibraryActions.moveSibling(node, from: index, to: destination) }
    }

    // MARK: Import and export

    func chooseFilesToImport() {
        let panel = NSOpenPanel()
        panel.title = "Import to Library"
        panel.prompt = "Import"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        importFiles(panel.urls)
    }

    /// Imports into the current album when it accepts new items.
    func importFiles(_ urls: [URL]) {
        let albumID = currentNode.flatMap { $0.canAddContent ? $0.id : nil }
        startActivity(title: "Importing") { activity in
            await AssetImporter.run(urls: urls, albumID: albumID, activity: activity)
        }
    }

    func chooseExportDestination(version: ExportVersion) {
        let assets = targetAssets
        guard !assets.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.title = version == .original ? "Export Originals" : "Export"
        panel.prompt = "Export"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let directory = panel.url else { return }
        startActivity(title: "Exporting") { activity in
            await AssetExporter.run(assets: assets, to: directory, version: version, activity: activity)
        }
    }

    private func startActivity(title: String, _ work: @escaping (Activity) async -> Void) {
        guard activity == nil else {
            alert = AlertInfo(title: "Another Task Is Running", message: "Wait for it to finish, or cancel it, and try again.")
            return
        }
        let activity = Activity(title: title)
        self.activity = activity
        activity.task = Task {
            await work(activity)
            self.activity = nil
            if !activity.failures.isEmpty {
                let shown = activity.failures.prefix(10).joined(separator: "\n")
                let hiddenCount = activity.failures.count - 10
                let more = hiddenCount > 0 ? "\n…and \(hiddenCount) more" : ""
                self.alert = AlertInfo(title: "\(title) Finished with Problems", message: shown + more)
            }
        }
    }

    // MARK: Photos.app features

    var isPhotosAppEnabled: Bool {
        UserDefaults.standard.bool(forKey: PhotosAppBridge.enabledKey)
    }

    func runSearch() {
        let text = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            clearSearch()
            return
        }
        guard isPhotosAppEnabled else {
            alert = AlertInfo(
                title: "Search Uses Photos",
                message: "PhotoKit has no search, so this runs through the Photos app. Turn on Photos integration in Settings to use it."
            )
            return
        }
        isSearching = true
        Task {
            defer { isSearching = false }
            do {
                let ids = try await PhotosAppBridge.shared.search(text)
                show(.search(query: text, assetIDs: ids))
            } catch {
                present(error)
            }
        }
    }

    func clearSearch() {
        if case .search = source { showPreviousSource() }
    }

    func duplicateTargets() {
        let ids = targetAssets.map(\.localIdentifier)
        perform { try await PhotosAppBridge.shared.duplicate(ids: ids) }
    }

    func revealInPhotos() {
        guard let id = firstTarget?.localIdentifier else { return }
        perform { try await PhotosAppBridge.shared.reveal(id: id) }
    }

    func addKeywords(_ keywords: [String], to assets: [PHAsset]) {
        let ids = assets.map(\.localIdentifier)
        perform { try await PhotosAppBridge.shared.addKeywords(keywords, to: ids) }
    }

    // MARK: Errors

    private func perform(_ work: @escaping () async throws -> Void) {
        Task {
            do {
                try await work()
            } catch {
                present(error)
            }
        }
    }

    func present(_ error: Error) {
        let nsError = error as NSError
        // The user chose Cancel in the system's confirmation dialog.
        if nsError.domain == PHPhotosErrorDomain, nsError.code == PHPhotosError.Code.userCancelled.rawValue {
            return
        }
        alert = AlertInfo(title: "Couldn't Complete That", message: error.localizedDescription)
    }
}
