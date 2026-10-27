import SwiftUI
import AppKit
import MapKit

// Select Apple’s supported State property wrapper on CLT-only installations.
// The macOS 27 State macro plugin ships with full Xcode, which is optional here.
typealias NativeState<Value> = SwiftUI.State<Value>

struct RootView: View {
    @EnvironmentObject var model: AppModel
    @NativeState<Bool> private var confirmStop = false
    var body: some View {
        NavigationSplitView {
            List(Destination.allCases, selection: $model.destination) { destination in
                Label(destination.rawValue, systemImage: destination.symbol).tag(destination)
            }
            .navigationSplitViewColumnWidth(min: 175, ideal: 210, max: 260)
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 8) {
                    Image(systemName: model.running ? "antenna.radiowaves.left.and.right" : "airplane")
                        .foregroundStyle(model.running ? .green : .secondary)
                    Text(model.running ? "Streaming" : "Not streaming").font(.callout)
                    Spacer()
                }.padding().accessibilityElement(children: .combine)
            }
        } detail: {
            Group {
                switch model.destination ?? .overview {
                case .overview: OverviewView()
                case .scenery: SceneryView()
                case .flight: FlightView()
                case .activity: ActivityView()
                case .diagnostics: DiagnosticsView()
                }
            }
            .navigationTitle((model.destination ?? .overview).rawValue)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        if model.running { confirmStop = true }
                        else { Task { await model.streaming(true) } }
                    } label: {
                        Label(model.running ? "Stop Streaming" : "Start Streaming", systemImage: model.running ? "stop.fill" : "play.fill")
                    }
                    .disabled(model.busy || model.snapshot == nil || (model.running && model.snapshot?.owned != true) ||
                              (!model.running && (model.snapshot?.ready != true || model.hasRunningTask)))
                    .help(model.running ? "Unmount scenery and stop streaming" : "Mount installed scenery for X-Plane")
                }
            }
        }
        .frame(minWidth: 850, minHeight: 600)
        .task { model.begin() }
        .alert("Stop streaming?", isPresented: $confirmStop) {
            Button("Keep Streaming", role: .cancel) { }
            Button("Stop Streaming", role: .destructive) { Task { await model.streaming(false) } }
        } message: { Text("Close your X-Plane flight first. Stopping unmounts the scenery it uses.") }
        .alert("AutoOrtho", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK", role: .cancel) { model.error = nil }
        } message: { Text(model.error ?? "") }
        .sheet(isPresented: Binding(get: { !model.reportName.isEmpty }, set: { if !$0 { model.reportName = "" } })) {
            VStack(alignment: .leading, spacing: 0) {
                HStack { Text(model.reportName).font(.headline); Spacer(); Button("Done") { model.reportName = "" }.keyboardShortcut(.defaultAction) }.padding()
                Divider()
                ScrollView { Text(model.reportText).font(.system(.body, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding() }
            }.frame(minWidth: 750, minHeight: 500)
        }
        .overlay {
            if model.snapshot == nil { ProgressView("Connecting to AutoOrtho…").padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)) }
        }
    }
}

