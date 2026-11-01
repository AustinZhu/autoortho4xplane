import SwiftUI
import AppKit

struct NativeSettingsView: View {
    @EnvironmentObject var model: AppModel
    @NativeState<String?> private var page: String?
    @NativeState<String> private var filter: String
    init(page: String? = nil, filter: String = "") {
        _page = NativeState(initialValue: page ?? UserDefaults.standard.string(forKey: "lastSettingsPage") ?? "general")
        _filter = NativeState(initialValue: filter)
    }
    var visible: [Setting] { (model.snapshot?.settings ?? []).filter(SettingsCatalog.isVisible) }
    var pages: [SettingsPage] {
        let used = Set(visible.map { SettingsCatalog.placement(of: $0).page })
        return SettingsCatalog.pages.filter { used.contains($0.id) }
    }
    var body: some View {
        NavigationSplitView {
            List(pages, selection: $page) { page in
                SidebarLabel(title: page.title, symbol: page.symbol, selected: self.page == page.id).tag(page.id)
            }
            .navigationSplitViewColumnWidth(180)
        } detail: {
            Form {
                ForEach(sections, id: \.title) { section in
                    Section(section.title) {
                        ForEach(section.settings) { SettingRow(setting: $0) }
                    }
                }
                if sections.isEmpty && !filter.isEmpty {
                    Text("No settings match “\(filter)”.").foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped).disabled(model.running || model.busy)
            // Pinned to the detail pane so the split view can't push it out of the window.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) { Divider(); footer.padding(12) }.background(.bar)
            }
        }
        .frame(minWidth: 850, minHeight: 620)
        .searchable(text: $filter, prompt: "Search settings")
        .navigationTitle("AutoOrtho Settings")
        .onChange(of: page) { UserDefaults.standard.set(page, forKey: "lastSettingsPage") }
        .alert("Settings could not be saved", isPresented: Binding(get: { model.settingsError != nil }, set: { if !$0 { model.settingsError = nil } })) {
            if conflict {
                Button("Discard Changes and Reload", role: .destructive) { model.settingsError = nil; Task { await model.reloadSettings() } }
                Button("Cancel", role: .cancel) { model.settingsError = nil }
            } else {
                Button("OK", role: .cancel) { model.settingsError = nil }
            }
        } message: { Text(model.settingsError ?? "") }
    }
    var conflict: Bool { model.settingsError?.contains("another app") == true }

