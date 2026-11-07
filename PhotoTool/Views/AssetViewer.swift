import AVKit
import Photos
import PhotosUI
import SwiftUI

/// Full-size viewing for photos, Live Photos, and videos. It's view-only: no
/// editing tools by design.
struct AssetViewer: View {
    @Environment(BrowserModel.self) private var browser
    let asset: PHAsset

    @FocusState private var isFocused: Bool

    var body: some View {
        ZStack(alignment: .top) {
            Color(nsColor: .windowBackgroundColor)
            content
                .id(asset.localIdentifier)
            header
        }
        .focusable()
        .focused($isFocused)
        .focusEffectDisabled()
        .onAppear { isFocused = true }
        .onKeyPress(.leftArrow) { browser.moveViewer(by: -1); return .handled }
        .onKeyPress(.rightArrow) { browser.moveViewer(by: 1); return .handled }
        .onKeyPress(.escape) { browser.closeViewer(); return .handled }
        .onKeyPress(".") { browser.toggleFavorite(); return .handled }
        .onKeyPress(.space) {
            guard asset.mediaType != .video else { return .ignored }
            browser.closeViewer()
            return .handled
        }
    }

    @ViewBuilder
    private var content: some View {
        if asset.mediaType == .video {
            VideoContent(asset: asset)
        } else if asset.mediaSubtypes.contains(.photoLive) {
            LivePhotoContent(asset: asset)
        } else {
            PhotoContent(asset: asset)
        }
    }

