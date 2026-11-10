//
//  PhotoToolTests.swift
//  PhotoToolTests
//
//  These cover logic only. Nothing here touches the real photo library.
//

import CoreGraphics
import Foundation
import Photos
import Testing
@testable import PhotoTool

struct AssetQueryTests {
    @Test func noFiltersMeansNoPredicate() {
        let query = AssetQuery()
        #expect(query.isUnfiltered)
        #expect(query.predicate == nil)
    }

    @Test func mediaAndFavoritesCombine() throws {
        var query = AssetQuery()
        query.media = .videos
        query.favoritesOnly = true
        #expect(!query.isUnfiltered)
        let format = try #require(query.predicate?.predicateFormat)
        #expect(format.contains("mediaType == \(PHAssetMediaType.video.rawValue)"))
        #expect(format.contains("favorite == 1"))
    }

    @Test func albumOrderHasNoSortDescriptors() {
        var query = AssetQuery()
        query.sortKey = .albumOrder
        #expect(query.sortDescriptors == nil)
    }

    @Test func sortUsesFetchKeyAndDirection() throws {
        var query = AssetQuery()
        query.sortKey = .dateModified
        query.ascending = true
        let descriptor = try #require(query.sortDescriptors?.first)
        #expect(descriptor.key == "modificationDate")
        #expect(descriptor.ascending)
    }
}

struct DateAdjustmentTests {
    private let reference = Date(timeIntervalSince1970: 1000)

    @Test func setReplacesAnyDate() {
        #expect(DateAdjustment.set(reference).apply(to: nil) == reference)
    }

    @Test func shiftMovesAnExistingDate() {
        #expect(DateAdjustment.shift(60).apply(to: reference) == Date(timeIntervalSince1970: 1060))
    }

    @Test func shiftLeavesAMissingDateMissing() {
        #expect(DateAdjustment.shift(60).apply(to: nil) == nil)
    }
}

struct ReorderMathTests {
    @Test func movingDownAccountsForRemovedItems() {
        // [a, b, c, d]: moving a to the gap before d gives [b, c, a, d].
        #expect(ReorderMath.destinationIndex(moving: [0], toGap: 3) == 2)
    }

    @Test func movingUpIsUnaffected() {
        #expect(ReorderMath.destinationIndex(moving: [3], toGap: 1) == 1)
    }

    @Test func movingSeveralItems() {
        #expect(ReorderMath.destinationIndex(moving: [0, 2], toGap: 4) == 2)
    }

    @Test(arguments: [1, 2]) func droppingNextToItselfIsANoOp(gap: Int) {
        #expect(ReorderMath.isNoOp(moving: [1], toGap: gap))
    }

    @Test func splitSelectionIsNeverANoOp() {
        #expect(!ReorderMath.isNoOp(moving: [0, 2], toGap: 1))
    }
}

struct GridMetricsTests {
    private func metrics(width: CGFloat = 400, target: CGFloat = 100, count: Int = 10) -> GridMetrics {
        GridMetrics(containerWidth: width, targetSide: target, itemCount: count)
    }

    @Test func columnsAndCellsFitTheWidth() {
        let grid = metrics()
        #expect(grid.columns == 3)
        let lastColumn = grid.frame(at: 2)
        #expect(lastColumn.maxX <= 400 - grid.inset)
    }

    @Test func alwaysHasAtLeastOneColumn() {
        #expect(metrics(width: 10).columns == 1)
    }

    @Test func framesWrapToTheNextRow() {
        let grid = metrics()
        #expect(grid.frame(at: 3).minX == grid.frame(at: 0).minX)
        #expect(grid.frame(at: 3).minY > grid.frame(at: 0).maxY)
    }

    @Test func emptyGridHasNoContent() {
        let grid = metrics(count: 0)
        #expect(grid.contentHeight == 0)
        #expect(grid.indexRange(in: CGRect(x: 0, y: 0, width: 400, height: 400)).isEmpty)
    }

    @Test func indexRangeCoversEveryVisibleItem() {
        let grid = metrics(count: 1_000_000)
        let rect = CGRect(x: 0, y: 50_000, width: 400, height: 600)
        let range = grid.indexRange(in: rect)
        #expect(!range.isEmpty)
        #expect(range.count < 100)
        for index in stride(from: max(0, range.lowerBound - 50), to: range.upperBound + 50, by: 1)
        where grid.frame(at: index).intersects(rect) {
            #expect(range.contains(index))
        }
    }

    @Test func indexRangeStopsAtTheLastItem() {
        let grid = metrics(count: 4)
        let range = grid.indexRange(in: CGRect(x: 0, y: 0, width: 400, height: 10_000))
        #expect(range == 0..<4)
    }

