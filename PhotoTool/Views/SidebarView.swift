import SwiftUI

struct SidebarView: View {
    @Environment(LibraryStore.self) private var store
    @Environment(BrowserModel.self) private var browser

    var body: some View {
        let sidebar = store.sidebar
        List(selection: selection) {
            Section("Library") {
                Label("All Photos", systemImage: "photo.on.rectangle")
                    .tag(LibrarySource.allPhotos)
                ForEach(sidebar.library) { SidebarRow(node: $0) }
            }
            if !sidebar.mediaTypes.isEmpty {
                Section("Media Types") {
                    ForEach(sidebar.mediaTypes) { SidebarRow(node: $0) }
                }
            }
            if !sidebar.utilities.isEmpty {
                Section("Utilities") {
                    ForEach(sidebar.utilities) { SidebarRow(node: $0) }
                }
            }
            if !sidebar.sharedAlbums.isEmpty {
                Section("Shared Albums") {
                    ForEach(sidebar.sharedAlbums) { SidebarRow(node: $0) }
                }
            }
            Section("My Albums") {
                OutlineGroup(sidebar.myAlbums, children: \.children) { SidebarRow(node: $0) }
            }
        }
        .listStyle(.sidebar)
        .contextMenu {
            Button("New Album…") { browser.activeSheet = .newAlbum(parentID: nil, assets: []) }
            Button("New Folder…") { browser.activeSheet = .newFolder(parentID: nil) }
        }
        .navigationSplitViewColumnWidth(min: 180, ideal: 230)
        .onChange(of: sidebar) {
            browser.sidebarDidChange()
        }
    }

    private var selection: Binding<LibrarySource?> {
        Binding(
            get: { browser.sidebarSelection },
            set: { newValue in
                guard let newValue else { return }
                browser.searchText = ""
                browser.show(newValue)
            }
        )
    }
}

private struct SidebarRow: View {
    @Environment(LibraryStore.self) private var store
    @Environment(BrowserModel.self) private var browser
    let node: CollectionNode

    @State private var isDropTargeted = false

    var body: some View {
        rowContent
            .tag(LibrarySource.collection(node.id))
            .selectionDisabled(node.isFolder)
            .contextMenu { menu }
            .accessibilityLabel(accessibilityText)
    }

    @ViewBuilder
    private var rowContent: some View {
        let label = HStack {
            Label(node.title, systemImage: node.symbol)
            Spacer()
            if let count = node.count {
                Text(count.formatted())
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        if node.kind == .album, node.canAddContent {
            label
                .contentShape(Rectangle())
                .dropDestination(for: String.self) { items, _ in
                    let ids = AssetDragPayload.decode(items)
                    guard !ids.isEmpty else { return false }
                    browser.addDraggedAssets(ids: ids, toAlbum: node.id)
                    return true
                } isTargeted: { isDropTargeted = $0 }
                .listRowBackground(isDropTargeted ? Color.accentColor.opacity(0.25) : nil)
        } else {
            label
        }
    }

    private var accessibilityText: String {
        guard let count = node.count else { return "\(node.title), folder" }
        return "\(node.title), \(count) \(count == 1 ? "item" : "items")"
    }

    @ViewBuilder
    private var menu: some View {
        if node.kind == .album || node.isFolder {
            if node.isFolder {
                Button("New Album in \(node.title)…") {
                    browser.activeSheet = .newAlbum(parentID: node.id, assets: [])
                }
                Button("New Folder in \(node.title)…") {
                    browser.activeSheet = .newFolder(parentID: node.id)
                }
                Divider()
            }
            Button("Rename…") { browser.activeSheet = .rename(node) }
                .disabled(!node.canRename)
            moveMenu
            Divider()
            Button("Delete \(node.isFolder ? "Folder" : "Album")…") { browser.delete(node) }
                .disabled(!node.canDelete)
        }
    }

    @ViewBuilder
    private var moveMenu: some View {
        let siblings = store.siblings(of: node)
        let index = siblings.firstIndex { $0.id == node.id }
        Menu("Move To") {
            Button("Top Level") { browser.move(node, toParent: nil) }
                .disabled(node.parentID == nil)
            let destinations = store.allFolders.filter { folder in
                // A folder can't move into itself or into its own subfolders.
                !node.flattened.contains { $0.id == folder.node.id }
            }
            if !destinations.isEmpty {
                Divider()
                ForEach(destinations, id: \.node.id) { folder in
                    Button(folder.path) { browser.move(node, toParent: folder.node.id) }
                        .disabled(node.parentID == folder.node.id)
                }
            }
        }
        Button("Move Up") { browser.moveSibling(node, by: -1) }
            .disabled((index ?? 0) == 0)
        Button("Move Down") { browser.moveSibling(node, by: 1) }
            .disabled(index.map { $0 >= siblings.count - 1 } ?? true)
    }
}