    private var header: some View {
        HStack {
            Button("Back to Grid", systemImage: "chevron.backward") { browser.closeViewer() }
            Spacer()
            if let date = asset.creationDate {
                Text(date.formatted(date: .abbreviated, time: .shortened))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Previous", systemImage: "chevron.left") { browser.moveViewer(by: -1) }
                .labelStyle(.iconOnly)
            Button("Next", systemImage: "chevron.right") { browser.moveViewer(by: 1) }
                .labelStyle(.iconOnly)
        }
        .padding(8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .padding(8)
    }
}

private struct LoadingOverlay: View {
    let progress: Double?

    var body: some View {
        Group {
            if let progress, progress > 0 {
                ProgressView("Downloading from iCloud", value: progress)
                    .frame(width: 200)
            } else {
                ProgressView()
            }
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: Photos

private enum PhotoLoadEvent: Sendable {
    case image(NSImage, isFinal: Bool)
    case progress(Double)
    case failed(String)
}

private nonisolated func photoLoadEvents(for asset: PHAsset) -> AsyncStream<PhotoLoadEvent> {
    AsyncStream { continuation in
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.isNetworkAccessAllowed = true
        options.progressHandler = { progress, _, _, _ in
            continuation.yield(.progress(progress))
        }
        // Full resolution, so zooming in shows real detail. The opportunistic
        // delivery mode provides a quick low-resolution image first.
        let requestID = PHImageManager.default().requestImage(
            for: asset,
            targetSize: PHImageManagerMaximumSize,
            contentMode: .aspectFit,
            options: options
        ) { image, info in
            let isDegraded = info?[PHImageResultIsDegradedKey] as? Bool ?? false
            if let image {
                continuation.yield(.image(image, isFinal: !isDegraded))
            } else if let error = info?[PHImageErrorKey] as? Error {
                continuation.yield(.failed(error.localizedDescription))
            }
            if !isDegraded { continuation.finish() }
        }
        continuation.onTermination = { _ in
            PHImageManager.default().cancelImageRequest(requestID)
        }
    }
}

private struct PhotoContent: View {
    let asset: PHAsset

    @State private var image: NSImage?
    @State private var isLoading = true
    @State private var progress: Double?
    @State private var errorMessage: String?

    var body: some View {
        ZStack {
            ZoomableImageView(
                image: image,
                pixelSize: CGSize(width: asset.pixelWidth, height: asset.pixelHeight)
            )
            .accessibilityLabel("Photo")
            if let errorMessage {
                ContentUnavailableView("Couldn't Load Photo", systemImage: "exclamationmark.triangle", description: Text(errorMessage))
            } else if isLoading {
                LoadingOverlay(progress: progress)
            }
        }
        .task {
            for await event in photoLoadEvents(for: asset) {
                switch event {
                case .image(let newImage, let isFinal):
                    image = newImage
                    if isFinal { isLoading = false }
                case .progress(let value):
                    progress = value
                case .failed(let message):
                    errorMessage = message
                    isLoading = false
                }
            }
        }
    }
}

/// Pinch and scroll zoom come from `NSScrollView`. The photo fits the window
/// until the user zooms, and double-clicking switches between fit and 100%.
private struct ZoomableImageView: NSViewRepresentable {
    let image: NSImage?
    let pixelSize: CGSize

    func makeNSView(context: Context) -> ZoomingScrollView {
        ZoomingScrollView()
    }

    func updateNSView(_ scrollView: ZoomingScrollView, context: Context) {
        scrollView.show(image: image, pixelSize: pixelSize)
    }
}

/// Keeps a photo smaller than the window centered rather than pinned to a corner.
private final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let documentView else { return rect }
        let document = documentView.frame
        if rect.width > document.width {
            rect.origin.x = (document.width - rect.width) / 2
        }
        if rect.height > document.height {
            rect.origin.y = (document.height - rect.height) / 2
        }
        return rect
    }
}

private final class ZoomingScrollView: NSScrollView {
    private let imageView = NSImageView()
    private var fitsWindow = true

    init() {
        super.init(frame: .zero)
        contentView = CenteringClipView()
        documentView = imageView
        drawsBackground = false
        allowsMagnification = true
        maxMagnification = 8
        hasVerticalScroller = true
        hasHorizontalScroller = true
        autohidesScrollers = true
        imageView.imageScaling = .scaleProportionallyUpOrDown
        NotificationCenter.default.addObserver(
            self, selector: #selector(userDidZoom), name: NSScrollView.didEndLiveMagnifyNotification, object: self
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func show(image: NSImage?, pixelSize: CGSize) {
        imageView.image = image
        guard imageView.frame.size != pixelSize, pixelSize.width > 0, pixelSize.height > 0 else { return }
        imageView.frame = CGRect(origin: .zero, size: pixelSize)
        fitsWindow = true
        needsLayout = true
    }

    override func layout() {
        super.layout()
        updateFit()
    }

    private var fitMagnification: CGFloat {
        let size = imageView.frame.size
        guard size.width > 0, size.height > 0, bounds.width > 0, bounds.height > 0 else { return 1 }
        return min(bounds.width / size.width, bounds.height / size.height, 1)
    }

    private func updateFit() {
        let fit = fitMagnification
        minMagnification = fit
        if fitsWindow, magnification != fit {
            magnification = fit
        }
    }

    @objc private func userDidZoom() {
        fitsWindow = magnification <= minMagnification + 0.001
    }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        guard event.clickCount == 2 else { return }
        if fitsWindow {
            fitsWindow = false
            let point = imageView.convert(event.locationInWindow, from: nil)
            setMagnification(1, centeredAt: point)
        } else {
            fitsWindow = true
            magnification = fitMagnification
        }
    }
}

// MARK: Live Photos

private struct LivePhotoContent: View {
    let asset: PHAsset

    @State private var livePhoto: PHLivePhoto?
    @State private var isLoading = true

    var body: some View {
        ZStack {
            LivePhotoRepresentable(livePhoto: livePhoto)
                .accessibilityLabel("Live Photo")
            if isLoading {
                LoadingOverlay(progress: nil)
            }
        }
        .onAppear(perform: load)
    }

    private func load() {
        let options = PHLivePhotoRequestOptions()
        options.deliveryMode = .opportunistic
        options.isNetworkAccessAllowed = true
        let size = CGSize(width: asset.pixelWidth, height: asset.pixelHeight)
        PHImageManager.default().requestLivePhoto(
            for: asset,
            targetSize: size,
            contentMode: .aspectFit,
            options: options
        ) { photo, info in
            let isDegraded = info?[PHImageResultIsDegradedKey] as? Bool ?? false
            MainThread.run {
                if let photo { livePhoto = photo }
                if !isDegraded { isLoading = false }
            }
        }
    }
}

private struct LivePhotoRepresentable: NSViewRepresentable {
    let livePhoto: PHLivePhoto?

    func makeNSView(context: Context) -> PHLivePhotoView {
        let view = PHLivePhotoView()
        view.contentMode = .aspectFit
        return view
    }

    func updateNSView(_ view: PHLivePhotoView, context: Context) {
        if view.livePhoto !== livePhoto {
            view.livePhoto = livePhoto
        }
    }
}

// MARK: Video

private struct VideoContent: View {
    let asset: PHAsset

    @State private var player: AVPlayer?
    @State private var errorMessage: String?

    var body: some View {
        ZStack {
            if let player {
                VideoPlayer(player: player)
            } else if let errorMessage {
                ContentUnavailableView("Couldn't Load Video", systemImage: "exclamationmark.triangle", description: Text(errorMessage))
            } else {
                LoadingOverlay(progress: nil)
            }
        }
        .padding(.top, 52)
        .onAppear(perform: load)
        .onDisappear { player?.pause() }
    }

    private func load() {
        let options = PHVideoRequestOptions()
        options.deliveryMode = .automatic
        options.isNetworkAccessAllowed = true
        PHImageManager.default().requestPlayerItem(forVideo: asset, options: options) { item, info in
            let message = (info?[PHImageErrorKey] as? Error)?.localizedDescription
            MainThread.run {
                if let item {
                    player = AVPlayer(playerItem: item)
                } else {
                    errorMessage = message ?? "The video isn't available."
                }
            }
        }
    }
}