struct OverviewView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        Form {
            Section {
                HStack(alignment: .center, spacing: 18) {
                    Image(systemName: model.running ? "airplane.circle.fill" : "globe.europe.africa.fill")
                        .font(.system(size: 42)).foregroundStyle(.tint).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(model.statusTitle).font(.title2.weight(.semibold))
                        Text(model.running ? "Satellite scenery is available to X-Plane." : "Start streaming before opening your X-Plane flight.")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if model.busy { ProgressView().controlSize(.small) }
                }.padding(.vertical, 8)
                if model.snapshot?.status == "streaming" && model.snapshot?.owned == false {
                    Label("Streaming is managed by another AutoOrtho instance.", systemImage: "info.circle")
                }
            }
            Section("Setup") {
                ForEach(model.snapshot?.checks ?? []) { check in
                    LabeledContent {
                        Image(systemName: check.ok ? "checkmark.circle.fill" : "exclamationmark.circle")
                            .foregroundStyle(check.ok ? .green : .orange)
                            .accessibilityLabel(check.ok ? "Ready" : "Needs attention")
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(check.title)
                            Text(check.detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }
                }
                SettingsLink { Label("Open Settings…", systemImage: "gearshape") }
            }
            Section("Scenery") {
                LabeledContent("Installed regions", value: "\(model.snapshot?.regions.count ?? 0)")
                ForEach(model.snapshot?.mounts ?? []) { mount in
                    LabeledContent(mount.name, value: mount.mounted ? "Mounted" : "Not mounted")
                }
                Button("Manage Scenery…") { model.destination = .scenery }
            }
            Section("Storage") {
                LabeledContent("Available disk space", value: byteLabel(model.snapshot?.freeBytes ?? 0))
                LabeledContent("Disk cache limit", value: "\(model.setting("cache.file_cache_size")) GB")
                LabeledContent("Memory cache limit", value: "\(model.setting("cache.cache_mem_limit")) GB")
            }
        }.formStyle(.grouped)
    }
}

struct SceneryView: View {
    @EnvironmentObject var model: AppModel
    @NativeState<Region?> private var selected = nil
    @NativeState<String> private var action = ""
    var body: some View {
        VStack(spacing: 0) {
            if model.regions.isEmpty {
                ContentUnavailableView {
                    Label("Add scenery", systemImage: "map")
                } description: { Text("Browse the catalog to choose the regions you fly in.") }
                actions: { Button("Browse Catalog") { Task { await model.catalog() } }.disabled(model.loadingCatalog) }
            } else {
                Table(model.regions) {
                    TableColumn("Region") { region in
                        Label(region.name, systemImage: "map").padding(.vertical, 6)
                    }.width(min: 180, ideal: 260)
                    TableColumn("Version", value: \.version).width(100)
                    TableColumn("Status") { region in Text(region.installed ? "Installed" : "Available").foregroundStyle(region.installed ? .primary : .secondary) }.width(85)
                    TableColumn("") { region in
                        Menu {
                            if !region.installed {
                                Button("Install…") { selected = region; action = "install" }
                            } else {
                                Button("Apply Seasons…") { selected = region; action = "seasons" }
                                Button("Restore Original Terrain…") { selected = region; action = "restore" }
                                Button("Reduce Terrain Reflections…") { selected = region; action = "roughness" }
                                Button("Restore Terrain Reflections…") { selected = region; action = "restore_roughness" }
                                Divider()
                                Button("Remove…", role: .destructive) { selected = region; action = "uninstall" }
                            }
                        } label: { Image(systemName: "ellipsis.circle") }
                        .menuStyle(.borderlessButton).fixedSize()
                        .accessibilityLabel("Options for \(region.name)")
                        .disabled(model.running || model.hasRunningTask)
                    }.width(40)
                }
            }
            Divider()
            HStack {
                if model.loadingCatalog { ProgressView().controlSize(.small); Text("Loading catalog…") }
                else { Text("\(model.snapshot?.regions.count ?? 0) installed regions").foregroundStyle(.secondary) }
                Spacer()
                Button("Show in Finder") { model.reveal(model.setting("paths.scenery_path")) }
            }.font(.callout).padding(12)
        }
        .searchable(text: $model.search, prompt: "Find a region")
        .toolbar { Button { Task { await model.catalog() } } label: { Label("Refresh Catalog", systemImage: "arrow.clockwise") }.disabled(model.loadingCatalog) }
        .confirmationDialog("\(action.capitalized) \(selected?.name ?? "scenery")?", isPresented: Binding(get: { selected != nil }, set: { if !$0 { selected = nil } }), titleVisibility: .visible) {
            if let region = selected {
                Button(action.capitalized, role: action == "uninstall" ? .destructive : nil) { Task { await model.scenery(region, action: action) }; selected = nil }
            }
            Button("Cancel", role: .cancel) { selected = nil }
        } message: {
            Text(action == "roughness" ? "This applies your terrain roughness setting to the region’s terrain files." :
                 action == "restore_roughness" ? "This removes the terrain roughness adjustment from the region." :
                 action == "restore" ? "This restores the original scenery terrain. Your local terrain patches may be replaced." :
                 action == "uninstall" ? "The downloaded scenery files for this region will be removed." :
                 action == "install" ? "Scenery packages can require substantial disk space. Progress appears in Activity." : "This modifies the region’s terrain files to support seasonal imagery.")
        }
    }
}

