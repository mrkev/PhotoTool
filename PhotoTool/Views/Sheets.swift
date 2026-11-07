import MapKit
import Photos
import SwiftUI

struct ActiveSheetView: View {
    @Environment(BrowserModel.self) private var browser
    let sheet: ActiveSheet

    var body: some View {
        switch sheet {
        case .newAlbum(let parentID, let assets):
            NameSheet(
                title: assets.isEmpty ? "New Album" : "New Album with \(assets.count.formatted()) \(assets.count == 1 ? "Item" : "Items")",
                initialName: "",
                confirmTitle: "Create"
            ) { browser.createAlbum(title: $0, parentID: parentID, assets: assets) }
        case .newFolder(let parentID):
            NameSheet(title: "New Folder", initialName: "", confirmTitle: "Create") {
                browser.createFolder(title: $0, parentID: parentID)
            }
        case .rename(let node):
            NameSheet(title: "Rename \(node.title)", initialName: node.title, confirmTitle: "Rename") {
                browser.rename(node, to: $0)
            }
        case .adjustDate(let assets):
            AdjustDateSheet(assets: assets)
        case .adjustLocation(let assets):
            AdjustLocationSheet(assets: assets)
        case .addKeywords(let assets):
            AddKeywordsSheet(assets: assets)
        case .dateFilter:
            DateFilterSheet()
        }
    }
}

/// The title, Cancel and confirm buttons shared by every sheet.
private struct SheetContainer<Content: View>: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let confirmTitle: String
    var canConfirm = true
    let confirm: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.headline)
            content
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(confirmTitle) {
                    confirm()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canConfirm)
            }
        }
        .padding(20)
    }
}

private struct NameSheet: View {
    let title: String
    let initialName: String
    let confirmTitle: String
    let onConfirm: (String) -> Void

    @State private var name = ""
    @FocusState private var isFocused: Bool

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        SheetContainer(
            title: title,
            confirmTitle: confirmTitle,
            canConfirm: !trimmedName.isEmpty,
            confirm: { onConfirm(trimmedName) }
        ) {
            TextField("Name", text: $name)
                .focused($isFocused)
        }
        .frame(width: 340)
        .onAppear {
            name = initialName
            isFocused = true
        }
    }
}

private struct AdjustDateSheet: View {
    @Environment(BrowserModel.self) private var browser
    let assets: [PHAsset]

    private enum Mode: Hashable {
        case shift, set
    }

    @State private var mode: Mode = .set
    @State private var date = Date()
    @State private var days = 0
    @State private var hours = 0
    @State private var minutes = 0
    @State private var seconds = 0

    private var shiftSeconds: TimeInterval {
        TimeInterval(days * 86_400 + hours * 3600 + minutes * 60 + seconds)
    }

    var body: some View {
        SheetContainer(
            title: "Adjust Date & Time of \(assets.count.formatted()) \(assets.count == 1 ? "Item" : "Items")",
            confirmTitle: "Adjust",
            canConfirm: mode == .set || shiftSeconds != 0,
            confirm: {
                browser.adjustDates(assets, mode == .set ? .set(date) : .shift(shiftSeconds))
            }
        ) {
            Picker("Change", selection: $mode) {
                Text("Set To").tag(Mode.set)
                Text("Shift By").tag(Mode.shift)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if mode == .set {
                DatePicker("Date & Time", selection: $date, displayedComponents: [.date, .hourAndMinute])
            } else {
                Form {
                    Stepper("Days: \(days)", value: $days, in: -36_500...36_500)
                    Stepper("Hours: \(hours)", value: $hours, in: -23...23)
                    Stepper("Minutes: \(minutes)", value: $minutes, in: -59...59)
                    Stepper("Seconds: \(seconds)", value: $seconds, in: -59...59)
                }
            }
        }
        .frame(width: 360)
        .onAppear {
            if let existing = assets.first?.creationDate {
                date = existing
            }
            // Setting one date on many photos would collapse their order, so
            // batches default to keeping their spacing.
            if assets.count > 1 {
                mode = .shift
            }
        }
    }
}

private struct AdjustLocationSheet: View {
    @Environment(BrowserModel.self) private var browser
    @Environment(\.dismiss) private var dismiss
    let assets: [PHAsset]

