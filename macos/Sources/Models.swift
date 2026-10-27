import Foundation
import CoreLocation

struct Setting: Codable, Identifiable {
    let id: String
    let section: String
    let key: String
    let value: String
    let help: String
    let kind: String
    var title: String { key.replacingOccurrences(of: "_", with: " ").capitalized }
}
struct ReadinessCheck: Codable, Identifiable {
    let id: String
    let title: String
    let ok: Bool
    let detail: String
}
struct Region: Codable, Identifiable {
    let id: String
    let name: String
    let version: String
    let bytes: Int64
    let installed: Bool
}
struct SceneryMount: Codable, Identifiable {
    var id: String { path }
    let name: String
    let path: String
    let mounted: Bool
}
struct EngineTask: Codable, Identifiable {
    let id: String
    let title: String
    let state: String
    let message: String
    let progress: Double?
}
struct Report: Codable, Identifiable {
    let id: String
    let name: String
    let path: String
    let modified: Double
}
struct Snapshot: Codable {
    let status: String
    let owned: Bool
    let ready: Bool
    let checks: [ReadinessCheck]
    let mounts: [SceneryMount]
    let settings: [Setting]
    let revision: String
    let regions: [Region]
    let catalog: [Region]
    let tasks: [EngineTask]
    let freeBytes: Int64
    let reports: [Report]
    let logPath: String
    let reportsPath: String
    let port: Int
}
struct RoutePoint: Identifiable {
    let id: String
    let name: String
    let coordinate: CLLocationCoordinate2D
}

enum Destination: String, CaseIterable, Identifiable {
    case overview = "Overview", scenery = "Scenery", flight = "Flight Plan", activity = "Activity", diagnostics = "Diagnostics"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .overview: return "airplane.circle"
        case .scenery: return "map"
        case .flight: return "point.topleft.down.to.point.bottomright.curvepath"
        case .activity: return "arrow.down.circle"
        case .diagnostics: return "waveform.path.ecg"
        }
    }
}

func byteLabel(_ value: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
}
