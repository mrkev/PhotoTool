import CoreLocation
import Foundation
import Photos

nonisolated enum LibraryActionError: LocalizedError {
    case collectionNotFound

    var errorDescription: String? {
        "That album or folder no longer exists."
    }
}

/// Every PhotoKit write the app makes. `performChanges` runs its block on a
/// private queue, so these stay off the main actor. Nothing here touches pixel
/// data: the app manages the library but doesn't edit photos.
nonisolated enum LibraryActions {
    // MARK: Assets

    static func setFavorite(_ assets: [PHAsset], _ isFavorite: Bool) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            for asset in assets {
                PHAssetChangeRequest(for: asset).isFavorite = isFavorite
            }
        }
    }

    static func setHidden(_ assets: [PHAsset], _ isHidden: Bool) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            for asset in assets {
                PHAssetChangeRequest(for: asset).isHidden = isHidden
            }
        }
    }

    /// Moves assets to Recently Deleted. The system asks the user to confirm.
    static func delete(_ assets: [PHAsset]) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.deleteAssets(assets as NSArray)
        }
    }

    static func adjustDates(_ assets: [PHAsset], _ adjustment: DateAdjustment) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            for asset in assets {
                PHAssetChangeRequest(for: asset).creationDate = adjustment.apply(to: asset.creationDate)
            }
        }
    }

    /// Pass `nil` to remove the location.
    static func setLocation(_ assets: [PHAsset], _ location: CLLocation?) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            for asset in assets {
                PHAssetChangeRequest(for: asset).location = location
            }
        }
    }

    // MARK: Album contents

    static func add(_ assets: [PHAsset], toAlbum albumID: String) async throws {
        let album = try fetchAlbum(albumID)
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetCollectionChangeRequest(for: album)?.addAssets(assets as NSArray)
        }
    }

    static func remove(_ assets: [PHAsset], fromAlbum albumID: String) async throws {
        let album = try fetchAlbum(albumID)
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetCollectionChangeRequest(for: album)?.removeAssets(assets as NSArray)
        }
    }

    /// `gap` is the position between items that the assets were dropped into.
    static func reorder(albumID: String, moving indexes: IndexSet, toGap gap: Int) async throws {
        guard !ReorderMath.isNoOp(moving: indexes, toGap: gap) else { return }
        let album = try fetchAlbum(albumID)
        let current = PHAsset.fetchAssets(in: album, options: nil)
        let destination = ReorderMath.destinationIndex(moving: indexes, toGap: gap)
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetCollectionChangeRequest(for: album, assets: current)?
                .moveAssets(at: indexes, to: destination)
        }
    }

    // MARK: Albums and folders

    static func createAlbum(title: String, parentID: String?, assets: [PHAsset]) async throws {
        let parent = try parentID.map(fetchFolder)
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: title)
            if !assets.isEmpty {
                request.addAssets(assets as NSArray)
            }
            if let parent {
                PHCollectionListChangeRequest(for: parent)?
                    .addChildCollections([request.placeholderForCreatedAssetCollection] as NSArray)
            }
        }
    }

    static func createFolder(title: String, parentID: String?) async throws {
        let parent = try parentID.map(fetchFolder)
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHCollectionListChangeRequest.creationRequestForCollectionList(withTitle: title)
            if let parent {
                PHCollectionListChangeRequest(for: parent)?
                    .addChildCollections([request.placeholderForCreatedCollectionList] as NSArray)
            }
        }
    }

    static func rename(_ node: CollectionNode, to title: String) async throws {
        if node.isFolder {
            let folder = try fetchFolder(node.id)
            try await PHPhotoLibrary.shared().performChanges {
                PHCollectionListChangeRequest(for: folder)?.title = title
            }
        } else {
            let album = try fetchAlbum(node.id)
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetCollectionChangeRequest(for: album)?.title = title
            }
        }
    }

    /// Deletes the album or folder but not the photos in it.
    static func delete(_ node: CollectionNode) async throws {
        if node.isFolder {
            let folder = try fetchFolder(node.id)
            try await PHPhotoLibrary.shared().performChanges {
                PHCollectionListChangeRequest.deleteCollectionLists([folder] as NSArray)
            }
        } else {
            let album = try fetchAlbum(node.id)
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetCollectionChangeRequest.deleteAssetCollections([album] as NSArray)
            }
        }
    }

    /// Moves an album or folder into another folder, or to the top level when
    /// `newParentID` is `nil`.
    static func move(_ node: CollectionNode, toParent newParentID: String?) async throws {
        guard node.parentID != newParentID else { return }
        let collection = try fetchCollection(node)
        let oldParent = try node.parentID.map(fetchFolder)
        let newParent = try newParentID.map(fetchFolder)
        let topLevel = PHCollectionList.fetchTopLevelUserCollections(with: nil)
        try await PHPhotoLibrary.shared().performChanges {
            if let newParent {
                PHCollectionListChangeRequest(for: newParent)?.addChildCollections([collection] as NSArray)
            } else {
                PHCollectionListChangeRequest(forTopLevelCollectionListUserCollections: topLevel)?
                    .addChildCollections([collection] as NSArray)
            }
            if let oldParent {
                PHCollectionListChangeRequest(for: oldParent)?.removeChildCollections([collection] as NSArray)
            } else {
                PHCollectionListChangeRequest(forTopLevelCollectionListUserCollections: topLevel)?
                    .removeChildCollections([collection] as NSArray)
            }
        }
    }

    /// Moves an album or folder up or down among its siblings.
    static func moveSibling(_ node: CollectionNode, from index: Int, to destination: Int) async throws {
        let moving = IndexSet(integer: index)
        if let parentID = node.parentID {
            let parent = try fetchFolder(parentID)
            let children = PHCollection.fetchCollections(in: parent, options: nil)
            try await PHPhotoLibrary.shared().performChanges {
                PHCollectionListChangeRequest(for: parent, childCollections: children)?
                    .moveChildCollections(at: moving, to: destination)
            }
        } else {
            let topLevel = PHCollectionList.fetchTopLevelUserCollections(with: nil)
            try await PHPhotoLibrary.shared().performChanges {
                PHCollectionListChangeRequest(forTopLevelCollectionListUserCollections: topLevel)?
                    .moveChildCollections(at: moving, to: destination)
            }
        }
    }

    // MARK: Lookups

    private static func fetchAlbum(_ id: String) throws -> PHAssetCollection {
        guard let album = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [id], options: nil).firstObject else {
            throw LibraryActionError.collectionNotFound
        }
        return album
    }

    private static func fetchFolder(_ id: String) throws -> PHCollectionList {
        guard let folder = PHCollectionList.fetchCollectionLists(withLocalIdentifiers: [id], options: nil).firstObject else {
            throw LibraryActionError.collectionNotFound
        }
        return folder
    }

    private static func fetchCollection(_ node: CollectionNode) throws -> PHCollection {
        node.isFolder ? try fetchFolder(node.id) : try fetchAlbum(node.id)
    }
}
