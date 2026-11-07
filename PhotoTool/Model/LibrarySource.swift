import Foundation
import Photos

/// What the browser is currently showing.
nonisolated enum LibrarySource: Hashable {
    case allPhotos
    case collection(String)
    case burst(String)
    case search(query: String, assetIDs: [String])
}

nonisolated enum AssetSortKey: String, CaseIterable, Identifiable {
    /// The album's own manual order. Only meaningful for user albums.
    case albumOrder
    case dateTaken
    case dateModified
    case duration
    case width

    var id: Self { self }

    var title: String {
        switch self {
        case .albumOrder: "Album Order"
        case .dateTaken: "Date Taken"
        case .dateModified: "Date Modified"
        case .duration: "Duration"
        case .width: "Width"
        }
    }

    var fetchKey: String? {
        switch self {
        case .albumOrder: nil
        case .dateTaken: "creationDate"
        case .dateModified: "modificationDate"
        case .duration: "duration"
        case .width: "pixelWidth"
        }
    }
}

nonisolated enum MediaFilter: String, CaseIterable, Identifiable {
    case all, photos, videos

    var id: Self { self }

    var title: String {
        switch self {
        case .all: "All Items"
        case .photos: "Photos"
        case .videos: "Videos"
        }
    }
}

/// Sort and filter settings. These translate directly to `PHFetchOptions`, so
/// only keys PhotoKit supports in fetch predicates can appear here.
nonisolated struct AssetQuery: Equatable {
    var sortKey: AssetSortKey = .dateTaken
    var ascending = false
    var media: MediaFilter = .all
    var favoritesOnly = false
    var dateRange: ClosedRange<Date>?

    var isUnfiltered: Bool {
        media == .all && !favoritesOnly && dateRange == nil
    }

    var predicate: NSPredicate? {
        var parts: [NSPredicate] = []
        switch media {
        case .all: break
        case .photos: parts.append(NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue))
        case .videos: parts.append(NSPredicate(format: "mediaType == %d", PHAssetMediaType.video.rawValue))
        }
        if favoritesOnly {
            parts.append(NSPredicate(format: "favorite == YES"))
        }
        if let dateRange {
            parts.append(NSPredicate(
                format: "creationDate >= %@ AND creationDate <= %@",
                dateRange.lowerBound as NSDate,
                dateRange.upperBound as NSDate
            ))
        }
        switch parts.count {
        case 0: return nil
        case 1: return parts[0]
        default: return NSCompoundPredicate(andPredicateWithSubpredicates: parts)
        }
    }

    var sortDescriptors: [NSSortDescriptor]? {
        guard let key = sortKey.fetchKey else { return nil }
        return [NSSortDescriptor(key: key, ascending: ascending)]
    }

    func fetchOptions(includeHidden: Bool = false, includeAllBursts: Bool = false) -> PHFetchOptions {
        let options = PHFetchOptions()
        options.predicate = predicate
        options.sortDescriptors = sortDescriptors
        options.includeHiddenAssets = includeHidden
        options.includeAllBurstAssets = includeAllBursts
        return options
    }
}

/// How "Adjust Date & Time" changes each asset.
nonisolated enum DateAdjustment: Equatable {
    case set(Date)
    case shift(TimeInterval)

    func apply(to date: Date?) -> Date? {
        switch self {
        case .set(let newDate): newDate
        case .shift(let seconds): date?.addingTimeInterval(seconds)
        }
    }
}

/// PhotoKit's move APIs take the final index of the moved items, while a drop
/// reports the gap they were dropped into. This converts one to the other.
nonisolated enum ReorderMath {
    static func destinationIndex(moving indexes: IndexSet, toGap gap: Int) -> Int {
        gap - indexes.count(in: 0..<max(gap, 0))
    }

    /// Whether a move would leave the order unchanged.
    static func isNoOp(moving indexes: IndexSet, toGap gap: Int) -> Bool {
        guard let first = indexes.first, let last = indexes.last,
              last - first + 1 == indexes.count else { return false }
        return gap >= first && gap <= last + 1
    }
}
