import SwiftUI
import AppKit
import MapKit

// Select Apple’s supported State property wrapper on CLT-only installations.
// The macOS 27 State macro plugin ships with full Xcode, which is optional here.
typealias NativeState<Value> = SwiftUI.State<Value>

struct RootView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        NavigationSplitView {
            List(Destination.allCases, selection: $model.destination) { destination in
                Label(destination.rawValue, systemImage: destination.symbol).tag(destination)
                    .badge(destination == .activity ? model.runningTaskCount : 0)
            }
            .navigationSplitViewColumnWidth(min: 175, ideal: 210, max: 260)
            .safeAreaInset(edge: .bottom) { StatusFooter() }
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
                ToolbarItem(placement: .primaryAction) { StreamingToolbarButton() }
            }
        }
        .frame(minWidth: 850, minHeight: 600)
        .task { model.begin() }
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

struct StatusFooter: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: model.running ? "antenna.radiowaves.left.and.right" : "airplane")
                .foregroundStyle(model.running ? .green : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(model.running ? "Streaming" : "Not streaming").font(.callout)
                Text(model.mountSummary).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }.padding().accessibilityElement(children: .combine)
    }
}

struct StreamingToolbarButton: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        Button { model.toggleStreaming() } label: {
            if let transition = model.transition {
                Label(transition, systemImage: "hourglass")
            } else {
                Label(model.running ? "Stop Streaming" : "Start Streaming", systemImage: model.running ? "stop.fill" : "play.fill")
            }
        }
        .disabled(model.running ? !model.canStop : !model.canStart)
        .help(help)
    }
    var help: String {
        if model.running { return model.ownsStreaming ? "Unmount scenery and stop streaming (⌘↩)" : "Streaming is managed by another AutoOrtho instance." }
        return model.startBlocker?.message ?? "Mount installed scenery for X-Plane (⌘↩)"
    }
}

// MARK: - Overview

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
                        Text(model.statusDetail).foregroundStyle(.secondary)
                    }
                    Spacer()
                }.padding(.top, 8)
                StreamingControls().padding(.bottom, 8)
            }
            Section("Setup") {
                ForEach(model.snapshot?.checks ?? []) { check in
                    LabeledContent {
                        HStack(spacing: 10) {
                            if !check.ok { fixButton(for: check) }
                            Image(systemName: check.ok ? "checkmark.circle.fill" : "exclamationmark.circle")
                                .foregroundStyle(check.ok ? .green : .orange)
                                .accessibilityLabel(check.ok ? "Ready" : "Needs attention")
                        }
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
                    LabeledContent(model.regionName(forMount: mount.name), value: mount.mounted ? "Mounted" : "Not mounted")
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
    @ViewBuilder func fixButton(for check: ReadinessCheck) -> some View {
        switch check.id {
        case "xplane": Button("Choose…") { model.chooseDirectory("paths.xplane_path", applyNow: true) }.disabled(model.running)
        case "scenery": Button("Add Scenery…") { model.destination = .scenery }
        default: EmptyView()
        }
    }
}

/// The primary Start/Stop control, with the reason it is unavailable and the action that resolves it.
struct StreamingControls: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                primary
                if model.transition != nil || model.snapshot?.status == "starting" { ProgressView().controlSize(.small) }
                if model.snapshot?.status == "failed" {
                    Button("View Log") { model.destination = .diagnostics }.controlSize(.large)
                }
            }
            if !model.running, model.transition == nil, model.snapshot != nil, let blocker = model.startBlocker {
                HStack(spacing: 8) {
                    Label(blocker.message, systemImage: "exclamationmark.circle").foregroundStyle(.secondary)
                    fix(blocker.fix)
                }.font(.callout)
            }
        }
    }
    @ViewBuilder var primary: some View {
        if model.running {
            Button { model.requestStop() } label: { Label(model.transition ?? "Stop Streaming…", systemImage: "stop.fill") }
                .controlSize(.large).disabled(!model.canStop)
        } else if model.startBlocker?.fix == .applySettings {
            Button { Task { await model.applyAndStart() } } label: { Label("Apply Settings and Start", systemImage: "play.fill") }
                .buttonStyle(.borderedProminent).controlSize(.large).disabled(model.busy)
        } else {
            Button { Task { await model.streaming(true) } } label: { Label(model.transition ?? "Start Streaming", systemImage: "play.fill") }
                .buttonStyle(.borderedProminent).controlSize(.large).disabled(!model.canStart)
        }
    }
    @ViewBuilder func fix(_ fix: StartBlocker.Fix) -> some View {
        switch fix {
        case .applySettings: SettingsLink { Text("Review Settings…") }.buttonStyle(.link)
        case .chooseXPlane: Button("Choose X-Plane Folder…") { model.chooseDirectory("paths.xplane_path", applyNow: true) }.buttonStyle(.link)
        case .manageScenery: Button("Add Scenery…") { model.destination = .scenery }.buttonStyle(.link)
        case .waitForTasks: Button("Show Activity") { model.destination = .activity }.buttonStyle(.link)
        case .none: EmptyView()
        }
    }
}

