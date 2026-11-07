import Photos
import SwiftUI

/// Shows the library once access is granted, and explains what's needed if not.
struct RootView: View {
    @Environment(LibraryStore.self) private var store
    @Environment(BrowserModel.self) private var browser
    @Environment(\.openURL) private var openURL

    var body: some View {
        Group {
            if let reason = store.unavailableReason {
                ContentUnavailableView("Library Unavailable", systemImage: "exclamationmark.triangle", description: Text(reason))
            } else if store.isAuthorized {
                BrowserView()
            } else if store.authorization == .notDetermined {
                requestAccess
            } else {
                accessDenied
            }
        }
        .frame(minWidth: 800, minHeight: 500)
        .task(id: store.isAuthorized) {
            guard store.isAuthorized else { return }
            store.start()
            browser.start()
        }
    }

    private var requestAccess: some View {
        ContentUnavailableView {
            Label("Connect Your Photo Library", systemImage: "photo.on.rectangle.angled")
        } description: {
            Text("PhotoTool needs full access to browse and organize your photos.")
        } actions: {
            Button("Allow Access") {
                Task { await store.requestAccess() }
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var accessDenied: some View {
        ContentUnavailableView {
            Label("No Access to Photos", systemImage: "lock")
        } description: {
            Text("Allow PhotoTool in System Settings > Privacy & Security > Photos.")
        } actions: {
            Button("Open Privacy Settings") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos") {
                    openURL(url)
                }
            }
        }
    }
}

struct SettingsView: View {
    @AppStorage(PhotosAppBridge.enabledKey) private var isPhotosAppEnabled = false

    var body: some View {
        Form {
            Section {
                Toggle("Use the Photos app for extra features", isOn: $isPhotosAppEnabled)
            } footer: {
                Text("Adds titles, descriptions, keywords, file sizes, search, and duplicating, which aren't available to apps through PhotoKit. PhotoTool controls Photos to do this, so Photos will open and macOS will ask for your permission.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
    }
}