struct ActivityView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        if model.snapshot?.tasks.isEmpty != false {
            ContentUnavailableView("No active tasks", systemImage: "checkmark.circle", description: Text("Scenery downloads and terrain operations appear here."))
        } else {
            List(model.snapshot?.tasks ?? []) { task in
                VStack(alignment: .leading, spacing: 8) {
                    Label(task.title, systemImage: task.state == "complete" ? "checkmark.circle" : task.state == "failed" ? "exclamationmark.triangle" : "arrow.down.circle")
                        .font(.headline)
                    if task.state == "running" {
                        if let value = task.progress { ProgressView(value: value) }
                        else { ProgressView().controlSize(.small) }
                    }
                    Text(task.message).foregroundStyle(.secondary).textSelection(.enabled)
                }.padding(.vertical, 10)
            }
        }
    }
}

struct FlightView: View {
    @EnvironmentObject var model: AppModel
    @NativeState<MapCameraPosition> private var position = .automatic
    @NativeState<Bool> private var showImagery = false
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                TextField("SimBrief pilot ID or username", text: $model.pilotID).textFieldStyle(.roundedBorder).frame(maxWidth: 260)
                    .onSubmit { Task { await model.loadFlight() } }
                Button("Load Flight Plan") { Task { await model.loadFlight() } }.disabled(model.loadingFlight || model.pilotID.isEmpty)
                if model.loadingFlight { ProgressView().controlSize(.small) }
                Spacer()
                Text(model.routeTitle).foregroundStyle(.secondary)
            }.padding()
            Divider()
            Map(position: $position) {
                if model.route.count > 1 { MapPolyline(coordinates: model.route.map(\.coordinate)).stroke(.blue, lineWidth: 3) }
                ForEach(model.route.filter { $0.id == model.route.first?.id || $0.id == model.route.last?.id }) { point in
                    Marker(point.name, systemImage: "airplane", coordinate: point.coordinate)
                }
                if let aircraft = model.aircraft {
                    Annotation("Aircraft", coordinate: aircraft) {
                        Image(systemName: "airplane.circle.fill").font(.title).foregroundStyle(.white, .blue)
                            .accessibilityLabel("Current aircraft position")
                    }
                }
            }.mapControls { MapCompass(); MapScaleView(); MapZoomStepper() }
                .onChange(of: model.route.count) { position = .automatic }
                .overlay(alignment: .bottomLeading) {
                    Text(model.running ? "Aircraft position comes from X-Plane." : "Start streaming to follow your aircraft.")
                        .font(.callout).padding(10).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8)).padding()
                }
            if !model.route.isEmpty {
                Divider()
                HStack { Text("\(model.route.count) route points"); Spacer(); Text("Flight plan available for route-aware streaming") }.font(.callout).foregroundStyle(.secondary).padding(12)
            }
        }
        .inspector(isPresented: $showImagery) { ImageryInspector().environmentObject(model) }
        .toolbar {
            Button { showImagery.toggle() } label: { Label("Imagery Overrides", systemImage: "map.badge.plus") }
        }
    }
}