    @ViewBuilder var footer: some View {
        HStack {
            if model.running {
                Label("Settings are locked while streaming.", systemImage: "lock").foregroundStyle(.secondary)
                Spacer()
                Button("Stop Streaming") { model.requestStop() }.disabled(!model.canStop)
            } else {
                Text(model.edits.isEmpty ? "Settings are up to date." : model.edits.count == 1 ? "1 unapplied change" : "\(model.edits.count) unapplied changes")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Revert") { model.revert() }.disabled(model.edits.isEmpty || model.busy)
                Button("Apply") { Task { await model.save() } }
                    .keyboardShortcut("s", modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(model.edits.isEmpty || model.busy)
            }
        }.font(.callout)
    }

    struct SectionContent { let title: String; let settings: [Setting] }
    /// The selected page's groups in catalog order, or matches from every page while searching.
    var sections: [SectionContent] {
        let matches = filter.isEmpty ? visible : visible.filter {
            $0.title.localizedCaseInsensitiveContains(filter) || $0.help.localizedCaseInsensitiveContains(filter) || $0.key.localizedCaseInsensitiveContains(filter)
        }
        // A remembered page that no longer exists falls back to the first page.
        let current = pages.contains { $0.id == page } ? page : pages.first?.id
        let scoped = filter.isEmpty ? pages.filter { $0.id == current } : pages
        return scoped.flatMap { page -> [SectionContent] in
            let items = matches.filter { SettingsCatalog.placement(of: $0).page == page.id }
            let groups = page.groups + Set(items.map { SettingsCatalog.placement(of: $0).group }).subtracting(page.groups).sorted()
            return groups.compactMap { group in
                let rows = items.filter { SettingsCatalog.placement(of: $0).group == group }
                guard !rows.isEmpty else { return nil }
                return SectionContent(title: filter.isEmpty ? group : "\(page.title) › \(group)", settings: rows)
            }
        }
    }
}

struct SettingRow: View {
    @EnvironmentObject var model: AppModel
    let setting: Setting
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            control
            if let help = SettingsCatalog.help(for: setting), !help.isEmpty { Text(help).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        }
        .padding(.vertical, 3)
        .help(model.edits[setting.id] != nil ? "Changed — not applied yet" : "")
    }
    var title: Text {
        model.edits[setting.id] != nil ? Text("\(setting.title) ") + Text("•").foregroundColor(.accentColor) : Text(setting.title)
    }
    @ViewBuilder var control: some View {
        let choices = SettingsCatalog.choices(setting.id)
        if setting.kind == "bool" {
            Toggle(isOn: Binding(get: { model.setting(setting.id).lowercased() == "true" }, set: { model.edit(setting.id, $0 ? "True" : "False") })) { title }
        } else if !choices.isEmpty {
            let current = model.setting(setting.id)
            Picker(selection: model.binding(setting.id)) {
                ForEach(choices.contains(current) ? choices : [current] + choices, id: \.self) { Text($0.isEmpty ? "Default" : $0).tag($0) }
            } label: { title }
        } else if setting.id == "autoortho.dynamic_zoom_steps", let steps = ZoomSteps.parse(model.setting(setting.id)) {
            VStack(alignment: .leading, spacing: 8) {
                title
                ZoomStepsEditor(id: setting.id, steps: steps)
            }
        } else if setting.kind == "integer" {
            LabeledContent { IntegerField(id: setting.id, limits: SettingsCatalog.limits(setting.id)) } label: { title }
        } else if setting.kind == "number" {
            LabeledContent {
                TextField("", value: Binding(get: { Double(model.setting(setting.id)) ?? 0 }, set: { model.edit(setting.id, String($0)) }),
                          format: .number.precision(.fractionLength(1...6)).grouping(.never))
                    .labelsHidden().multilineTextAlignment(.trailing).frame(width: 90)
            } label: { title }
        } else if SettingsCatalog.isFolder(setting) {
            LabeledContent {
                TextField("", text: model.binding(setting.id)).labelsHidden().textFieldStyle(.roundedBorder)
                Button("Choose…") { model.chooseDirectory(setting.id) }
            } label: { title }
        } else {
            LabeledContent {
                TextField("", text: model.binding(setting.id), axis: setting.value.count > 70 ? .vertical : .horizontal)
                    .labelsHidden().textFieldStyle(.roundedBorder).lineLimit(1...5)
            } label: { title }
        }
    }
}

/// A number field with a stepper, clamped to the range the engine accepts.
struct IntegerField: View {
    @EnvironmentObject var model: AppModel
    let id: String
    let limits: ClosedRange<Int>?
    var value: Binding<Int> {
        Binding(get: { Int(model.setting(id)) ?? limits?.lowerBound ?? 0 },
                set: { newValue in model.edit(id, String(limits.map { min(max(newValue, $0.lowerBound), $0.upperBound) } ?? newValue)) })
    }
    var body: some View {
        HStack(spacing: 4) {
            TextField("", value: value, format: .number.grouping(.never))
                .labelsHidden().multilineTextAlignment(.trailing).frame(width: 80)
            if let limits {
                Stepper("", value: value, in: limits).labelsHidden()
            } else {
                Stepper("", value: value, step: 1).labelsHidden()
            }
        }
        .help(limits.map { "\($0.lowerBound)–\($0.upperBound)" } ?? "")
    }
}

/// One altitude band of dynamic zoom: the maximum zoom at or above `altitude` feet AGL.
struct ZoomStep: Equatable {
    var altitude: Int
    var zoom: Int
    var airports: Int
}

/// Reads and writes `autoortho.dynamic_zoom_steps`, a Python literal list of dicts (see utils/dynamic_zoom.py).
enum ZoomSteps {
    static let zoomRange = 12...19
    static let altitudeRange = 1000...60000