// MARK: - Scenery

struct PendingSceneryAction: Identifiable {
    let region: Region
    let action: SceneryAction
    var id: String { region.id + action.rawValue }
}

struct SceneryView: View {
    enum Filter: String, CaseIterable { case all = "All", installed = "Installed", available = "Available" }
    @EnvironmentObject var model: AppModel
    @NativeState<PendingSceneryAction?> private var pending = nil
    @NativeState<Filter> private var filter = .all
    var shown: [Region] {
        model.regions.filter { filter == .all || (filter == .installed) == $0.installed }
    }
    var locked: Bool { model.running || model.hasRunningTask }
    var body: some View {
        VStack(spacing: 0) {
            if model.running { banner }
            if model.regions.isEmpty && model.sceneryQuery.isEmpty {
                ContentUnavailableView {
                    Label(model.loadingCatalog ? "Loading regions…" : "Add scenery", systemImage: "map")
                } description: { Text("Choose the regions you fly in. Each region is downloaded once and streamed to X-Plane.") }
                actions: { Button("Browse Regions") { Task { await model.catalog() } }.disabled(model.loadingCatalog) }
            } else if shown.isEmpty {
                ContentUnavailableView.search(text: model.sceneryQuery)
            } else {
                table
            }
            Divider()
            HStack(spacing: 6) {
                if model.loadingCatalog { ProgressView().controlSize(.small); Text("Loading regions…") }
                else { Text(summary).foregroundStyle(.secondary) }
                Spacer()
                Button("Show in Finder") { model.reveal(model.setting("paths.scenery_path")) }
            }.font(.callout).padding(12)
        }
        .searchable(text: $model.sceneryQuery, prompt: "Find a region")
        .toolbar {
            ToolbarItem {
                Picker("Show", selection: $filter) { ForEach(Filter.allCases, id: \.self) { Text($0.rawValue) } }
                    .pickerStyle(.segmented).help("Show all, installed or available regions")
            }
            ToolbarItem {
                Button { Task { await model.catalog() } } label: { Label("Refresh Regions", systemImage: "arrow.clockwise") }
                    .disabled(model.loadingCatalog).help("Check for new and updated regions")
            }
        }
        .task { await model.loadCatalogIfNeeded() }
        .confirmationDialog(pending.map { "\($0.action.title) \($0.region.name)?" } ?? "",
                            isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }), titleVisibility: .visible,
                            presenting: pending) { item in
            Button(item.action.title, role: item.action == .uninstall ? .destructive : nil) { Task { await model.scenery(item.region, action: item.action) } }
            Button("Cancel", role: .cancel) { }
        } message: { item in Text(message(for: item)) }
    }
    var banner: some View {
        HStack {
            Label("Stop streaming to install or change scenery.", systemImage: "lock").foregroundStyle(.secondary)
            Spacer()
            Button("Stop Streaming…") { model.requestStop() }.disabled(!model.canStop)
        }.font(.callout).padding(.horizontal, 12).padding(.vertical, 8).background(.bar)
    }
    var table: some View {
        Table(shown) {
            TableColumn("Region") { region in Text(region.name).padding(.vertical, 4) }.width(min: 180, ideal: 260)
            TableColumn("Version", value: \.version).width(min: 70, ideal: 90)
            TableColumn("Size") { region in Text(region.bytes > 0 ? byteLabel(region.bytes) : "—").monospacedDigit().foregroundStyle(.secondary) }
                .width(min: 70, ideal: 80)
            TableColumn("Status") { region in status(region) }.width(min: 110, ideal: 170)
            TableColumn("") { region in actions(region) }.width(90)
        }
    }
    @ViewBuilder func status(_ region: Region) -> some View {
        if let task = model.task(for: region) {
            VStack(alignment: .leading, spacing: 2) {
                if let value = task.progress { ProgressView(value: value).controlSize(.small) } else { ProgressView().controlSize(.small) }
                Text(task.message).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        } else {
            Text(region.installed ? "Installed" : "Available").foregroundStyle(region.installed ? .primary : .secondary)
        }
    }
    @ViewBuilder func actions(_ region: Region) -> some View {
        if region.installed {
            Menu {
                Button("Apply Seasons…") { request(region, .seasons) }
                Button("Restore Original Terrain…") { request(region, .restore) }
                Button("Reduce Terrain Reflections…") { request(region, .roughness) }
                Button("Restore Terrain Reflections…") { request(region, .restore_roughness) }
                Divider()
                Button("Remove…", role: .destructive) { request(region, .uninstall) }
            } label: { Image(systemName: "ellipsis.circle") }
            .menuStyle(.borderlessButton).fixedSize()
            .accessibilityLabel("Options for \(region.name)")
            .disabled(locked).help(lockReason ?? "Region options")
        } else {
            Button("Install") { request(region, .install) }
                .controlSize(.small).disabled(locked).help(lockReason ?? "Download and install \(region.name)")
        }
    }
    var lockReason: String? {
        model.running ? "Stop streaming to change scenery." : model.hasRunningTask ? "Wait for the current scenery operation to finish." : nil
    }
    var summary: String {
        let installed = model.snapshot?.regions.count ?? 0
        let available = (model.snapshot?.catalog ?? []).filter { !$0.installed }.count
        let free = byteLabel(model.snapshot?.freeBytes ?? 0)
        return available > 0 ? "\(installed) installed · \(available) available · \(free) free" : "\(installed) installed · \(free) free"
    }
    func request(_ region: Region, _ action: SceneryAction) {
        if action == .install, region.bytes > 0, region.bytes > (model.snapshot?.freeBytes ?? .max) {
            model.error = "\(region.name) needs about \(byteLabel(region.bytes)), but only \(byteLabel(model.snapshot?.freeBytes ?? 0)) is available."
            return
        }
        pending = .init(region: region, action: action)
    }
    func message(for item: PendingSceneryAction) -> String {
        guard item.action == .install else { return item.action.message }
        let size = item.region.bytes > 0 ? " Download size: \(byteLabel(item.region.bytes))." : ""
        return "\(item.action.message)\(size) Available: \(byteLabel(model.snapshot?.freeBytes ?? 0)). Progress appears in this list and in Activity."
    }
}