struct ImageryInspector: View {
    @EnvironmentObject var model: AppModel
    @NativeState<String> private var latitude = "35"
    @NativeState<String> private var longitude = "139"
    @NativeState<String> private var provider = "BI"
    var body: some View {
        Form {
            Section("Imagery Overrides") {
                Text("Assign an imagery source to a one-degree tile. Existing overrides are kept.").font(.callout).foregroundStyle(.secondary)
                TextField("South latitude", text: $latitude)
                TextField("West longitude", text: $longitude)
                Picker("Provider", selection: $provider) {
                    ForEach(["BI", "NAIP", "EOX", "USGS", "Firefly", "GO2", "ARC", "YNDX", "APPLE"], id: \.self) { Text($0).tag($0) }
                }
                Button("Assign Provider") {
                    guard let lat = Int(latitude), let lon = Int(longitude) else { model.error = "Enter integer latitude and longitude values."; return }
                    Task { await model.assignImagery(latitude: lat, longitude: lon, provider: provider) }
                }
                Text("Select Custom Map as the imagery source in Streaming settings to use these overrides.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Assigned Tiles") {
                if model.imagery.isEmpty { Text("No overrides").foregroundStyle(.secondary) }
                ForEach(model.imagery.keys.sorted(), id: \.self) { key in
                    HStack {
                        Text(key).monospacedDigit(); Spacer(); Text(model.imagery[key] ?? "")
                        Button {
                            let coordinates = key.split(separator: ",").compactMap { Int($0) }
                            if coordinates.count == 2 { Task { await model.assignImagery(latitude: coordinates[0], longitude: coordinates[1], provider: nil) } }
                        } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless).help("Remove override for \(key)")
                    }
                }
            }
        }.formStyle(.grouped).inspectorColumnWidth(min: 280, ideal: 320, max: 400)
            .task { await model.loadImagery() }
    }
}

