import Foundation
import CoreLocation

struct Setting: Codable, Identifiable {
    let id: String
    let section: String
    let key: String
    let value: String
    let help: String
    let kind: String
    var title: String { SettingsCatalog.title(for: self) }
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
    /// The catalog's newest release, set for installed regions when the catalog is loaded.
    var latestVersion: String? = nil
    var updateAvailable: Bool {
        guard installed, let latestVersion else { return false }
        return latestVersion.compare(version, options: .numeric) == .orderedDescending
    }
}
struct SceneryMount: Codable, Identifiable {
    var id: String { path }
    let name: String
    let path: String
    let mounted: Bool
}
struct EngineTask: Codable, Identifiable {
    let id: String
    let region: String
    let name: String
    let action: String
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
    let port: Int
    let engineExit: Int?
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

/// User-facing names for scenery operations, shared by menus, dialogs and Activity.
enum SceneryAction: String {
    case install, update, uninstall, seasons, restore, roughness, restore_roughness
    var title: String {
        switch self {
        case .install: return "Install"
        case .update: return "Update"
        case .uninstall: return "Remove"
        case .seasons: return "Apply Seasons"
        case .restore: return "Restore Original Terrain"
        case .roughness: return "Reduce Terrain Reflections"
        case .restore_roughness: return "Restore Terrain Reflections"
        }
    }
    var progressTitle: String {
        switch self {
        case .install: return "Installing"
        case .update: return "Updating"
        case .uninstall: return "Removing"
        case .seasons: return "Applying seasons to"
        case .restore: return "Restoring terrain for"
        case .roughness: return "Reducing reflections for"
        case .restore_roughness: return "Restoring reflections for"
        }
    }
    var doneTitle: String {
        switch self {
        case .install: return "Installed"
        case .update: return "Updated"
        case .uninstall: return "Removed"
        case .seasons: return "Applied seasons to"
        case .restore: return "Restored terrain for"
        case .roughness: return "Reduced reflections for"
        case .restore_roughness: return "Restored reflections for"
        }
    }
    var failedTitle: String {
        switch self {
        case .install: return "Couldn’t install"
        case .update: return "Couldn’t update"
        case .uninstall: return "Couldn’t remove"
        case .seasons: return "Couldn’t apply seasons to"
        case .restore: return "Couldn’t restore terrain for"
        case .roughness: return "Couldn’t reduce reflections for"
        case .restore_roughness: return "Couldn’t restore reflections for"
        }
    }
    var message: String {
        switch self {
        case .install: return "Scenery packages can require substantial disk space."
        case .update: return "Downloads the newest release of this region and replaces the installed one."
        case .uninstall: return "The downloaded scenery files for this region will be removed."
        case .seasons: return "This modifies the region’s terrain files to support seasonal imagery."
        case .restore: return "This restores the original scenery terrain. Your local terrain patches may be replaced."
        case .roughness: return "This applies your terrain roughness setting to the region’s terrain files."
        case .restore_roughness: return "This removes the terrain roughness adjustment from the region."
        }
    }
}

func byteLabel(_ value: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
}
