import Foundation
import Observation
import Photos

/// Runs a PhotoKit callback on the main actor, whichever queue it arrives on.
nonisolated enum MainThread {
    static func run(_ body: @escaping @MainActor () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated(body)
        } else {
            DispatchQueue.main.async { MainActor.assumeIsolated(body) }
        }
    }
}

/// Forwards PhotoKit's background-queue callbacks to the main actor.
nonisolated final class PhotoLibraryObserver: NSObject, PHPhotoLibraryChangeObserver, PHPhotoLibraryAvailabilityObserver {
    private let onChange: @MainActor (PHChange) -> Void
    private let onUnavailable: @MainActor (Error?) -> Void

    init(
        onChange: @escaping @MainActor (PHChange) -> Void,
        onUnavailable: @escaping @MainActor (Error?) -> Void = { _ in }
    ) {
        self.onChange = onChange
        self.onUnavailable = onUnavailable
    }

    func photoLibraryDidChange(_ changeInstance: PHChange) {
        let onChange = onChange
        MainThread.run { onChange(changeInstance) }
    }

    func photoLibraryDidBecomeUnavailable(_ photoLibrary: PHPhotoLibrary) {
        let onUnavailable = onUnavailable
        let error = photoLibrary.unavailabilityReason
        MainThread.run { onUnavailable(error) }
    }
}

/// A row in the sidebar: a smart album, album, shared album, or folder.
nonisolated struct CollectionNode: Identifiable, Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        case smartAlbum, album, sharedAlbum, folder
    }

    let id: String
    let title: String
    let symbol: String
    let kind: Kind
    let count: Int?
    let parentID: String?
    /// `nil` for albums, and an array (possibly empty) for folders.
    let children: [CollectionNode]?
    let canAddContent: Bool
    let canRemoveContent: Bool
    let canRearrangeContent: Bool
    let canRename: Bool
    let canDelete: Bool

    var isFolder: Bool { kind == .folder }

    /// This node and everything nested inside it, in display order.
    var flattened: [CollectionNode] {
        [self] + (children ?? []).flatMap(\.flattened)
    }
}

nonisolated struct SidebarSnapshot: Equatable, Sendable {
    var library: [CollectionNode] = []
    var mediaTypes: [CollectionNode] = []
    var utilities: [CollectionNode] = []
    var sharedAlbums: [CollectionNode] = []
    var myAlbums: [CollectionNode] = []
}

