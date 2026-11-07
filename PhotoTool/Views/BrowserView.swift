import Photos
import SwiftUI

struct BrowserView: View {
    @Environment(BrowserModel.self) private var browser

    var body: some View {
        @Bindable var browser = browser
        NavigationSplitView {
            SidebarView()
        } detail: {
            BrowserDetail()
                .inspector(isPresented: $browser.showInspector) {
                    InspectorView()
                        .inspectorColumnWidth(min: 240, ideal: 280, max: 400)
                }
        }
        .navigationTitle(browser.title)
        .navigationSubtitle(browser.subtitle)
        .searchable(text: $browser.searchText, placement: .toolbar, prompt: "Search with Photos")
        .onSubmit(of: .search) { browser.runSearch() }
        .onChange(of: browser.searchText) { _, text in
            if text.isEmpty { browser.clearSearch() }
        }
        .toolbar { BrowserToolbar() }
        .sheet(item: $browser.activeSheet) { ActiveSheetView(sheet: $0) }
        .alert(
            browser.alert?.title ?? "",
            isPresented: Binding(
                get: { browser.alert != nil },
                set: { if !$0 { browser.alert = nil } }
            ),
            presenting: browser.alert
        ) { _ in
            Button("OK") {}
        } message: { info in
            Text(info.message)
        }
    }
}

/// The grid, with the viewer layered on top. The grid stays alive underneath,
/// so closing the viewer returns to the same scroll position and selection.
private struct BrowserDetail: View {
    @Environment(BrowserModel.self) private var browser

    var body: some View {
        ZStack {
            AssetGridView(
                browser: browser,
                thumbnailSize: browser.thumbnailSize,
                square: browser.squareThumbnails
            )
            .accessibilityHidden(browser.viewerAsset != nil)

            if browser.fetchResult?.count == 0 {
                emptyState
            }

            if let asset = browser.viewerAsset {
                AssetViewer(asset: asset)
            }
        }
        .overlay(alignment: .bottom) {
            if let activity = browser.activity {
                ActivityBar(activity: activity)
                    .padding()
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if browser.query.isUnfiltered {
            ContentUnavailableView("No Photos", systemImage: "photo", description: Text("Drag photos here or choose File > Import."))
        } else {
            ContentUnavailableView {
                Label("No Matching Photos", systemImage: "line.3.horizontal.decrease.circle")
            } actions: {
                Button("Clear Filters") { browser.clearFilters() }
            }
        }
    }
}

private struct ActivityBar: View {
    let activity: Activity

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(activity.title) \(activity.completed.formatted()) of \(activity.total.formatted())")
                    .font(.callout)
                ProgressView(value: Double(activity.completed), total: Double(max(activity.total, 1)))
            }
            Button("Cancel") { activity.task?.cancel() }
        }
        .padding(12)
        .frame(maxWidth: 360)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .shadow(radius: 6)
    }
}

private struct BrowserToolbar: ToolbarContent {
    @Environment(BrowserModel.self) private var browser

    var body: some ToolbarContent {
        @Bindable var browser = browser

        if browser.isShowingTemporarySource {
            ToolbarItem(placement: .navigation) {
                Button("Back", systemImage: "chevron.backward") { browser.showPreviousSource() }
            }
        }

        ToolbarItem {
            Slider(value: $browser.thumbnailSize, in: BrowserModel.thumbnailRange) {
                Text("Thumbnail Size")
            } minimumValueLabel: {
                Image(systemName: "photo").imageScale(.small)
            } maximumValueLabel: {
                Image(systemName: "photo").imageScale(.large)
            }
            .labelsHidden()
            .frame(width: 140)
            .help("Thumbnail Size")
        }

        ToolbarItem {
            SortMenu()
        }

        ToolbarItem {
            FilterMenu()
        }

        ToolbarItem {
            Button(
                "Favorite",
                systemImage: browser.firstTarget?.isFavorite == true ? "heart.fill" : "heart"
            ) {
                browser.toggleFavorite()
            }
            .disabled(!browser.hasTargets)
            .help("Add to or remove from Favorites")
        }

        ToolbarItem {
            Button("Delete", systemImage: "trash") { browser.deleteTargets() }
                .disabled(!browser.hasTargets)
                .help("Delete from Library")
        }

        ToolbarItem {
            Button("Info", systemImage: "info.circle") { browser.showInspector.toggle() }
                .help("Show or hide Info")
        }
    }
}

private struct SortMenu: View {
    @Environment(BrowserModel.self) private var browser

    var body: some View {
        @Bindable var browser = browser
        Menu("Sort", systemImage: "arrow.up.arrow.down") {
            Picker("Sort By", selection: $browser.query.sortKey) {
                ForEach(AssetSortKey.allCases) { key in
                    if key != .albumOrder || browser.currentAlbumAllowsManualOrder {
                        Text(key.title).tag(key)
                    }
                }
            }
            .pickerStyle(.inline)
            if browser.query.sortKey != .albumOrder {
                Picker("Order", selection: $browser.query.ascending) {
                    Text("Ascending").tag(true)
                    Text("Descending").tag(false)
                }
                .pickerStyle(.inline)
            }
        }
        .help("Sort")
    }
}

private struct FilterMenu: View {
    @Environment(BrowserModel.self) private var browser

    var body: some View {
        @Bindable var browser = browser
        Menu(
            "Filter",
            systemImage: browser.query.isUnfiltered ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill"
        ) {
            Picker("Show", selection: $browser.query.media) {
                ForEach(MediaFilter.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.inline)
            Toggle("Favorites Only", isOn: $browser.query.favoritesOnly)
            Divider()
            Button(browser.query.dateRange == nil ? "Date Range…" : "Edit Date Range…") {
                browser.activeSheet = .dateFilter
            }
            if browser.query.dateRange != nil {
                Button("Clear Date Range") { browser.query.dateRange = nil }
            }
            if !browser.query.isUnfiltered {
                Divider()
                Button("Clear All Filters") { browser.clearFilters() }
            }
        }
        .help("Filter")
    }
}

extension BrowserModel {
    func clearFilters() {
        query.media = .all
        query.favoritesOnly = false
        query.dateRange = nil
    }
}