// MARK: - Activity

struct ActivityView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        if model.tasks.isEmpty {
            ContentUnavailableView("No scenery operations", systemImage: "checkmark.circle", description: Text("Scenery downloads and terrain operations appear here."))
        } else {
            List(model.tasks.reversed()) { task in
                VStack(alignment: .leading, spacing: 8) {
                    Label {
                        Text(model.taskTitle(task))
                    } icon: {
                        Image(systemName: icon(task)).foregroundStyle(task.state == "failed" ? .red : task.state == "complete" ? .green : .accentColor)
                    }.font(.headline)
                    if task.state == "running" {
                        if let value = task.progress { ProgressView(value: value) } else { ProgressView().controlSize(.small) }
                    }
                    HStack {
                        Text(task.message).foregroundStyle(.secondary).textSelection(.enabled)
                        if task.state == "failed" { Spacer(); Button("View Log") { model.destination = .diagnostics } }
                    }
                }.padding(.vertical, 10)
            }
        }
    }
    func icon(_ task: EngineTask) -> String {
        switch task.state {
        case "complete": return "checkmark.circle.fill"
        case "failed": return "exclamationmark.triangle.fill"
        default: return "arrow.down.circle"
        }
    }
}

// MARK: - Flight

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
                .help("Assign imagery sources to individual tiles")
        }
    }
}

