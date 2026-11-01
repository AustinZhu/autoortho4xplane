import SwiftUI
import AppKit
import MapKit

/// Why streaming can't start right now, and the one action that resolves it.
struct StartBlocker {
    enum Fix { case applySettings, chooseXPlane, manageScenery, waitForTasks, none }
    let message: String
    let fix: Fix
}

/// An alert whose title states what failed, per Apple's alert guidance.
struct AppAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()
    let bridge = EngineBridge()
    @Published var snapshot: Snapshot?
    @Published var destination: Destination? = .overview
    @Published var alert: AppAlert?
    @Published var settingsError: String?
    @Published var busy = false
    @Published var transition: String?
    @Published var loadingCatalog = false
    @Published var logs = ""
    @Published var sceneryQuery = ""
    @Published var logQuery = ""
    @Published var edits: [String: String] = [:]
    @Published var pilotID = ""
    @Published var route: [RoutePoint] = []
    @Published var routeTitle = "No flight plan loaded"
    @Published var aircraft: CLLocationCoordinate2D?
    @Published var loadingFlight = false
    @Published var reportText = ""
    @Published var reportName = ""
    @Published var imagery: [String: String] = [:]
    private var editRevision: String?
    private var started = false
    private var refreshing = false
    private var polling: Task<Void, Never>?
    private var hadStreaming = false
    /// X-Plane was already open when streaming started, so its loaded flight lacks AutoOrtho scenery.
    @Published var xplaneStartedFirst = false

    var running: Bool { ["streaming", "starting"].contains(snapshot?.status ?? "") }
    var ownsStreaming: Bool { snapshot?.owned == true }
    var tasks: [EngineTask] { snapshot?.tasks ?? [] }
    var hasRunningTask: Bool { tasks.contains { $0.state == "running" } }
    var runningTaskCount: Int { tasks.filter { $0.state == "running" }.count }
    var statusTitle: String {
        if let transition { return transition }
        switch snapshot?.status {
        case "streaming": return "Streaming scenery"
        case "starting": return "Starting streaming…"
        case "failed": return "Streaming stopped unexpectedly"
        default: return snapshot?.ready == true ? "Ready to fly" : "Finish setting up"
        }
    }
    var statusDetail: String {
        switch snapshot?.status {
        case "streaming":
            if !ownsStreaming { return "Streaming is managed by another AutoOrtho instance." }
            return xplaneStartedFirst ? "X-Plane was already open. Reload your flight to see AutoOrtho scenery."
                                      : "Satellite scenery is available to X-Plane."
        case "starting": return "Mounting scenery for X-Plane. This can take a minute."
        case "failed":
            let code = snapshot?.engineExit.map { " (exit code \($0))" } ?? ""
            return "The streaming engine exited\(code). The log shows what happened."
        default: return "Start streaming before opening your X-Plane flight."
        }
    }
    var mountSummary: String {
        let mounts = snapshot?.mounts ?? []
        let mounted = mounts.filter(\.mounted).count
        return mounts.isEmpty ? "No regions installed" : "\(mounted) of \(mounts.count) regions mounted"
    }
    var startBlocker: StartBlocker? {
        guard let snapshot else { return .init(message: "Connecting to the streaming engine…", fix: .none) }
        if let check = snapshot.checks.first(where: { !$0.ok }) {
            switch check.id {
            case "xplane": return .init(message: "Choose your X-Plane folder.", fix: .chooseXPlane)
            case "scenery": return .init(message: "Install at least one scenery region.", fix: .manageScenery)
            case "storage": return .init(message: "Free up disk space. AutoOrtho needs at least 2 GB.", fix: .none)
            default: return .init(message: "\(check.title): \(check.detail)", fix: .none)
            }
        }
        if hasRunningTask { return .init(message: "Wait for the scenery operation to finish.", fix: .waitForTasks) }
        if !edits.isEmpty { return .init(message: "You have unapplied settings.", fix: .applySettings) }
        return nil
    }
    var canStart: Bool { !running && !busy && startBlocker == nil }
    var canStop: Bool { running && !busy && ownsStreaming }
    /// Catalog and installed regions together. Installed state comes only from the live installed
    /// list: the catalog's own flag is fixed when it was fetched and goes stale after installs and removals.
    var allRegions: [Region] {
        let installed = Dictionary(uniqueKeysWithValues: (snapshot?.regions ?? []).map { ($0.id, $0) })
        var items = installed
        for region in snapshot?.catalog ?? [] where installed[region.id] == nil {
            items[region.id] = Region(id: region.id, name: region.name, version: region.version, bytes: region.bytes, installed: false)
        }
        return items.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    var regions: [Region] {
        allRegions.filter { sceneryQuery.isEmpty || $0.name.localizedCaseInsensitiveContains(sceneryQuery) }
    }
    func task(for region: Region) -> EngineTask? {
        tasks.last { $0.region == region.id && $0.state == "running" }
    }
    /// Scenery mounts are named z_ao_<region id>; show the region's catalog name instead.
    func regionName(forMount name: String) -> String {
        let id = name.hasPrefix("z_ao_") ? String(name.dropFirst(5)) : name
        return (snapshot?.regions ?? []).first { $0.id == id }?.name ?? (snapshot?.catalog ?? []).first { $0.id == id }?.name ?? name
    }
    /// "Installing Europe", "Installed Europe" or "Couldn’t install Europe", depending on the task's state.
    func taskTitle(_ task: EngineTask) -> String {
        guard let action = SceneryAction(rawValue: task.action) else { return "\(task.action.capitalized) \(task.name)" }
        switch task.state {
        case "complete": return "\(action.doneTitle) \(task.name)"
        case "failed": return "\(action.failedTitle) \(task.name)"
        default: return "\(action.progressTitle) \(task.name)"
        }
    }
    var hasFinishedTasks: Bool { tasks.contains { $0.state != "running" } }

    func fail(_ title: String, _ error: Error) { fail(title, error.localizedDescription) }
    func fail(_ title: String, _ message: String) { alert = AppAlert(title: title, message: message) }

    func begin() {
        guard !started else { return }; started = true
        polling = Task {
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }
    func refresh() async {
        guard !refreshing else { return }; refreshing = true
        defer { refreshing = false }
        do {
            let data = try await bridge.request("snapshot", timeout: 15)
            let state = try JSONDecoder().decode(Snapshot.self, from: data)
            snapshot = state
            if pilotID.isEmpty { pilotID = setting("simbrief.userid") }
            if state.status == "streaming" {
                if !hadStreaming { _ = try? await bridge.request("flight.publish", timeout: 7) }
                await refreshAircraft(port: state.port)
            }
            hadStreaming = state.status == "streaming"
            if destination == .diagnostics { await readLogs() }
        } catch { if snapshot == nil { fail("Can’t Connect to the Streaming Engine", error) } }
    }

    // MARK: Settings
    /// The value on disk, ignoring unapplied edits.
    func savedSetting(_ id: String) -> String {
        snapshot?.settings.first(where: { $0.id == id })?.value ?? ""
    }
    func setting(_ id: String) -> String {
        edits[id] ?? snapshot?.settings.first(where: { $0.id == id })?.value ?? ""
    }
    func binding(_ id: String) -> Binding<String> {
        Binding(get: { self.setting(id) }, set: { self.edit(id, $0) })
    }
    func edit(_ id: String, _ value: String) {
        if edits.isEmpty { editRevision = snapshot?.revision }
        if snapshot?.settings.first(where: { $0.id == id })?.value == value { edits.removeValue(forKey: id) }
        else { edits[id] = value }
    }
    func revert() { edits.removeAll(); editRevision = nil }
    /// Discards edits and loads the settings as they are on disk now.
    func reloadSettings() async { revert(); await refresh() }
    @discardableResult
    func save() async -> Bool {
        guard !edits.isEmpty, let revision = editRevision else { return true }
        busy = true; defer { busy = false }
        do {
            let data = try await bridge.request("settings.save", ["changes": edits, "revision": revision])
            snapshot = try JSONDecoder().decode(Snapshot.self, from: data)
            revert()
            return true
        } catch { settingsError = error.localizedDescription; return false }
    }
    func applyAndStart() async {
        if await save() { await streaming(true) }
    }

    // MARK: Streaming
    func toggleStreaming() {
        if running { requestStop() } else { Task { await streaming(true) } }
    }
    /// Confirms with an app-modal alert so every entry point (window, menu, menu bar) behaves the same.
    /// Whether X-Plane is open, matched by the configured install folder or the app's name.
    var xplaneRunning: Bool {
        let folder = NSString(string: savedSetting("paths.xplane_path")).expandingTildeInPath
        return NSWorkspace.shared.runningApplications.contains { app in
            if !folder.isEmpty, let path = app.bundleURL?.path, path.hasPrefix(folder + "/") { return true }
            return app.localizedName?.hasPrefix("X-Plane") == true
        }
    }
    /// Stops at once when X-Plane is closed; otherwise confirms, since stopping removes scenery from the open flight.
    func requestStop() {
        guard canStop else { return }
        guard xplaneRunning else { Task { await streaming(false) }; return }
        let alert = NSAlert()
        alert.messageText = "Stop streaming while X-Plane is open?"
        alert.informativeText = "Stopping unmounts the scenery your flight is using. End the flight first, or stop anyway."
        alert.addButton(withTitle: "Keep Streaming")
        let stop = alert.addButton(withTitle: "Stop Streaming")
        stop.hasDestructiveAction = true
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertSecondButtonReturn { Task { await streaming(false) } }
    }
    func streaming(_ start: Bool) async {
        if start, let blocker = startBlocker { fail("Streaming Can’t Start Yet", blocker.message); return }
        busy = true; transition = start ? "Starting streaming…" : "Stopping streaming…"
        defer { busy = false; transition = nil }
        do {
            let openedFirst = start && xplaneRunning
            _ = try await bridge.request(start ? "streaming.start" : "streaming.stop")
            xplaneStartedFirst = openedFirst
            await refresh()
        } catch { fail(start ? "Couldn’t Start Streaming" : "Couldn’t Stop Streaming", error) }
    }

    // MARK: Scenery
    private var catalogAttempted = false
    func catalog() async {
        catalogAttempted = true
        loadingCatalog = true; defer { loadingCatalog = false }
        do { _ = try await bridge.request("catalog"); await refresh() }
        catch { fail("Couldn’t Load Regions", error) }
    }
    /// Loads the catalog once per session when Scenery first opens. Failures stay quiet;
    /// the Browse Regions and Refresh buttons retry and report errors.
    func loadCatalogIfNeeded() async {
        guard !catalogAttempted, !loadingCatalog, snapshot?.catalog.isEmpty != false else { return }
        catalogAttempted = true
        loadingCatalog = true; defer { loadingCatalog = false }
        if (try? await bridge.request("catalog", timeout: 60)) != nil { await refresh() }
    }
    func scenery(_ region: Region, action: SceneryAction) async {
        do { _ = try await bridge.request("scenery", ["region": region.id, "action": action.rawValue]); await refresh() }
        catch { fail("Couldn’t \(action.title) \(region.name)", error) }
    }

    func clearFinishedTasks() async {
        do { _ = try await bridge.request("tasks.clear"); await refresh() }
        catch { fail("Couldn’t Clear Activity", error) }
    }

    // MARK: Diagnostics
    private var logStamp = ""
    /// Polls ask only for changes; `force` re-reads the log even if it looks unchanged.
    func readLogs(force: Bool = false) async {
        do {
            let data = try await bridge.request("logs", force ? [:] : ["since": logStamp], timeout: 10)
            let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            logStamp = result["stamp"] as? String ?? ""
            if result["unchanged"] as? Bool == true { return }
            logs = result["text"] as? String ?? ""
        } catch { logs = error.localizedDescription; logStamp = "" }
    }

    // MARK: Flight
    func loadFlight() async {
        loadingFlight = true; defer { loadingFlight = false }
        do {
            let data = try await bridge.request("flight", ["user": pilotID])
            guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let plan = result["plan"] as? [String: Any] else { throw BridgeError.message("No flight plan was returned.") }
            let origin = plan["origin"] as? [String: Any] ?? [:]
            let arrival = plan["destination"] as? [String: Any] ?? [:]
            routeTitle = "\(origin["icao_code"] ?? "Departure") → \(arrival["icao_code"] ?? "Arrival")"
            let fixes = (plan["navlog"] as? [String: Any])?["fix"] as? [[String: Any]] ?? []
            route = ([origin] + fixes + [arrival]).enumerated().compactMap { index, fix in
                guard let lat = Double(String(describing: fix["pos_lat"] ?? "")),
                      let lon = Double(String(describing: fix["pos_long"] ?? "")),
                      (-90...90).contains(lat), (-180...180).contains(lon) else { return nil }
                return RoutePoint(id: String(index), name: String(describing: fix["ident"] ?? fix["icao_code"] ?? "Fix"),
                                  coordinate: .init(latitude: lat, longitude: lon))
            }
            await rememberPilotID()
        } catch { fail("Couldn’t Load Flight Plan", error) }
    }
    /// Saves a pilot ID that loaded successfully, when that can be done without touching other pending edits.
    /// Only numeric IDs are saved: the engine's other SimBrief client sends this value as `userid`.
    private func rememberPilotID() async {
        guard let snapshot, !running, edits.isEmpty, !pilotID.isEmpty, pilotID.allSatisfy(\.isASCII), pilotID.allSatisfy(\.isNumber),
              snapshot.settings.contains(where: { $0.id == "simbrief.userid" }),
              setting("simbrief.userid") != pilotID else { return }
        if let data = try? await bridge.request("settings.save", ["changes": ["simbrief.userid": pilotID], "revision": snapshot.revision]),
           let state = try? JSONDecoder().decode(Snapshot.self, from: data) { self.snapshot = state }
    }
    func loadImagery() async {
        do {
            let data = try await bridge.request("imagery")
            imagery = (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["cells"] as? [String: String] ?? [:]
        } catch { fail("Couldn’t Load Imagery Overrides", error) }
    }
    func assignImagery(latitude: Int, longitude: Int, provider: String?) async {
        do {
            var params: [String: Any] = ["latitude": latitude, "longitude": longitude]
            params["provider"] = provider ?? NSNull() as Any
            let data = try await bridge.request("imagery", params)
            imagery = (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["cells"] as? [String: String] ?? [:]
        } catch { fail("Couldn’t Update Imagery Override", error) }
    }
    private func refreshAircraft(port: Int) async {
        guard let url = URL(string: "http://127.0.0.1:\(port)/get_latlon") else { return }
        var request = URLRequest(url: url); request.timeoutInterval = 2
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let point = try? JSONSerialization.jsonObject(with: data) as? [String: Double],
              let lat = point["lat"], let lon = point["lon"], lat.isFinite, lon.isFinite,
              (-90...90).contains(lat), (-180...180).contains(lon), lat != 0 || lon != 0 else { return }
        aircraft = .init(latitude: lat, longitude: lon)
    }

    // MARK: Files
    func chooseDirectory(_ id: String, applyNow: Bool = false) {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.canCreateDirectories = true; panel.prompt = "Choose"
        panel.directoryURL = URL(fileURLWithPath: NSString(string: setting(id)).expandingTildeInPath)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // Apply immediately only when this is the sole change, so other pending edits aren't saved silently.
        let applies = applyNow && edits.isEmpty
        edit(id, url.path)
        if applies { Task { if !(await save()) { fail("Couldn’t Save the Folder", settingsError ?? ""); settingsError = nil } } }
    }
    func reveal(_ path: String) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
    func showReport(_ report: Report) {
        do { reportText = try String(contentsOfFile: report.path, encoding: .utf8); reportName = report.name }
        catch { fail("Couldn’t Open Report", error) }
    }
    func exportLogs() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "AutoOrtho.log"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try (logs + "\n" + bridge.diagnostics).write(to: url, atomically: true, encoding: .utf8) }
        catch { fail("Couldn’t Export Log", error) }
    }
    func shutdown() async -> Bool {
        if hasRunningTask { fail("AutoOrtho Can’t Quit Yet", "Wait for the scenery operation to finish before quitting."); return false }
        do { _ = try await bridge.request("shutdown"); polling?.cancel(); bridge.close(); return true }
        catch { fail("Couldn’t Quit Cleanly", error); return false }
    }
}
