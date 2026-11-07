import AppKit
import Photos
import SwiftUI

/// One command, defined once and shown in both the menu bar and context menu.
struct AssetMenuAction: Identifiable {
    let id: String
    let title: String
    var shortcut: KeyboardShortcut?
    var isEnabled = true
    let perform: () -> Void
}

enum AssetMenuEntry: Identifiable {
    case action(AssetMenuAction)
    case submenu(id: String, title: String, items: [AssetMenuAction])
    case separator(id: String)

    var id: String {
        switch self {
        case .action(let action): action.id
        case .submenu(let id, _, _): id
        case .separator(let id): id
        }
    }
}

extension BrowserModel {
    var assetMenuEntries: [AssetMenuEntry] {
        let hasTargets = hasTargets
        let first = firstTarget
        // Titles are based on the first item, which keeps menus fast after
        // Select All. The action itself checks the whole selection.
        let isFavorite = first?.isFavorite ?? false
        let isHidden = first?.isHidden ?? false

        var addToAlbum: [AssetMenuAction] = [
            AssetMenuAction(id: "newAlbumFromSelection", title: "New Album…", isEnabled: hasTargets) { [self] in
                activeSheet = .newAlbum(parentID: nil, assets: targetAssets)
            },
        ]
        addToAlbum += store.addableAlbums.map { album in
            AssetMenuAction(id: "add-\(album.node.id)", title: album.path, isEnabled: hasTargets) { [self] in
                add(targetAssets, toAlbum: album.node.id)
            }
        }

        var entries: [AssetMenuEntry] = [
            .action(AssetMenuAction(
                id: "favorite",
                title: isFavorite ? "Remove from Favorites" : "Add to Favorites",
                isEnabled: hasTargets
            ) { [self] in toggleFavorite() }),
            .action(AssetMenuAction(
                id: "hide",
                title: isHidden ? "Unhide" : "Hide",
                shortcut: KeyboardShortcut("l", modifiers: .command),
                isEnabled: hasTargets
            ) { [self] in toggleHidden() }),
            .separator(id: "sep-1"),
            .submenu(id: "addToAlbum", title: "Add to Album", items: addToAlbum),
        ]

        if let node = currentNode, node.canRemoveContent {
            entries.append(.action(AssetMenuAction(
                id: "removeFromAlbum",
                title: "Remove from \(node.title)",
                isEnabled: hasTargets
            ) { [self] in removeTargetsFromCurrentAlbum() }))
        }

        entries += [
            .separator(id: "sep-2"),
            .action(AssetMenuAction(
                id: "adjustDate",
                title: "Adjust Date & Time…",
                isEnabled: hasTargets
            ) { [self] in activeSheet = .adjustDate(targetAssets) }),
            .action(AssetMenuAction(
                id: "adjustLocation",
                title: "Adjust Location…",
                isEnabled: hasTargets
            ) { [self] in activeSheet = .adjustLocation(targetAssets) }),
        ]

        if let burstID = first?.burstIdentifier {
            entries.append(.action(AssetMenuAction(id: "showBurst", title: "Show All Burst Photos") { [self] in
                viewerAsset = nil
                show(.burst(burstID))
            }))
        }

        if isPhotosAppEnabled {
            entries += [
                .separator(id: "sep-3"),
                .action(AssetMenuAction(
                    id: "addKeywords",
                    title: "Add Keywords…",
                    shortcut: KeyboardShortcut("k", modifiers: .command),
                    isEnabled: hasTargets
                ) { [self] in activeSheet = .addKeywords(targetAssets) }),
                .action(AssetMenuAction(
                    id: "duplicate",
                    title: "Duplicate",
                    shortcut: KeyboardShortcut("d", modifiers: .command),
                    isEnabled: hasTargets
                ) { [self] in duplicateTargets() }),
                .action(AssetMenuAction(
                    id: "reveal",
                    title: "Show in Photos",
                    isEnabled: hasTargets
                ) { [self] in revealInPhotos() }),
            ]
        }

        entries += [
            .separator(id: "sep-4"),
            .action(AssetMenuAction(
                id: "export",
                title: "Export…",
                shortcut: KeyboardShortcut("e", modifiers: [.command, .shift]),
                isEnabled: hasTargets
            ) { [self] in chooseExportDestination(version: .current) }),
            .action(AssetMenuAction(
                id: "exportOriginals",
                title: "Export Originals…",
                shortcut: KeyboardShortcut("e", modifiers: [.command, .shift, .option]),
                isEnabled: hasTargets
            ) { [self] in chooseExportDestination(version: .original) }),
            .separator(id: "sep-5"),
            .action(AssetMenuAction(
                id: "delete",
                title: "Delete from Library…",
                shortcut: KeyboardShortcut(.delete, modifiers: .command),
                isEnabled: hasTargets
            ) { [self] in deleteTargets() }),
        ]
        return entries
    }
}

/// The menu bar version of the entries.
struct AssetMenuItems: View {
    let browser: BrowserModel

    var body: some View {
        ForEach(browser.assetMenuEntries) { entry in
            switch entry {
            case .action(let action):
                row(action)
            case .submenu(_, let title, let items):
                Menu(title) {
                    ForEach(items) { row($0) }
                }
            case .separator:
                Divider()
            }
        }
    }

    private func row(_ action: AssetMenuAction) -> some View {
        Button(action.title, action: action.perform)
            .keyboardShortcut(action.shortcut)
            .disabled(!action.isEnabled)
    }
}

/// An `NSMenuItem` that runs a closure, for the grid's AppKit context menu.
private final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, isEnabled: Bool, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
        self.isEnabled = isEnabled
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    @objc private func fire() {
        handler()
    }
}

extension NSMenu {
    /// The context menu version of the entries.
    convenience init(entries: [AssetMenuEntry]) {
        self.init()
        autoenablesItems = false
        for entry in entries {
            switch entry {
            case .action(let action):
                addItem(ClosureMenuItem(title: action.title, isEnabled: action.isEnabled, handler: action.perform))
            case .submenu(_, let title, let items):
                let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                parent.submenu = NSMenu(entries: items.map(AssetMenuEntry.action))
                addItem(parent)
            case .separator:
                addItem(.separator())
            }
        }
    }
}
