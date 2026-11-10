import AppKit
import Photos

/// A thumbnail cell. It draws with layers rather than an `NSImageView`, which
/// keeps fast scrolling cheap.
final class AssetCellView: NSView {
    private let imageLayer = CALayer()
    private let selectionLayer = CALayer()
    private let badges = NSStackView()
    private let durationLabel = NSTextField(labelWithString: "")
    private let favoriteBadge = AssetCellView.makeBadge("heart.fill")
    private let liveBadge = AssetCellView.makeBadge("livephoto")
    private let burstBadge = AssetCellView.makeBadge("square.stack.3d.down.right.fill")
    private let videoBadge = AssetCellView.makeBadge("video.fill")

    var assetDescription = "Photo"

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
        layer?.cornerRadius = 3
        layer?.masksToBounds = true

        // Without this, reused cells visibly cross-fade between photos.
        let noAnimations: [String: any CAAction] = [
            "contents": NSNull(), "bounds": NSNull(), "position": NSNull(), "contentsGravity": NSNull(),
        ]
        imageLayer.actions = noAnimations
        imageLayer.masksToBounds = true
        imageLayer.contentsGravity = .resizeAspectFill
        layer?.addSublayer(imageLayer)

        selectionLayer.actions = noAnimations.merging(["borderWidth": NSNull()]) { first, _ in first }
        selectionLayer.cornerRadius = 3
        layer?.addSublayer(selectionLayer)

        durationLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        durationLabel.textColor = .white
        durationLabel.shadow = AssetCellView.badgeShadow

        badges.orientation = .horizontal
        badges.spacing = 4
        badges.translatesAutoresizingMaskIntoConstraints = false
        [favoriteBadge, liveBadge, burstBadge, videoBadge, durationLabel].forEach(badges.addArrangedSubview)
        addSubview(badges)
        NSLayoutConstraint.activate([
            badges.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            badges.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private static let badgeShadow: NSShadow = {
        let shadow = NSShadow()
        shadow.shadowColor = .black.withAlphaComponent(0.7)
        shadow.shadowBlurRadius = 2
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        return shadow
    }()

    private static func makeBadge(_ symbol: String) -> NSImageView {
        let view = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
        view.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        view.contentTintColor = .white
        view.shadow = badgeShadow
        return view
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.frame = bounds
        selectionLayer.frame = bounds
        CATransaction.commit()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        imageLayer.contentsScale = window?.backingScaleFactor ?? 2
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
            selectionLayer.borderColor = NSColor.controlAccentColor.cgColor
        }
    }

    func setImage(_ image: NSImage?, fill: Bool) {
        imageLayer.contentsGravity = fill ? .resizeAspectFill : .resizeAspect
        imageLayer.contents = image?.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    func setSelected(_ isSelected: Bool) {
        selectionLayer.borderColor = NSColor.controlAccentColor.cgColor
        selectionLayer.borderWidth = isSelected ? 3 : 0
        setAccessibilitySelected(isSelected)
    }

    func setBadges(for asset: PHAsset) {
        favoriteBadge.isHidden = !asset.isFavorite
        liveBadge.isHidden = !asset.mediaSubtypes.contains(.photoLive)
        burstBadge.isHidden = !asset.representsBurst
        let isVideo = asset.mediaType == .video
        videoBadge.isHidden = !isVideo
        durationLabel.isHidden = !isVideo
        if isVideo {
            durationLabel.stringValue = Self.durationText(asset.duration)
        }

        var parts = [isVideo ? "Video" : "Photo"]
        if let date = asset.creationDate {
            parts.append(date.formatted(date: .abbreviated, time: .shortened))
        }
        if asset.isFavorite { parts.append("Favorite") }
        assetDescription = parts.joined(separator: ", ")
    }

    static func durationText(_ duration: TimeInterval) -> String {
        Duration.seconds(duration.rounded()).formatted(
            duration >= 3600 ? .time(pattern: .hourMinuteSecond) : .time(pattern: .minuteSecond)
        )
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .image }
    override func accessibilityLabel() -> String? { assetDescription }
}

final class AssetGridItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("AssetGridItem")

    private var requestID: PHImageRequestID?
    private weak var manager: PHImageManager?
    private var loadedKey: LoadKey?

    private struct LoadKey: Equatable {
        let assetID: String
        let modified: Date?
        let targetSize: CGSize
        let fill: Bool
    }

    private var cell: AssetCellView? { view as? AssetCellView }

    override func loadView() {
        view = AssetCellView(frame: .zero)
    }

    override var isSelected: Bool {
        didSet { cell?.setSelected(isSelected) }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        cancelRequest()
        loadedKey = nil
        cell?.setImage(nil, fill: true)
    }

    /// Updates the cell. The image is only re-requested if it would change, so
    /// favoriting a photo doesn't make its thumbnail flicker.
    func configure(asset: PHAsset, manager: PHImageManager, targetSize: CGSize, fill: Bool) {
        cell?.setBadges(for: asset)
        cell?.setSelected(isSelected)

        let key = LoadKey(
            assetID: asset.localIdentifier,
            modified: asset.modificationDate,
            targetSize: targetSize,
            fill: fill
        )
        guard key != loadedKey else { return }
        cancelRequest()
        loadedKey = key
        self.manager = manager

        requestID = manager.requestImage(
            for: asset,
            targetSize: targetSize,
            contentMode: fill ? .aspectFill : .aspectFit,
            options: Self.requestOptions
        ) { [weak self] image, _ in
            MainThread.run {
                guard let self, self.loadedKey == key, let image else { return }
                self.cell?.setImage(image, fill: fill)
            }
        }
    }

    private func cancelRequest() {
        if let requestID { manager?.cancelImageRequest(requestID) }
        requestID = nil
    }

    private static let requestOptions: PHImageRequestOptions = {
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true
        return options
    }()
}