    @Test func nearestGapStaysInBounds() {
        let grid = metrics(count: 4)
        #expect(grid.nearestGap(to: CGPoint(x: -50, y: -50)) == 0)
        #expect(grid.nearestGap(to: CGPoint(x: 10_000, y: 10_000)) == 4)
    }

    @Test func arrowKeysStopAtEdges() {
        let grid = metrics(count: 10)
        #expect(grid.index(from: 0, delta: -1) == nil)
        #expect(grid.index(from: 9, delta: 1) == nil)
        #expect(grid.index(from: 4, delta: 1) == 5)
    }

    @Test func arrowKeysWithNoCurrentItemStartAtAnEnd() {
        let grid = metrics(count: 10)
        #expect(grid.index(from: nil, delta: 1) == 0)
        #expect(grid.index(from: nil, delta: -1) == 9)
    }

    @Test func downArrowLandsOnLastItemFromTheRowAbove() {
        let grid = metrics(count: 10) // 3 columns, and the last row holds only item 9.
        #expect(grid.index(from: 8, delta: 3) == 9)
        #expect(grid.index(from: 9, delta: 3) == nil)
    }
}

struct ImportPlannerTests {
    private func url(_ name: String) -> URL {
        URL(fileURLWithPath: "/imports/\(name)")
    }

    @Test func separateFilesBecomeSeparateAssets() {
        let items = ImportPlanner.plan(files: [url("a.jpg"), url("b.mov")])
        #expect(items == [
            ImportItem(resources: [ImportResource(type: .photo, url: url("a.jpg"))]),
            ImportItem(resources: [ImportResource(type: .video, url: url("b.mov"))]),
        ])
    }

    @Test func imageAndMovieWithSameNamePairAsLivePhoto() {
        let items = ImportPlanner.plan(files: [url("IMG_1.heic"), url("IMG_1.mov")])
        #expect(items == [ImportItem(resources: [
            ImportResource(type: .photo, url: url("IMG_1.heic")),
            ImportResource(type: .pairedVideo, url: url("IMG_1.mov")),
        ])])
    }

    @Test func imageAndRawPair() {
        let items = ImportPlanner.plan(files: [url("DSC_1.jpg"), url("DSC_1.cr2")])
        #expect(items == [ImportItem(resources: [
            ImportResource(type: .photo, url: url("DSC_1.jpg")),
            ImportResource(type: .alternatePhoto, url: url("DSC_1.cr2")),
        ])])
    }

    @Test func nameMatchingIgnoresCase() {
        #expect(ImportPlanner.plan(files: [url("IMG_1.HEIC"), url("img_1.mov")]).count == 1)
    }

    @Test func sameNameInDifferentFoldersDoesNotPair() {
        let files = [URL(fileURLWithPath: "/a/IMG_1.heic"), URL(fileURLWithPath: "/b/IMG_1.mov")]
        #expect(ImportPlanner.plan(files: files).count == 2)
    }

    @Test func unsupportedFilesAreSkipped() {
        #expect(ImportPlanner.plan(files: [url("notes.txt"), url("data.xyzzy")]).isEmpty)
    }

    @Test func ambiguousGroupsAreNotPaired() {
        let items = ImportPlanner.plan(files: [url("a.jpg"), url("a.heic"), url("a.mov")])
        #expect(items.count == 3)
        #expect(items.allSatisfy { $0.resources.count == 1 })
    }

    @Test func failedPairFallsBackToStandaloneTypes() {
        let pair = ImportItem(resources: [
            ImportResource(type: .photo, url: url("a.heic")),
            ImportResource(type: .pairedVideo, url: url("a.mov")),
        ])
        #expect(pair.separated == [
            ImportItem(resources: [ImportResource(type: .photo, url: url("a.heic"))]),
            ImportItem(resources: [ImportResource(type: .video, url: url("a.mov"))]),
        ])
    }

    @Test func foldersExpandRecursivelyAndSkipHiddenFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let nested = root.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data().write(to: root.appendingPathComponent("a.jpg"))
        try Data().write(to: nested.appendingPathComponent("b.jpg"))
        try Data().write(to: root.appendingPathComponent(".hidden.jpg"))

        let names = ImportPlanner.expand([root]).map(\.lastPathComponent).sorted()
        #expect(names == ["a.jpg", "b.jpg"])
    }
}

struct ExportSelectionTests {
    @Test func originalsKeepRawAndLiveVideoButNotEditFiles() {
        let available: [PHAssetResourceType] = [.photo, .alternatePhoto, .pairedVideo, .fullSizePhoto, .adjustmentData]
        #expect(ExportSelection.types(from: available, version: .original) == [.photo, .alternatePhoto, .pairedVideo])
    }

