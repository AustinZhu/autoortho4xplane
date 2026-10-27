import SwiftUI
import AppKit
import MapKit

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()
    let bridge = EngineBridge()
    @Published var snapshot: Snapshot?
    @Published var destination: Destination? = .overview
    @Published var error: String?
    @Published var busy = false
    @Published var loadingCatalog = false
    @Published var logs = ""
    @Published var search = ""
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
    var running: Bool { ["streaming", "starting"].contains(snapshot?.status ?? "") }
    var hasRunningTask: Bool { snapshot?.tasks.contains { $0.state == "running" } ?? false }
    var statusTitle: String {
        switch snapshot?.status {
        case "streaming": return "Streaming scenery"
        case "starting": return "Starting streaming…"
        case "failed": return "Streaming stopped unexpectedly"
        default: return snapshot?.ready == true ? "Ready to fly" : "Finish setting up"
        }
    }
    var regions: [Region] {
        var items = Dictionary(uniqueKeysWithValues: (snapshot?.catalog ?? []).map { ($0.id, $0) })
        for region in snapshot?.regions ?? [] { items[region.id] = region }
        return items.values.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

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
        } catch { if snapshot == nil { self.error = error.localizedDescription } }
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
    func save() async {
        guard !edits.isEmpty, let revision = editRevision else { return }
        busy = true; defer { busy = false }
        do {
            let data = try await bridge.request("settings.save", ["changes": edits, "revision": revision])
            snapshot = try JSONDecoder().decode(Snapshot.self, from: data)
            revert()
        } catch { self.error = error.localizedDescription }
    }
    func streaming(_ start: Bool) async {
        busy = true; defer { busy = false }
        do {
            if start && !edits.isEmpty { throw BridgeError.message("Apply or revert your settings before starting streaming.") }
            _ = try await bridge.request(start ? "streaming.start" : "streaming.stop")
            await refresh()
        } catch { self.error = error.localizedDescription }
    }
    func catalog() async {
        loadingCatalog = true; defer { loadingCatalog = false }
        do { _ = try await bridge.request("catalog"); await refresh() }
        catch { self.error = error.localizedDescription }
    }
    func scenery(_ region: Region, action: String) async {
        do { _ = try await bridge.request("scenery", ["region": region.id, "action": action]); destination = .activity; await refresh() }
        catch { self.error = error.localizedDescription }
    }
    func readLogs() async {
        do {
            let data = try await bridge.request("logs", timeout: 10)
            logs = (try JSONSerialization.jsonObject(with: data) as? [String: String])?["text"] ?? ""
        } catch { logs = error.localizedDescription }
    }
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
        } catch { self.error = error.localizedDescription }
    }
    func loadImagery() async {
        do {
            let data = try await bridge.request("imagery")
            imagery = (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["cells"] as? [String: String] ?? [:]
        } catch { self.error = error.localizedDescription }
    }
    func assignImagery(latitude: Int, longitude: Int, provider: String?) async {
        do {
            var params: [String: Any] = ["latitude": latitude, "longitude": longitude]
            params["provider"] = provider ?? NSNull() as Any
            let data = try await bridge.request("imagery", params)
            imagery = (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["cells"] as? [String: String] ?? [:]
        } catch { self.error = error.localizedDescription }
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
    func chooseDirectory(_ id: String) {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.canCreateDirectories = true; panel.prompt = "Choose"
        panel.directoryURL = URL(fileURLWithPath: NSString(string: setting(id)).expandingTildeInPath)
        if panel.runModal() == .OK, let url = panel.url { edit(id, url.path) }
    }
    func reveal(_ path: String) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
    func showReport(_ report: Report) {
        do { reportText = try String(contentsOfFile: report.path, encoding: .utf8); reportName = report.name }
        catch { self.error = error.localizedDescription }
    }
    func exportLogs() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "AutoOrtho.log"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try (logs + "\n" + bridge.diagnostics).write(to: url, atomically: true, encoding: .utf8) }
        catch { self.error = error.localizedDescription }
    }
    func shutdown() async -> Bool {
        if hasRunningTask { error = "Wait for the scenery operation to finish before quitting."; return false }
        do { _ = try await bridge.request("shutdown"); polling?.cancel(); bridge.close(); return true }
        catch { self.error = error.localizedDescription; return false }
    }
}
