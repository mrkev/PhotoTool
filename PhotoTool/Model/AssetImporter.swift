import Foundation
import Photos
import UniformTypeIdentifiers

nonisolated struct ImportResource: Equatable {
    let type: PHAssetResourceType
    let url: URL
}

/// One asset to create, which may be made up of several files.
nonisolated struct ImportItem: Equatable {
    let resources: [ImportResource]

    var displayName: String {
        resources.first?.url.lastPathComponent ?? "Unknown file"
    }

    /// The same files imported as separate assets. Used when a pairing fails,
    /// such as an unrelated photo and video that happen to share a name.
    var separated: [ImportItem] {
        resources.map { resource in
            let type: PHAssetResourceType = switch resource.type {
            case .pairedVideo: .video
            case .alternatePhoto: .photo
            default: resource.type
            }
            return ImportItem(resources: [ImportResource(type: type, url: resource.url)])
        }
    }
}

nonisolated enum ImportPlanner {
    private enum FileKind {
        case raw, image, movie
    }

    /// Expands folders into the files inside them, skipping hidden files.
    static func expand(_ urls: [URL]) -> [URL] {
        urls.flatMap { url -> [URL] in
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return [] }
            guard isDirectory.boolValue else { return [url] }
            let files = FileManager.default.enumerator(
                at: url,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            )
            return files?.compactMap { $0 as? URL }.filter {
                (try? $0.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
            } ?? []
        }
    }

    /// Groups files into assets. Files sharing a folder and base name become
    /// one asset: image + RAW pairs and image + movie Live Photos. Unsupported
    /// files are left out.
    static func plan(files: [URL]) -> [ImportItem] {
        var groups: [String: [(url: URL, kind: FileKind)]] = [:]
        var order: [String] = []
        for url in files {
            guard let kind = kind(of: url) else { continue }
            let key = url.deletingPathExtension().path.lowercased()
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append((url, kind))
        }
        return order.flatMap { items(for: groups[$0] ?? []) }
    }

    private static func items(for group: [(url: URL, kind: FileKind)]) -> [ImportItem] {
        let images = group.filter { $0.kind == .image }.map(\.url)
        let raws = group.filter { $0.kind == .raw }.map(\.url)
        let movies = group.filter { $0.kind == .movie }.map(\.url)

        if images.count == 1, raws.count == 1, movies.isEmpty {
            return [ImportItem(resources: [
                ImportResource(type: .photo, url: images[0]),
                ImportResource(type: .alternatePhoto, url: raws[0]),
            ])]
        }
        if images.count == 1, raws.isEmpty, movies.count == 1 {
            return [ImportItem(resources: [
                ImportResource(type: .photo, url: images[0]),
                ImportResource(type: .pairedVideo, url: movies[0]),
            ])]
        }
        return (images + raws).map { ImportItem(resources: [ImportResource(type: .photo, url: $0)]) }
            + movies.map { ImportItem(resources: [ImportResource(type: .video, url: $0)]) }
    }

    private static func kind(of url: URL) -> FileKind? {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return nil }
        if type.conforms(to: .rawImage) { return .raw }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .movie) { return .movie }
        return nil
    }
}

nonisolated enum ImportWriter {
    static func create(_ item: ImportItem, albumID: String?) async throws {
        let album = albumID.flatMap {
            PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [$0], options: nil).firstObject
        }
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            for resource in item.resources {
                let options = PHAssetResourceCreationOptions()
                options.originalFilename = resource.url.lastPathComponent
                options.shouldMoveFile = false
                request.addResource(with: resource.type, fileURL: resource.url, options: options)
            }
            if let album, let placeholder = request.placeholderForCreatedAsset {
                PHAssetCollectionChangeRequest(for: album)?.addAssets([placeholder] as NSArray)
            }
        }
    }
}

enum AssetImporter {
    /// Imports each asset in its own change, so one bad file can't fail the rest.
    static func run(urls: [URL], albumID: String?, activity: Activity) async {
        let items = ImportPlanner.plan(files: ImportPlanner.expand(urls))
        activity.total = items.count
        if items.isEmpty {
            activity.failures.append("None of the selected files are photos or videos.")
        }
        for item in items {
            guard !Task.isCancelled else { return }
            do {
                try await ImportWriter.create(item, albumID: albumID)
            } catch where item.resources.count > 1 {
                for single in item.separated {
                    do {
                        try await ImportWriter.create(single, albumID: albumID)
                    } catch {
                        activity.failures.append("\(single.displayName): \(error.localizedDescription)")
                    }
                }
            } catch {
                activity.failures.append("\(item.displayName): \(error.localizedDescription)")
            }
            activity.completed += 1
        }
    }
}