    @Test func currentVersionPrefersRenderedFiles() {
        let available: [PHAssetResourceType] = [.photo, .fullSizePhoto, .pairedVideo, .fullSizePairedVideo, .adjustmentData]
        #expect(ExportSelection.types(from: available, version: .current) == [.fullSizePhoto, .fullSizePairedVideo])
    }

    @Test func currentVersionFallsBackToOriginal() {
        #expect(ExportSelection.types(from: [.photo], version: .current) == [.photo])
        #expect(ExportSelection.types(from: [.video], version: .current) == [.video])
    }

    @Test func renderedFilesTakeTheOriginalName() {
        let name = ExportSelection.fileName(resourceName: "FullSizeRender.jpg", originalName: "IMG_1.HEIC")
        #expect(name == "IMG_1.jpg")
    }

    @Test func uniqueNameLeavesFreeNamesAlone() {
        #expect(ExportSelection.uniqueName("a.jpg") { _ in false } == "a.jpg")
    }

    @Test func uniqueNameCountsPastTakenNames() {
        let taken: Set = ["a.jpg", "a (1).jpg"]
        #expect(ExportSelection.uniqueName("a.jpg") { taken.contains($0) } == "a (2).jpg")
    }
}

struct PhotosScriptTests {
    @Test func literalEscapesQuotesAndBackslashes() {
        #expect(PhotosScript.literal(#"say "hi" \ bye"#) == #""say \"hi\" \\ bye""#)
    }

    @Test func textCannotBreakOutOfAString() {
        let attack = #"x" & (do shell script "id") & ""#
        #expect(PhotosScript.search(attack).contains(#"search for "x\" & (do shell script \"id\") & \"""#))
    }

    @Test func listJoinsEscapedItems() {
        #expect(PhotosScript.list(["a", #"b"c"#]) == #"{"a", "b\"c"}"#)
    }

    // Compiled by `osacompile` in its own process, never with NSAppleScript here.
    // NSAppleScript shares state within a process, so a script compiled in the
    // test host can end up being run by a parallel test, which sends real
    // events to Photos. A separate process can only compile, so this can't.
    @Test func everyScriptCompiles() throws {
        let scripts = [
            PhotosScript.metadata(id: "A/L0/001"),
            PhotosScript.update(id: "A/L0/001", title: "t", description: "d", keywords: ["k"]),
            PhotosScript.addKeywords(ids: ["A/L0/001"], keywords: ["k"]),
            PhotosScript.search("dog"),
            PhotosScript.duplicate(ids: ["A/L0/001"]),
            PhotosScript.reveal(id: "A/L0/001"),
        ]
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        for (index, source) in scripts.enumerated() {
            let sourceURL = directory.appendingPathComponent("\(index).applescript")
            try source.write(to: sourceURL, atomically: true, encoding: .utf8)

            let process = Process()
            let errorOutput = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osacompile")
            process.arguments = ["-o", directory.appendingPathComponent("\(index).scpt").path, sourceURL.path]
            process.standardError = errorOutput
            try process.run()
            process.waitUntilExit()

            let message = String(decoding: errorOutput.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            #expect(process.terminationStatus == 0, "\(source)\n\(message)")
        }
    }
}

/// Parses real AppleScript results. These scripts don't address Photos. They
/// run one at a time because concurrent NSAppleScript use isn't safe.
@Suite(.serialized)
struct PhotosResultParsingTests {
    private func evaluate(_ source: String) throws -> NSAppleEventDescriptor {
        var errorInfo: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&errorInfo)
        return try #require(result, "\(String(describing: errorInfo))")
    }

    @Test func missingValueIsNotText() throws {
        #expect(PhotosAppBridge.text(try evaluate("return missing value")) == nil)
    }

    @Test func textIsRead() throws {
        #expect(PhotosAppBridge.text(try evaluate(#"return "Beach""#)) == "Beach")
    }

    @Test func missingKeywordsAreEmpty() throws {
        #expect(PhotosAppBridge.strings(try evaluate("return missing value")).isEmpty)
    }

    @Test func keywordsAreRead() throws {
        #expect(PhotosAppBridge.strings(try evaluate(#"return {"a", "b"}"#)) == ["a", "b"])
    }

    @Test func missingFileSizeIsNil() throws {
        #expect(PhotosAppBridge.fileSize(try evaluate("return missing value")) == nil)
    }

    @Test func smallFileSizeIsRead() throws {
        #expect(PhotosAppBridge.fileSize(try evaluate("return 2048")) == 2048)
    }

    @Test func fileSizeOverFourGigabytesIsRead() throws {
        #expect(PhotosAppBridge.fileSize(try evaluate("return 5000000000")) == 5_000_000_000)
    }
}

