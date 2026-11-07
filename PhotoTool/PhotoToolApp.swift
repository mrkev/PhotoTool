//
//  PhotoToolApp.swift
//  PhotoTool
//
//  Created by Kevin on 06/11/26.
//

import SwiftUI

@main
struct PhotoToolApp: App {
    @State private var store: LibraryStore
    @State private var browser: BrowserModel

    init() {
        let store = LibraryStore()
        _store = State(initialValue: store)
        _browser = State(initialValue: BrowserModel(store: store))
    }

    var body: some Scene {
        Window("PhotoTool", id: "main") {
            RootView()
                .environment(store)
                .environment(browser)
        }
        .defaultSize(width: 1200, height: 800)
        .commands {
            LibraryCommands(browser: browser)
        }

        Settings {
            SettingsView()
        }
    }
}

struct LibraryCommands: Commands {
    let browser: BrowserModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            FileMenuItems(browser: browser)
        }
        CommandGroup(after: .pasteboard) {
            DeselectItem(browser: browser)
        }
        CommandGroup(before: .toolbar) {
            ViewMenuItems(browser: browser)
            Divider()
        }
        CommandMenu("Photo") {
            AssetMenuItems(browser: browser)
        }
    }
}

// Menu contents are views so that they track changes to the model.

private struct FileMenuItems: View {
    let browser: BrowserModel

    var body: some View {
        let isReady = browser.store.isAuthorized
        Button("New Album…") {
            browser.activeSheet = .newAlbum(parentID: nil, assets: [])
        }
        .keyboardShortcut("n")
        .disabled(!isReady)

        Button("New Album with Selection…") {
            browser.activeSheet = .newAlbum(parentID: nil, assets: browser.targetAssets)
        }
        .keyboardShortcut("n", modifiers: [.command, .shift])
        .disabled(!browser.hasTargets)

        Button("New Folder…") {
            browser.activeSheet = .newFolder(parentID: nil)
        }
        .keyboardShortcut("n", modifiers: [.command, .option])
        .disabled(!isReady)

        Divider()

        Button("Import…") {
            browser.chooseFilesToImport()
        }
        .keyboardShortcut("i", modifiers: [.command, .shift])
        .disabled(!isReady)
    }
}

private struct DeselectItem: View {
    let browser: BrowserModel

    var body: some View {
        Button("Deselect All") {
            browser.deselectAll()
        }
        .keyboardShortcut("a", modifiers: [.command, .shift])
        .disabled(browser.selection.isEmpty)
    }
}

private struct ViewMenuItems: View {
    let browser: BrowserModel

    var body: some View {
        Button("Larger Thumbnails") {
            browser.thumbnailSize = min(browser.thumbnailSize * 1.25, BrowserModel.thumbnailRange.upperBound)
        }
        .keyboardShortcut("=")

        Button("Smaller Thumbnails") {
            browser.thumbnailSize = max(browser.thumbnailSize / 1.25, BrowserModel.thumbnailRange.lowerBound)
        }
        .keyboardShortcut("-")

        Toggle("Square Thumbnails", isOn: Binding(
            get: { browser.squareThumbnails },
            set: { browser.squareThumbnails = $0 }
        ))

        Toggle("Info", isOn: Binding(
            get: { browser.showInspector },
            set: { browser.showInspector = $0 }
        ))
        .keyboardShortcut("i")
    }
}