    static func parse(_ text: String) -> [ZoomStep]? {
        guard let data = text.replacingOccurrences(of: "'", with: "\"").data(using: .utf8),
              let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        var steps: [ZoomStep] = []
        for item in list {
            guard let altitude = (item["altitude_ft"] as? NSNumber)?.intValue,
                  let zoom = (item["zoom_level"] as? NSNumber)?.intValue else { return nil }
            steps.append(ZoomStep(altitude: altitude, zoom: zoom, airports: (item["zoom_level_airports"] as? NSNumber)?.intValue ?? 18))
        }
        return steps.sorted { $0.altitude < $1.altitude }
    }

    /// Same text Python's str() produces, which the engine parses with ast.literal_eval.
    static func serialize(_ steps: [ZoomStep]) -> String {
        "[" + steps.sorted { $0.altitude < $1.altitude }.map {
            "{'altitude_ft': \($0.altitude), 'zoom_level': \($0.zoom), 'zoom_level_airports': \($0.airports)}"
        }.joined(separator: ", ") + "]"
    }

    /// A new step 5,000 ft above the highest, one zoom level lower, as the Qt editor does.
    static func next(after steps: [ZoomStep]) -> ZoomStep {
        let highest = steps.max { $0.altitude < $1.altitude } ?? ZoomStep(altitude: 0, zoom: 16, airports: 18)
        var altitude = min(altitudeRange.upperBound, max(altitudeRange.lowerBound, highest.altitude + 5000))
        while steps.contains(where: { $0.altitude == altitude }) && altitude < altitudeRange.upperBound { altitude += 1000 }
        return ZoomStep(altitude: altitude, zoom: max(zoomRange.lowerBound, highest.zoom - 1),
                        airports: max(zoomRange.lowerBound, highest.airports - 1))
    }
}

struct ZoomStepsEditor: View {
    @EnvironmentObject var model: AppModel
    let id: String
    let steps: [ZoomStep]
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow {
                    Text("At or above (ft AGL)"); Text("Max zoom"); Text("Near airports"); Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                }.font(.caption).foregroundStyle(.secondary)
                ForEach(steps.indices, id: \.self) { index in
                    GridRow {
                        if steps[index].altitude == 0 {
                            Text("Ground").foregroundStyle(.secondary)
                        } else {
                            HStack(spacing: 4) {
                                TextField("", value: binding(index, \.altitude, ZoomSteps.altitudeRange), format: .number)
                                    .labelsHidden().multilineTextAlignment(.trailing).frame(width: 80)
                                Stepper("", value: binding(index, \.altitude, ZoomSteps.altitudeRange), in: ZoomSteps.altitudeRange, step: 1000).labelsHidden()
                            }
                        }
                        Stepper("ZL \(steps[index].zoom)", value: binding(index, \.zoom, ZoomSteps.zoomRange), in: ZoomSteps.zoomRange)
                        Stepper("ZL \(steps[index].airports)", value: binding(index, \.airports, ZoomSteps.zoomRange), in: ZoomSteps.zoomRange)
                        Button { write(steps.enumerated().filter { $0.offset != index }.map(\.element)) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless).disabled(steps[index].altitude == 0)
                            .help(steps[index].altitude == 0 ? "The ground step can’t be removed" : "Remove this step")
                            .accessibilityLabel("Remove step")
                    }
                }
            }
            HStack {
                Button("Add Step") { write(steps + [ZoomSteps.next(after: steps)]) }
                if !steps.contains(where: { $0.altitude == 0 }) {
                    Button("Add Ground Step") { write(steps + [ZoomStep(altitude: 0, zoom: 16, airports: 18)]) }
                }
                if Set(steps.map(\.altitude)).count != steps.count {
                    Label("Two steps share an altitude.", systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.caption)
                }
            }
            if model.setting("autoortho.max_zoom_mode") != "dynamic" {
                Text("These steps apply when Zoom mode is dynamic.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    func binding(_ index: Int, _ field: WritableKeyPath<ZoomStep, Int>, _ range: ClosedRange<Int>) -> Binding<Int> {
        Binding(get: { steps[index][keyPath: field] }, set: { value in
            var updated = steps
            updated[index][keyPath: field] = min(max(value, range.lowerBound), range.upperBound)
            write(updated)
        })
    }
    func write(_ updated: [ZoomStep]) { model.edit(id, ZoomSteps.serialize(updated)) }
}
