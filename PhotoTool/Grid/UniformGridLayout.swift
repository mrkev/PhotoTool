import AppKit

/// Grid geometry as plain arithmetic: every lookup is O(1), so the cost doesn't
/// grow with the size of the library.
nonisolated struct GridMetrics: Equatable {
    var containerWidth: CGFloat = 0
    var targetSide: CGFloat = 180
    var itemCount = 0
    var spacing: CGFloat = 4
    var inset: CGFloat = 8

    var columns: Int {
        let available = containerWidth - inset * 2 + spacing
        return max(1, Int(available / (targetSide + spacing)))
    }

    var side: CGFloat {
        let totalSpacing = spacing * CGFloat(columns - 1)
        return max(1, ((containerWidth - inset * 2 - totalSpacing) / CGFloat(columns)).rounded(.down))
    }

    var rows: Int {
        itemCount == 0 ? 0 : (itemCount + columns - 1) / columns
    }

    var contentHeight: CGFloat {
        guard rows > 0 else { return 0 }
        return inset * 2 + CGFloat(rows) * side + CGFloat(rows - 1) * spacing
    }

    func frame(at index: Int) -> CGRect {
        let columns = columns
        let side = side
        return CGRect(
            x: inset + CGFloat(index % columns) * (side + spacing),
            y: inset + CGFloat(index / columns) * (side + spacing),
            width: side,
            height: side
        )
    }

    /// The items that intersect `rect`.
    func indexRange(in rect: CGRect) -> Range<Int> {
        guard itemCount > 0, rect.height > 0 else { return 0..<0 }
        let rowHeight = side + spacing
        let firstRow = max(0, Int((rect.minY - inset) / rowHeight))
        let lastRow = max(firstRow, Int((rect.maxY - inset) / rowHeight))
        let lower = min(firstRow * columns, itemCount)
        let upper = min((lastRow + 1) * columns, itemCount)
        return lower..<upper
    }

    /// The gap between items nearest to `point`, from `0` through `itemCount`.
    func nearestGap(to point: CGPoint) -> Int {
        guard itemCount > 0 else { return 0 }
        let cell = side + spacing
        let row = min(max(0, Int((point.y - inset) / cell)), rows - 1)
        let column = min(max(0, Int(((point.x - inset) / cell).rounded())), columns)
        return min(row * columns + column, itemCount)
    }

    /// Where to draw the insertion marker for a gap.
    func gapFrame(before index: Int) -> CGRect {
        guard itemCount > 0 else {
            return CGRect(x: inset, y: inset, width: spacing, height: side)
        }
        if index >= itemCount {
            let last = frame(at: itemCount - 1)
            return CGRect(x: last.maxX, y: last.minY, width: spacing, height: last.height)
        }
        let item = frame(at: index)
        return CGRect(x: item.minX - spacing, y: item.minY, width: spacing, height: item.height)
    }

    /// The item reached by moving `delta` places, or `nil` if there's nothing
    /// there. Moving down from the second-to-last row lands on the last item.
    func index(from current: Int?, delta: Int) -> Int? {
        guard itemCount > 0 else { return nil }
        guard let current else { return delta > 0 ? 0 : itemCount - 1 }
        let next = current + delta
        if next < 0 { return nil }
        if next >= itemCount {
            let isOnLastRow = current / columns == (itemCount - 1) / columns
            return delta > 1 && !isOnLastRow ? itemCount - 1 : nil
        }
        return next
    }
}

/// `NSCollectionViewFlowLayout` measures every item up front, which doesn't
/// scale to libraries with hundreds of thousands of photos. This doesn't.
final class UniformGridLayout: NSCollectionViewLayout {
    private(set) var metrics = GridMetrics()

    var targetSide: CGFloat = 180 {
        didSet {
            if targetSide != oldValue { invalidateLayout() }
        }
    }

    override func prepare() {
        super.prepare()
        guard let collectionView else { return }
        metrics.targetSide = targetSide
        metrics.containerWidth = collectionView.enclosingScrollView?.contentView.bounds.width ?? collectionView.bounds.width
        metrics.itemCount = collectionView.numberOfSections > 0 ? collectionView.numberOfItems(inSection: 0) : 0
    }

    override var collectionViewContentSize: NSSize {
        // Fill the visible area so clicks below the last row still deselect.
        let visibleHeight = collectionView?.enclosingScrollView?.contentView.bounds.height ?? 0
        return NSSize(width: metrics.containerWidth, height: max(metrics.contentHeight, visibleHeight))
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: NSRect) -> Bool {
        newBounds.width != metrics.containerWidth
    }

    override func layoutAttributesForElements(in rect: NSRect) -> [NSCollectionViewLayoutAttributes] {
        metrics.indexRange(in: rect).map(attributes(at:))
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> NSCollectionViewLayoutAttributes? {
        guard indexPath.item < metrics.itemCount else { return nil }
        return attributes(at: indexPath.item)
    }

    override func layoutAttributesForDropTarget(at pointInCollectionView: NSPoint) -> NSCollectionViewLayoutAttributes? {
        gapAttributes(before: metrics.nearestGap(to: pointInCollectionView))
    }

    override func layoutAttributesForInterItemGap(before indexPath: IndexPath) -> NSCollectionViewLayoutAttributes? {
        gapAttributes(before: indexPath.item)
    }

    private func attributes(at index: Int) -> NSCollectionViewLayoutAttributes {
        let attributes = NSCollectionViewLayoutAttributes(forItemWith: IndexPath(item: index, section: 0))
        attributes.frame = metrics.frame(at: index)
        return attributes
    }

    private func gapAttributes(before index: Int) -> NSCollectionViewLayoutAttributes {
        let attributes = NSCollectionViewLayoutAttributes(forInterItemGapBefore: IndexPath(item: index, section: 0))
        attributes.frame = metrics.gapFrame(before: index)
        return attributes
    }
}