struct ImageryInspector: View {
    @EnvironmentObject var model: AppModel
    @NativeState<String> private var latitude = ""
    @NativeState<String> private var longitude = ""
    @NativeState<String> private var provider = "BI"
    var body: some View {
        Form {
            Section("Imagery Overrides") {
                Text("Assign an imagery source to a one-degree tile. Existing overrides are kept.").font(.callout).foregroundStyle(.secondary)
                TextField("South latitude", text: $latitude, prompt: Text("e.g. 35"))
                TextField("West longitude", text: $longitude, prompt: Text("e.g. 139"))
                Picker("Provider", selection: $provider) {
                    ForEach(["BI", "NAIP", "EOX", "USGS", "Firefly", "GO2", "ARC", "YNDX", "APPLE"], id: \.self) { Text($0).tag($0) }
                }
                Button("Assign Provider") {
                    guard let lat = Int(latitude), let lon = Int(longitude), (-90...89).contains(lat), (-180...179).contains(lon) else {
                        model.error = "Enter whole-number coordinates: latitude −90 to 89, longitude −180 to 179."; return
                    }
                    Task { await model.assignImagery(latitude: lat, longitude: lon, provider: provider) }
                }.disabled(latitude.isEmpty || longitude.isEmpty)
                Text("Select Custom Map as the imagery source in Settings › Imagery to use these overrides.").font(.caption).foregroundStyle(.secondary)
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

// MARK: - Diagnostics

struct DiagnosticsView: View {
    @EnvironmentObject var model: AppModel
    @NativeState<String> private var tab = "Log"
    @NativeState<Bool> private var follow = true
    var body: some View {
        VStack(spacing: 0) {
            Picker("Diagnostics", selection: $tab) { Text("Log").tag("Log"); Text("Performance Reports").tag("Reports") }
                .pickerStyle(.segmented).labelsHidden().padding()
            Divider()
            if tab == "Log" {
                ScrollViewReader { proxy in
                    ScrollView {
                        Text(model.logs.isEmpty ? "No log entries." : filteredLogs)
                            .font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading).padding()
                        Color.clear.frame(height: 1).id("end")
                    }
                    .background(.background)
                    .onAppear { if follow { proxy.scrollTo("end", anchor: .bottom) } }
                    .onChange(of: model.logs) { if follow && model.logQuery.isEmpty { proxy.scrollTo("end", anchor: .bottom) } }
                    .onChange(of: follow) { if follow { proxy.scrollTo("end", anchor: .bottom) } }
                }
            } else if model.snapshot?.reports.isEmpty != false {
                ContentUnavailableView("No performance reports", systemImage: "chart.xyaxis.line", description: Text("Turn on Record performance reports in Settings › Diagnostics. Reports appear after a streaming session ends."))
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
        .searchable(text: $model.logQuery, prompt: "Filter log")
        .toolbar {
            Toggle(isOn: $follow) { Label("Follow Log", systemImage: "arrow.down.to.line") }
                .help("Keep the newest log entries in view")
            Button { model.exportLogs() } label: { Label("Export Log…", systemImage: "square.and.arrow.up") }
            Button { Task { await model.readLogs() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
        }
        .task { await model.readLogs() }
    }
    var filteredLogs: String { model.logQuery.isEmpty ? model.logs : model.logs.components(separatedBy: .newlines).filter { $0.localizedCaseInsensitiveContains(model.logQuery) }.joined(separator: "\n") }
}
