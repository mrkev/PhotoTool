import MapKit
import Photos
import SwiftUI

struct InspectorView: View {
    @Environment(BrowserModel.self) private var browser

    var body: some View {
        Group {
            if let asset = browser.viewerAsset {
                AssetDetails(asset: asset)
            } else if browser.selection.count == 1, let asset = browser.firstTarget {
                AssetDetails(asset: asset)
            } else if browser.selection.count > 1 {
                ContentUnavailableView(
                    "\(browser.selection.count.formatted()) Items Selected",
                    systemImage: "square.stack",
                    description: Text("Use the Photo menu to change them all at once.")
                )
            } else {
                ContentUnavailableView("No Selection", systemImage: "photo", description: Text("Select a photo to see its details."))
            }
        }
    }
}

private struct ResourceInfo: Identifiable {
    let id: Int
    let filename: String
    let kind: String
}

private struct AssetDetails: View {
    @Environment(BrowserModel.self) private var browser
    let asset: PHAsset

    @State private var resources: [ResourceInfo] = []
    @State private var albums: [(id: String, title: String)] = []

    private var dimensions: String {
        "\(asset.pixelWidth) × \(asset.pixelHeight)"
    }

    var body: some View {
        Form {
            Section("Details") {
                if let filename = resources.first?.filename {
                    LabeledContent("Filename", value: filename)
                }
                LabeledContent("Type", value: Self.typeDescription(for: asset))
                LabeledContent("Dimensions", value: dimensions)
                if asset.mediaType == .video {
                    LabeledContent("Duration", value: AssetCellView.durationText(asset.duration))
                }
                if let date = asset.creationDate {
                    LabeledContent("Taken", value: date.formatted(date: .abbreviated, time: .standard))
                }
                if let date = asset.modificationDate {
                    LabeledContent("Modified", value: date.formatted(date: .abbreviated, time: .standard))
                }
                LabeledContent("Favorite", value: asset.isFavorite ? "Yes" : "No")
                LabeledContent("Has Edits", value: asset.hasAdjustments ? "Yes" : "No")
            }

            if asset.representsBurst || asset.burstIdentifier != nil {
                Section("Burst") {
                    if let burstID = asset.burstIdentifier {
                        Button("Show All Burst Photos") {
                            browser.viewerAsset = nil
                            browser.show(.burst(burstID))
                        }
                    }
                }
            }

            Section("Location") {
                if let location = asset.location {
                    LocationPreview(coordinate: location.coordinate)
                        .id(asset.localIdentifier)
                    LabeledContent(
                        "Coordinates",
                        value: "\(location.coordinate.latitude.formatted(.number.precision(.fractionLength(5)))), \(location.coordinate.longitude.formatted(.number.precision(.fractionLength(5))))"
                    )
                } else {
                    Text("No location").foregroundStyle(.secondary)
                }
                Button("Adjust Location…") { browser.activeSheet = .adjustLocation([asset]) }
            }

            PhotosAppSection(assetID: asset.localIdentifier)

            if !albums.isEmpty {
                Section("Albums") {
                    ForEach(albums, id: \.id) { album in
                        Button(album.title) {
                            browser.viewerAsset = nil
                            browser.show(.collection(album.id))
                        }
                        .buttonStyle(.link)
                    }
                }
            }

            if !resources.isEmpty {
                Section("Stored Files") {
                    ForEach(resources) { resource in
                        LabeledContent(resource.kind, value: resource.filename)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task(id: asset.localIdentifier) { loadRelatedInfo() }
    }

    private func loadRelatedInfo() {
        resources = PHAssetResource.assetResources(for: asset).enumerated().map { index, resource in
            ResourceInfo(id: index, filename: resource.originalFilename, kind: Self.title(for: resource.type))
        }
        var found: [(id: String, title: String)] = []
        PHAssetCollection.fetchAssetCollectionsContaining(asset, with: .album, options: nil)
            .enumerateObjects { collection, _, _ in
                found.append((collection.localIdentifier, collection.localizedTitle ?? "Untitled Album"))
            }
        albums = found
    }

    private static func typeDescription(for asset: PHAsset) -> String {
        var parts: [String] = []
        switch asset.mediaType {
        case .image: parts.append("Photo")
        case .video: parts.append("Video")
        case .audio: parts.append("Audio")
        default: parts.append("Unknown")
        }
        let subtypes: [(PHAssetMediaSubtype, String)] = [
            (.photoLive, "Live"), (.photoPanorama, "Panorama"), (.photoHDR, "HDR"),
            (.photoScreenshot, "Screenshot"), (.photoDepthEffect, "Portrait"),
            (.videoCinematic, "Cinematic"), (.videoHighFrameRate, "Slo-mo"),
            (.videoTimelapse, "Time-lapse"), (.videoScreenRecording, "Screen Recording"),
        ]
        parts += subtypes.filter { asset.mediaSubtypes.contains($0.0) }.map(\.1)
        return parts.joined(separator: ", ")
    }

    private static func title(for type: PHAssetResourceType) -> String {
        switch type {
        case .photo: "Original"
        case .video: "Original Video"
        case .audio: "Audio"
        case .alternatePhoto: "Alternate (RAW)"
        case .fullSizePhoto: "Edited"
        case .fullSizeVideo: "Edited Video"
        case .adjustmentData: "Edit Data"
        case .adjustmentBasePhoto: "Edit Base"
        case .pairedVideo: "Live Video"
        case .fullSizePairedVideo: "Edited Live Video"
        case .adjustmentBasePairedVideo: "Live Edit Base"
        case .adjustmentBaseVideo: "Video Edit Base"
        case .photoProxy: "Proxy"
        @unknown default: "Other"
        }
    }
}

private struct LocationPreview: View {
    let coordinate: CLLocationCoordinate2D

    var body: some View {
        Map(initialPosition: .region(MKCoordinateRegion(
            center: coordinate,
            latitudinalMeters: 2000,
            longitudinalMeters: 2000
        ))) {
            Marker("Photo", coordinate: coordinate)
        }
        .frame(height: 140)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .accessibilityLabel("Map of the photo's location")
    }
}

/// Fields that only Photos.app can read and write. Nothing loads until the user
/// opts in, so browsing never launches Photos unexpectedly.
private struct PhotosAppSection: View {
    @Environment(BrowserModel.self) private var browser
    @AppStorage(PhotosAppBridge.enabledKey) private var isEnabled = false
    let assetID: String

    @State private var saved: PhotosAppMetadata?
    @State private var title = ""
    @State private var details = ""
    @State private var keywords: [String] = []
    @State private var newKeyword = ""
    @State private var errorMessage: String?
    @State private var isSaving = false

    private var hasChanges: Bool {
        guard let saved else { return false }
        return saved.title != title || saved.description != details || saved.keywords != keywords
    }

    var body: some View {
        Section("Title, Description & Keywords") {
            if !isEnabled {
                Text("These are only available through the Photos app.")
                    .foregroundStyle(.secondary)
                Button("Use Photos App") { isEnabled = true }
            } else if let errorMessage {
                Text(errorMessage).foregroundStyle(.secondary)
                Button("Try Again") { Task { await load() } }
            } else if let saved {
                TextField("Title", text: $title)
                TextField("Description", text: $details, axis: .vertical)
                    .lineLimit(2...5)
                ForEach(keywords, id: \.self) { keyword in
                    LabeledContent(keyword) {
                        Button("Remove \(keyword)", systemImage: "xmark.circle.fill") {
                            keywords.removeAll { $0 == keyword }
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                    }
                }
                TextField("Add Keyword", text: $newKeyword)
                    .onSubmit(addKeyword)
                if let size = saved.fileSize {
                    LabeledContent("File Size", value: Int64(size).formatted(.byteCount(style: .file)))
                }
                Button("Save") { Task { await save() } }
                    .disabled(!hasChanges || isSaving)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .task(id: LoadKey(assetID: assetID, isEnabled: isEnabled)) {
            await load()
        }
    }

    private struct LoadKey: Equatable {
        let assetID: String
        let isEnabled: Bool
    }

    private func addKeyword() {
        let keyword = newKeyword.trimmingCharacters(in: .whitespacesAndNewlines)
        newKeyword = ""
        if !keyword.isEmpty, !keywords.contains(keyword) {
            keywords.append(keyword)
        }
    }

    private func load() async {
        saved = nil
        errorMessage = nil
        guard isEnabled else { return }
        do {
            let metadata = try await PhotosAppBridge.shared.metadata(id: assetID)
            guard !Task.isCancelled else { return }
            saved = metadata
            title = metadata.title
            details = metadata.description
            keywords = metadata.keywords
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
        }
    }

    private func save() async {
        addKeyword()
        isSaving = true
        defer { isSaving = false }
        do {
            try await PhotosAppBridge.shared.update(id: assetID, title: title, description: details, keywords: keywords)
            saved?.title = title
            saved?.description = details
            saved?.keywords = keywords
        } catch {
            browser.present(error)
        }
    }
}