struct DiagnosticsView: View {
    @EnvironmentObject var model: AppModel
    @NativeState<String> private var tab = "Log"
    var body: some View {
        VStack(spacing: 0) {
            Picker("Diagnostics", selection: $tab) { Text("Log").tag("Log"); Text("Performance Reports").tag("Reports") }.pickerStyle(.segmented).padding()
            Divider()
            if tab == "Log" {
                ScrollView {
                    Text(model.logs.isEmpty ? "No log entries." : filteredLogs)
                        .font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding()
                }.background(.background)
            } else if model.snapshot?.reports.isEmpty != false {
                ContentUnavailableView("No performance reports", systemImage: "chart.xyaxis.line", description: Text("Recorded flight reports appear after a streaming session ends."))
            } else {
                List(model.snapshot?.reports ?? []) { report in
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(report.name)
                            Text(Date(timeIntervalSince1970: report.modified), style: .date).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Open") { model.showReport(report) }
                        Button { model.reveal(report.path) } label: { Image(systemName: "folder") }.help("Show report in Finder")
                    }.padding(.vertical, 6)
                }
            }
        }
        .searchable(text: $model.search, prompt: "Filter log")
        .toolbar {
            Button { model.exportLogs() } label: { Label("Export Log…", systemImage: "square.and.arrow.up") }
            Button { Task { await model.readLogs() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
        }
        .task { await model.readLogs() }
    }
    var filteredLogs: String { model.search.isEmpty ? model.logs : model.logs.components(separatedBy: .newlines).filter { $0.localizedCaseInsensitiveContains(model.search) }.joined(separator: "\n") }
}

struct NativeSettingsView: View {
    @EnvironmentObject var model: AppModel
    @NativeState<String> private var category = "general"
    @NativeState<String> private var filter = ""
    var sections: [String] {
        Array(Set((model.snapshot?.settings ?? []).map(\.section))).filter { $0 != "windows" }.sorted()
    }
    var body: some View {
        VStack(spacing: 0) {
            NavigationSplitView {
                List(sections, id: \.self, selection: $category) { section in Text(title(section)).tag(section) }
                    .navigationSplitViewColumnWidth(180)
            } detail: {
                Form {
                    Section(title(category)) {
                        ForEach(model.snapshot?.settings.filter { $0.section == category && (filter.isEmpty || $0.title.localizedCaseInsensitiveContains(filter) || $0.help.localizedCaseInsensitiveContains(filter)) } ?? []) { setting in
                            SettingRow(setting: setting)
                        }
                    }
                }.formStyle(.grouped).disabled(model.running || model.busy)
            }
            Divider()
            HStack {
                Text(model.running ? "Stop streaming to change settings." : model.edits.isEmpty ? "Settings are up to date." : "You have unapplied changes.")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Revert") { model.revert() }.disabled(model.edits.isEmpty || model.busy)
                Button("Apply") { Task { await model.save() } }.keyboardShortcut("s", modifiers: .command)
                    .disabled(model.edits.isEmpty || model.running || model.busy)
            }.padding()
        }
        .frame(minWidth: 850, minHeight: 620)
        .searchable(text: $filter, prompt: "Find in this category")
        .navigationTitle("AutoOrtho Settings")
        .alert("Settings could not be saved", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
    }
    func title(_ value: String) -> String {
        switch value { case "autoortho": return "Streaming"; case "pydds": return "Textures"; case "flightdata": return "X-Plane Connection"; case "fuse": return "Filesystem"; default: return value.replacingOccurrences(of: "_", with: " ").capitalized }
    }
}

struct SettingRow: View {
    @EnvironmentObject var model: AppModel
    let setting: Setting
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if setting.kind == "bool" {
                Toggle(setting.title, isOn: Binding(get: { model.setting(setting.id).lowercased() == "true" }, set: { model.edit(setting.id, $0 ? "True" : "False") }))
            } else if !choices.isEmpty {
                Picker(setting.title, selection: model.binding(setting.id)) {
                    ForEach(choices, id: \.self) { Text($0).tag($0) }
                }
            } else if let limits = limits {
                Stepper(value: Binding(get: { Int(model.setting(setting.id)) ?? limits.lowerBound }, set: { model.edit(setting.id, String($0)) }), in: limits) {
                    LabeledContent(setting.title, value: model.setting(setting.id))
                }
            } else if (setting.section == "paths" && setting.key != "log_file") || setting.key == "report_dir" {
                LabeledContent(setting.title) {
                    TextField(setting.title, text: model.binding(setting.id)).labelsHidden().textFieldStyle(.roundedBorder)
                    Button("Choose…") { model.chooseDirectory(setting.id) }
                }
            } else {
                TextField(setting.title, text: model.binding(setting.id), axis: setting.value.count > 70 ? .vertical : .horizontal)
                    .textFieldStyle(.roundedBorder).lineLimit(1...5)
            }
            if !setting.help.isEmpty { Text(setting.help).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        }.padding(.vertical, 3)
    }
    var choices: [String] {
        switch setting.id {
        case "autoortho.maptype_override": return ["Use tile default", "BI", "NAIP", "EOX", "USGS", "Firefly", "GO2", "ARC", "YNDX", "APPLE", "Custom Map"]
        case "autoortho.max_zoom_mode": return ["fixed", "dynamic"]
        case "pydds.compressor": return ["ISPC", "STB"]
        case "pydds.format": return ["BC1", "BC3"]
        case "pydds.dds_compression": return ["none", "zstd"]
        case "general.console_log_level", "general.file_log_level": return ["DEBUG", "INFO", "WARNING", "ERROR", "CRITICAL"]
        default: return []
        }
    }
    var limits: ClosedRange<Int>? {
        switch setting.id {
        case "autoortho.min_zoom": return 1...20
        case "autoortho.max_zoom", "autoortho.max_zoom_near_airports": return 12...20
        case "pydds.water_alpha": return 0...255
        case "pydds.dds_compression_level": return 1...19
        default: return nil
        }
    }
}