/// Builds the sidebar away from the main actor, because counting every album
/// on a large library is too slow for the UI thread.
nonisolated enum SidebarBuilder {
    private static let librarySubtypes: [PHAssetCollectionSubtype] = [
        .smartAlbumFavorites, .smartAlbumRecentlyAdded,
    ]

    private static let mediaTypeSubtypes: [PHAssetCollectionSubtype] = [
        .smartAlbumVideos, .smartAlbumSelfPortraits, .smartAlbumLivePhotos, .smartAlbumDepthEffect,
        .smartAlbumPanoramas, .smartAlbumTimelapses, .smartAlbumSlomoVideos, .smartAlbumCinematic,
        .smartAlbumBursts, .smartAlbumScreenshots, .smartAlbumScreenRecordings, .smartAlbumSpatial,
        .smartAlbumAnimated, .smartAlbumLongExposures, .smartAlbumRAW,
    ]

    private static let utilitySubtypes: [PHAssetCollectionSubtype] = [
        .smartAlbumAllHidden, .smartAlbumUnableToUpload,
    ]

    @concurrent
    static func build() async -> SidebarSnapshot {
        var snapshot = SidebarSnapshot()
        snapshot.library = smartNodes(librarySubtypes, keepEmpty: true)
        snapshot.mediaTypes = smartNodes(mediaTypeSubtypes, keepEmpty: false)
        snapshot.utilities = smartNodes(utilitySubtypes, keepEmpty: false)

        let shared = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumCloudShared, options: nil)
        shared.enumerateObjects { collection, _, _ in
            snapshot.sharedAlbums.append(node(for: collection, kind: .sharedAlbum, parentID: nil))
        }

        let imports = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumImported, options: nil)
        imports.enumerateObjects { collection, _, _ in
            let imported = node(for: collection, kind: .smartAlbum, parentID: nil)
            if (imported.count ?? 0) > 0 { snapshot.utilities.append(imported) }
        }

        snapshot.myAlbums = children(of: PHCollectionList.fetchTopLevelUserCollections(with: nil), parentID: nil)
        return snapshot
    }

    private static func smartNodes(_ subtypes: [PHAssetCollectionSubtype], keepEmpty: Bool) -> [CollectionNode] {
        subtypes.compactMap { subtype in
            let result = PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: subtype, options: nil)
            guard let collection = result.firstObject else { return nil }
            let smart = node(for: collection, kind: .smartAlbum, parentID: nil)
            return keepEmpty || (smart.count ?? 0) > 0 ? smart : nil
        }
    }

    private static func children(of result: PHFetchResult<PHCollection>, parentID: String?) -> [CollectionNode] {
        var nodes: [CollectionNode] = []
        result.enumerateObjects { collection, _, _ in
            if let list = collection as? PHCollectionList {
                let nested = PHCollection.fetchCollections(in: list, options: nil)
                nodes.append(CollectionNode(
                    id: list.localIdentifier,
                    title: list.localizedTitle ?? "Untitled Folder",
                    symbol: "folder",
                    kind: .folder,
                    count: nil,
                    parentID: parentID,
                    children: children(of: nested, parentID: list.localIdentifier),
                    canAddContent: list.canPerform(.addContent),
                    canRemoveContent: list.canPerform(.removeContent),
                    canRearrangeContent: list.canPerform(.rearrangeContent),
                    canRename: list.canPerform(.rename),
                    canDelete: list.canPerform(.delete)
                ))
            } else if let album = collection as? PHAssetCollection {
                nodes.append(node(for: album, kind: .album, parentID: parentID))
            }
        }
        return nodes
    }

    private static func node(
        for collection: PHAssetCollection,
        kind: CollectionNode.Kind,
        parentID: String?
    ) -> CollectionNode {
        let options = PHFetchOptions()
        options.includeHiddenAssets = collection.assetCollectionSubtype == .smartAlbumAllHidden
        return CollectionNode(
            id: collection.localIdentifier,
            title: collection.localizedTitle ?? "Untitled Album",
            symbol: symbol(for: collection, kind: kind),
            kind: kind,
            count: PHAsset.fetchAssets(in: collection, options: options).count,
            parentID: parentID,
            children: nil,
            canAddContent: collection.canPerform(.addContent),
            canRemoveContent: collection.canPerform(.removeContent),
            canRearrangeContent: collection.canPerform(.rearrangeContent),
            canRename: collection.canPerform(.rename),
            canDelete: collection.canPerform(.delete)
        )
    }

    private static func symbol(for collection: PHAssetCollection, kind: CollectionNode.Kind) -> String {
        if kind == .sharedAlbum { return "person.2" }
        switch collection.assetCollectionSubtype {
        case .smartAlbumFavorites: return "heart"
        case .smartAlbumRecentlyAdded: return "clock"
        case .smartAlbumVideos: return "video"
        case .smartAlbumSelfPortraits: return "person.crop.square"
        case .smartAlbumLivePhotos: return "livephoto"
        case .smartAlbumDepthEffect: return "cube"
        case .smartAlbumPanoramas: return "pano"
        case .smartAlbumTimelapses: return "timelapse"
        case .smartAlbumSlomoVideos: return "slowmo"
        case .smartAlbumCinematic: return "film"
        case .smartAlbumBursts: return "square.stack.3d.down.right"
        case .smartAlbumScreenshots: return "camera.viewfinder"
        case .smartAlbumScreenRecordings: return "record.circle"
        case .smartAlbumSpatial: return "cube.transparent"
        case .smartAlbumAnimated: return "square.stack.3d.forward.dottedline"
        case .smartAlbumLongExposures: return "camera.aperture"
        case .smartAlbumRAW: return "r.square"
        case .smartAlbumAllHidden: return "eye.slash"
        case .smartAlbumUnableToUpload: return "exclamationmark.icloud"
        case .albumImported: return "square.and.arrow.down"
        default: return kind == .smartAlbum ? "gearshape" : "rectangle.stack"
        }
    }
}

