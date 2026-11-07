import Foundation
import Photos

nonisolated enum ExportVersion {
    /// The photo as it looks in the library, including any edits.
    case current
    /// The files as they were first added, plus any RAW or Live Photo video.
    case original
}

/// Picks which of an asset's stored files to export. This writes the files
/// PhotoKit already holds, so nothing is re-encoded.
nonisolated enum ExportSelection {
    static func types(from available: [PHAssetResourceType], version: ExportVersion) -> [PHAssetResourceType] {
        switch version {
        case .original:
            return available.filter { [.photo, .video, .audio, .alternatePhoto, .pairedVideo].contains($0) }
        case .current:
            let replacements: [(rendered: PHAssetResourceType, base: PHAssetResourceType)] = [
                (.fullSizePhoto, .photo), (.fullSizeVideo, .video), (.fullSizePairedVideo, .pairedVideo),
            ]
            var result: [PHAssetResourceType] = []
            for (rendered, base) in replacements {
                if available.contains(rendered) {
                    result.append(rendered)
                } else if available.contains(base) {
                    result.append(base)
                }
            }
            if available.contains(.audio) { result.append(.audio) }
            return result
        }
    }

    /// The name to save a file under. Rendered files have generic names like
    /// `FullSizeRender.heic`, so they take the base name of the original.
    static func fileName(resourceName: String, originalName: String) -> String {
        let base = (originalName as NSString).deletingPathExtension
        let fileExtension = (resourceName as NSString).pathExtension
        return fileExtension.isEmpty ? base : "\(base).\(fileExtension)"
    }

    /// Adds " (1)", " (2)", … until `isTaken` stops matching.
    static func uniqueName(_ name: String, isTaken: (String) -> Bool) -> String {
        guard isTaken(name) else { return name }
        let base = (name as NSString).deletingPathExtension
        let fileExtension = (name as NSString).pathExtension
        var attempt = 1
        while true {
            let candidate = fileExtension.isEmpty ? "\(base) (\(attempt))" : "\(base) (\(attempt)).\(fileExtension)"
            if !isTaken(candidate) { return candidate }
            attempt += 1
        }
    }
}

nonisolated enum AssetFiles {
    /// The resources to write for an asset, in priority order.
    static func resources(for asset: PHAsset, version: ExportVersion) -> [PHAssetResource] {
        let all = PHAssetResource.assetResources(for: asset)
        return ExportSelection.types(from: all.map(\.type), version: version).compactMap { type in
            all.first { $0.type == type }
        }
    }

    /// The filename the asset was imported with.
    static func originalName(for asset: PHAsset) -> String {
        let all = PHAssetResource.assetResources(for: asset)
        let original = all.first { [.photo, .video].contains($0.type) } ?? all.first
        return original?.originalFilename ?? "Untitled"
    }

    static func write(_ resource: PHAssetResource, to url: URL) async throws {
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        do {
            try await PHAssetResourceManager.default().writeData(for: resource, toFile: url, options: options)
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }
}

enum AssetExporter {
    static func run(assets: [PHAsset], to directory: URL, version: ExportVersion, activity: Activity) async {
        activity.total = assets.count
        for asset in assets {
            guard !Task.isCancelled else { return }
            let originalName = AssetFiles.originalName(for: asset)
            for resource in AssetFiles.resources(for: asset, version: version) {
                let name = ExportSelection.uniqueName(
                    ExportSelection.fileName(resourceName: resource.originalFilename, originalName: originalName)
                ) { FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path) }
                do {
                    try await AssetFiles.write(resource, to: directory.appendingPathComponent(name))
                } catch {
                    activity.failures.append("\(name): \(error.localizedDescription)")
                }
            }
            activity.completed += 1
        }
    }
}