    @State private var coordinate: CLLocationCoordinate2D?
    @State private var position: MapCameraPosition = .automatic
    @State private var searchText = ""
    @State private var searchMessage: String?

    private var hasExistingLocation: Bool {
        assets.contains { $0.location != nil }
    }

    var body: some View {
        SheetContainer(
            title: "Adjust Location of \(assets.count.formatted()) \(assets.count == 1 ? "Item" : "Items")",
            confirmTitle: "Set Location",
            canConfirm: coordinate != nil,
            confirm: {
                if let coordinate {
                    browser.setLocation(assets, CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude))
                }
            }
        ) {
            TextField("Search for a place", text: $searchText)
                .onSubmit { Task { await search() } }
            if let searchMessage {
                Text(searchMessage).font(.callout).foregroundStyle(.secondary)
            }

            MapReader { proxy in
                Map(position: $position) {
                    if let coordinate {
                        Marker("Location", coordinate: coordinate)
                    }
                }
                .onTapGesture { point in
                    if let tapped = proxy.convert(point, from: .local) {
                        coordinate = tapped
                    }
                }
            }
            .frame(height: 320)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .accessibilityLabel("Map. Click to choose a location.")

            HStack {
                TextField("Latitude", value: latitude, format: .number.precision(.fractionLength(0...6)))
                TextField("Longitude", value: longitude, format: .number.precision(.fractionLength(0...6)))
            }

            if hasExistingLocation {
                Button("Remove Location", role: .destructive) {
                    browser.setLocation(assets, nil)
                    dismiss()
                }
            }
        }
        .frame(width: 520)
        .onAppear {
            if let existing = assets.first?.location?.coordinate {
                coordinate = existing
                position = .region(MKCoordinateRegion(center: existing, latitudinalMeters: 5000, longitudinalMeters: 5000))
            }
        }
    }

    private var latitude: Binding<Double?> {
        Binding(
            get: { coordinate?.latitude },
            set: { newValue in
                guard let newValue, (-90...90).contains(newValue) else { return }
                coordinate = CLLocationCoordinate2D(latitude: newValue, longitude: coordinate?.longitude ?? 0)
            }
        )
    }

    private var longitude: Binding<Double?> {
        Binding(
            get: { coordinate?.longitude },
            set: { newValue in
                guard let newValue, (-180...180).contains(newValue) else { return }
                coordinate = CLLocationCoordinate2D(latitude: coordinate?.latitude ?? 0, longitude: newValue)
            }
        )
    }

    private func search() async {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = searchText
        searchMessage = nil
        guard let found = try? await MKLocalSearch(request: request).start().mapItems.first else {
            searchMessage = "No places found."
            return
        }
        let center = found.placemark.coordinate
        coordinate = center
        position = .region(MKCoordinateRegion(center: center, latitudinalMeters: 5000, longitudinalMeters: 5000))
    }
}

private struct AddKeywordsSheet: View {
    @Environment(BrowserModel.self) private var browser
    let assets: [PHAsset]

    @State private var text = ""

    private var keywords: [String] {
        text.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    var body: some View {
        SheetContainer(
            title: "Add Keywords to \(assets.count.formatted()) \(assets.count == 1 ? "Item" : "Items")",
            confirmTitle: "Add",
            canConfirm: !keywords.isEmpty,
            confirm: { browser.addKeywords(keywords, to: assets) }
        ) {
            TextField("Keywords, separated by commas", text: $text)
            Text("Existing keywords are kept.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(width: 380)
    }
}

private struct DateFilterSheet: View {
    @Environment(BrowserModel.self) private var browser

    @State private var start = Calendar.current.date(byAdding: .year, value: -1, to: Date()) ?? Date()
    @State private var end = Date()

    var body: some View {
        SheetContainer(
            title: "Show Photos Taken Between",
            confirmTitle: "Apply",
            canConfirm: start <= end,
            confirm: {
                let dayEnd = Calendar.current.date(bySettingHour: 23, minute: 59, second: 59, of: end) ?? end
                browser.query.dateRange = Calendar.current.startOfDay(for: start)...dayEnd
            }
        ) {
            DatePicker("From", selection: $start, displayedComponents: .date)
            DatePicker("To", selection: $end, displayedComponents: .date)
        }
        .frame(width: 320)
        .onAppear {
            if let range = browser.query.dateRange {
                start = range.lowerBound
                end = range.upperBound
            }
        }
    }
}