/// App-wide library state: permission, availability, and the sidebar.
@Observable
final class LibraryStore {
    private(set) var authorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    private(set) var unavailableReason: String?
    private(set) var sidebar = SidebarSnapshot()
    private(set) var hasLoadedSidebar = false

    @ObservationIgnored private var nodesByID: [String: CollectionNode] = [:]
    @ObservationIgnored private var observer: PhotoLibraryObserver?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?

    var isAuthorized: Bool {
        authorization == .authorized || authorization == .limited
    }

    /// Every album that assets can be added to, labelled with its folder path.
    var addableAlbums: [(path: String, node: CollectionNode)] {
        sidebar.myAlbums.flatMap { Self.albumPaths($0, prefix: "") }
            .filter { $0.node.canAddContent }
    }

    /// Every folder, labelled with its path, for the "Move To" menu.
    var allFolders: [(path: String, node: CollectionNode)] {
        sidebar.myAlbums.flatMap { Self.folderPaths($0, prefix: "") }
    }

    func node(id: String) -> CollectionNode? {
        nodesByID[id]
    }

    /// The siblings of a node, in display order.
    func siblings(of node: CollectionNode) -> [CollectionNode] {
        if let parentID = node.parentID {
            return nodesByID[parentID]?.children ?? []
        }
        return sidebar.myAlbums
    }

    func requestAccess() async {
        authorization = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
    }

    /// Starts observing the library. Call only once access is granted, because
    /// registering an observer earlier would trigger the permission prompt.
    func start() {
        guard observer == nil, isAuthorized else { return }
        let observer = PhotoLibraryObserver(
            onChange: { [weak self] _ in self?.scheduleRefresh() },
            onUnavailable: { [weak self] error in
                self?.unavailableReason = error?.localizedDescription ?? "The photo library is no longer available."
            }
        )
        self.observer = observer
        PHPhotoLibrary.shared().register(observer as PHPhotoLibraryChangeObserver)
        PHPhotoLibrary.shared().register(observer as PHPhotoLibraryAvailabilityObserver)
        scheduleRefresh(after: .zero)
    }

    /// Coalesces refreshes, since iCloud sync can deliver many changes quickly.
    private func scheduleRefresh(after delay: Duration = .milliseconds(500)) {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            let snapshot = await SidebarBuilder.build()
            guard !Task.isCancelled, let self else { return }
            self.apply(snapshot)
        }
    }

    private func apply(_ snapshot: SidebarSnapshot) {
        let all = snapshot.library + snapshot.mediaTypes + snapshot.utilities + snapshot.sharedAlbums
            + snapshot.myAlbums.flatMap(\.flattened)
        nodesByID = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        hasLoadedSidebar = true
        if sidebar != snapshot { sidebar = snapshot }
    }

    private static func albumPaths(_ node: CollectionNode, prefix: String) -> [(path: String, node: CollectionNode)] {
        let path = prefix + node.title
        guard let children = node.children else { return [(path, node)] }
        return children.flatMap { albumPaths($0, prefix: path + " / ") }
    }

    private static func folderPaths(_ node: CollectionNode, prefix: String) -> [(path: String, node: CollectionNode)] {
        guard let children = node.children else { return [] }
        let path = prefix + node.title
        return [(path, node)] + children.flatMap { folderPaths($0, prefix: path + " / ") }
    }
}
