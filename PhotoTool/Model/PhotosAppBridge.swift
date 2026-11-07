import Foundation

nonisolated struct PhotosAppMetadata: Equatable, Sendable {
    var title: String
    var description: String
    var keywords: [String]
    var fileSize: Int?
}

nonisolated enum PhotosAppError: LocalizedError {
    case notAuthorized
    case script(String)

    var errorDescription: String? {
        switch self {
        case .notAuthorized:
            "PhotoTool isn't allowed to control Photos. Turn it on in System Settings > Privacy & Security > Automation."
        case .script(let message):
            message
        }
    }
}

/// Builds the AppleScript the bridge runs. Every caller-supplied string goes
/// through `literal`, so text in a title or keyword can't alter the script.
nonisolated enum PhotosScript {
    static func literal(_ string: String) -> String {
        let escaped = string
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    static func list(_ strings: [String]) -> String {
        "{" + strings.map(literal).joined(separator: ", ") + "}"
    }

    static func wrap(_ body: String) -> String {
        """
        tell application id "com.apple.Photos"
            with timeout of 600 seconds
                \(body)
            end timeout
        end tell
        """
    }

    static func metadata(id: String) -> String {
        wrap("""
        set theItem to media item id \(literal(id))
        return {name of theItem, description of theItem, keywords of theItem, size of theItem}
        """)
    }

    static func update(id: String, title: String, description: String, keywords: [String]) -> String {
        wrap("""
        set theItem to media item id \(literal(id))
        set name of theItem to \(literal(title))
        set description of theItem to \(literal(description))
        set keywords of theItem to \(list(keywords))
        """)
    }

    static func addKeywords(ids: [String], keywords: [String]) -> String {
        wrap("""
        repeat with theID in \(list(ids))
            set theItem to media item id (theID as text)
            set theKeywords to keywords of theItem
            if theKeywords is missing value then set theKeywords to {}
            repeat with theKeyword in \(list(keywords))
                if theKeywords does not contain (theKeyword as text) then set end of theKeywords to (theKeyword as text)
            end repeat
            set keywords of theItem to theKeywords
        end repeat
        """)
    }

    static func search(_ text: String) -> String {
        wrap("""
        set theResults to search for \(literal(text))
        set theIDs to {}
        repeat with theItem in theResults
            set end of theIDs to id of theItem
        end repeat
        return theIDs
        """)
    }

    static func duplicate(ids: [String]) -> String {
        wrap("""
        repeat with theID in \(list(ids))
            duplicate media item id (theID as text)
        end repeat
        """)
    }

    static func reveal(id: String) -> String {
        wrap("""
        activate
        spotlight media item id \(literal(id))
        """)
    }
}

/// Reaches what PhotoKit doesn't expose by scripting Photos.app: titles,
/// descriptions, keywords, file sizes, content search, and duplicating items.
/// It relies on `media item` IDs matching `PHAsset.localIdentifier`.
nonisolated final class PhotosAppBridge: @unchecked Sendable {
    static let enabledKey = "photosAppIntegrationEnabled"
    static let shared = PhotosAppBridge()

    /// All scripts must share this serial queue. Concurrent `NSAppleScript` use
    /// isn't just racy: one instance can end up running another's compiled
    /// script. Being off the main thread also keeps a slow Photos launch from
    /// blocking the UI.
    private let queue = DispatchQueue(label: "com.aykev.PhotoTool.photos-bridge", qos: .userInitiated)

    func metadata(id: String) async throws -> PhotosAppMetadata {
        let result = try await run(PhotosScript.metadata(id: id))
        return PhotosAppMetadata(
            title: result.atIndex(1).flatMap(Self.text) ?? "",
            description: result.atIndex(2).flatMap(Self.text) ?? "",
            keywords: result.atIndex(3).map(Self.strings) ?? [],
            fileSize: result.atIndex(4).flatMap(Self.fileSize)
        )
    }

    func update(id: String, title: String, description: String, keywords: [String]) async throws {
        _ = try await run(PhotosScript.update(id: id, title: title, description: description, keywords: keywords))
    }

    func addKeywords(_ keywords: [String], to ids: [String]) async throws {
        _ = try await run(PhotosScript.addKeywords(ids: ids, keywords: keywords))
    }

    /// Runs the same search as the Search field in Photos.app.
    func search(_ text: String) async throws -> [String] {
        Self.strings(try await run(PhotosScript.search(text)))
    }

    func duplicate(ids: [String]) async throws {
        _ = try await run(PhotosScript.duplicate(ids: ids))
    }

    func reveal(id: String) async throws {
        _ = try await run(PhotosScript.reveal(id: id))
    }

    /// AppleScript's `missing value` has a type code of its own. Reading it as
    /// a string would give the literal text "msng".
    private static func isMissing(_ descriptor: NSAppleEventDescriptor) -> Bool {
        let typeCodeForType: DescType = 0x7479_7065 // 'type'
        return descriptor.descriptorType == typeCodeForType
    }

    static func text(_ descriptor: NSAppleEventDescriptor) -> String? {
        isMissing(descriptor) ? nil : descriptor.stringValue
    }

    /// Read as a double because sizes over 2 GB don't fit AppleScript's 32-bit
    /// integers, so Photos sends those as reals.
    static func fileSize(_ descriptor: NSAppleEventDescriptor) -> Int? {
        guard !isMissing(descriptor) else { return nil }
        let size = descriptor.doubleValue
        return size > 0 ? Int(size) : nil
    }

    static func strings(_ descriptor: NSAppleEventDescriptor) -> [String] {
        guard descriptor.numberOfItems > 0 else { return [] }
        return (1...descriptor.numberOfItems).compactMap { descriptor.atIndex($0).flatMap(text) }
    }

    private func run(_ source: String) async throws -> NSAppleEventDescriptor {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                var errorInfo: NSDictionary?
                let script = NSAppleScript(source: source)
                if let result = script?.executeAndReturnError(&errorInfo), errorInfo == nil {
                    continuation.resume(returning: result)
                    return
                }
                let number = errorInfo?[NSAppleScript.errorNumber] as? Int
                let message = errorInfo?[NSAppleScript.errorMessage] as? String
                if number == -1743 {
                    continuation.resume(throwing: PhotosAppError.notAuthorized)
                } else {
                    continuation.resume(throwing: PhotosAppError.script(message ?? "Photos couldn't complete the request."))
                }
            }
        }
    }
}
