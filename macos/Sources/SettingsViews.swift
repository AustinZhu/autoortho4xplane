import SwiftUI
import AppKit

struct NativeSettingsView: View {
    @EnvironmentObject var model: AppModel
    @NativeState<String?> private var page: String?
    @NativeState<String> private var filter: String
    init(page: String = "general", filter: String = "") {
        _page = NativeState(initialValue: page)
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
                Label(page.title, systemImage: page.symbol).tag(page.id)
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
        let scoped = filter.isEmpty ? pages.filter { $0.id == (page ?? "general") } : pages
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
            if !setting.help.isEmpty { Text(setting.help).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
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
