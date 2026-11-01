import Foundation

/// Presentation of the engine's config keys: page, group, title and limits.
/// Keys not listed here still appear, on the Advanced page under their config section,
/// so new engine settings are never lost.
struct SettingsPage: Identifiable, Hashable {
    let id: String
    let title: String
    let symbol: String
    let groups: [String]
}

enum SettingsCatalog {
    static let pages: [SettingsPage] = [
        .init(id: "general", title: "General", symbol: "gearshape", groups: ["Locations"]),
        .init(id: "imagery", title: "Imagery", symbol: "photo", groups: ["Source", "Quality", "Textures", "Night Imagery", "Troubleshooting"]),
        .init(id: "loading", title: "Loading", symbol: "speedometer", groups: ["Loading and Fallbacks", "Prefetching", "Predictive Loading"]),
        .init(id: "storage", title: "Storage", symbol: "internaldrive", groups: ["Cache", "Cache Tuning"]),
        .init(id: "scenery", title: "Scenery", symbol: "map", groups: ["Installation", "Seasons", "Terrain"]),
        .init(id: "flight", title: "Flight", symbol: "airplane", groups: ["SimBrief", "X-Plane Connection"]),
        .init(id: "advanced", title: "Advanced", symbol: "slider.horizontal.3", groups: ["Engine", "Network"]),
        .init(id: "diagnostics", title: "Diagnostics", symbol: "waveform.path.ecg", groups: ["Logging", "Performance Profiling"]),
    ]

    /// Application state and legacy-window keys that are not user preferences.
    static let hidden: Set<String> = [
        "general.gui", "general.showconfig", "general.setup_complete", "general.config_revision",
        "general.window_width", "general.window_height", "general.window_x", "general.window_y",
        "general.last_page", "general.dismissed_update_version", "general.hide", "paths.log_file",
    ]
    static let hiddenSections: Set<String> = ["windows"]

    static func isVisible(_ setting: Setting) -> Bool {
        !hidden.contains(setting.id) && !hiddenSections.contains(setting.section)
    }

    /// (page id, group title) for a setting.
    static func placement(of setting: Setting) -> (page: String, group: String) {
        switch setting.section {
        case "paths": return ("general", "Locations")
        case "pydds": return ("imagery", "Textures")
        case "time_exclusion": return ("imagery", "Night Imagery")
        case "cache": return ("storage", "Cache")
        case "scenery": return ("scenery", "Installation")
        case "seasons": return ("scenery", "Seasons")
        case "terrain": return ("scenery", "Terrain")
        case "simbrief": return ("flight", "SimBrief")
        case "flightdata": return ("flight", "X-Plane Connection")
        case "fuse": return ("advanced", "Engine")
        case "diagnostics": return ("diagnostics", "Performance Profiling")
        case "general" where setting.key.hasSuffix("log_level"): return ("diagnostics", "Logging")
        case "autoortho": return autoorthoPlacement(setting.key)
        default: return ("advanced", sectionTitle(setting.section))
        }
    }

    // Mirrors the Qt app's grouping of the [autoortho] section.
    private static func autoorthoPlacement(_ key: String) -> (page: String, group: String) {
        switch key {
        case "maptype_override", "simheaven_compat", "using_custom_tiles": return ("imagery", "Source")
        case "min_zoom", "max_zoom", "max_zoom_near_airports", "max_zoom_mode", "dynamic_zoom_steps": return ("imagery", "Quality")
        case "missing_color": return ("imagery", "Troubleshooting")
        case "maxwait", "suspend_maxwait", "use_time_budget", "tile_time_budget", "fallback_level",
             "fallback_extends_budget", "fallback_timeout", "native_partial_allow_incomplete":
            return ("loading", "Loading and Fallbacks")
        case "tile_image_cache_mb", "cache_write_buffer_mb", "long_term_cache_write_buffer_mb", "ephemeral_dds_cache_mb",
             "persistent_dds_cache_mb", "persist_partial_dds_cache", "partial_cache_promote_startup_max_tiles",
             "cleanup_source_jpegs_after_dds", "dds_cache_maintenance_workers", "disk_budget_enabled", "dds_budget_pct":
            return ("storage", "Cache Tuning")
        default:
            if key.hasPrefix("prefetch") || key == "strict_target_deadline_sec" { return ("loading", "Prefetching") }
            if key.hasPrefix("predictive_dds") || ["background_builder_workers", "live_builder_concurrency", "live_tile_admission"].contains(key) {
                return ("loading", "Predictive Loading")
            }
            if key.hasPrefix("http2") || key.hasPrefix("provider") || key.contains("download") || key == "fetch_threads" {
                return ("advanced", "Network")
            }
            return ("advanced", "Engine")
        }
    }

    static func sectionTitle(_ section: String) -> String {
        section.replacingOccurrences(of: "_", with: " ").capitalized
    }

    private static let titles: [String: String] = [
        "paths.xplane_path": "X-Plane folder", "paths.scenery_path": "Scenery folder",
        "paths.cache_dir": "Cache folder", "paths.long_term_cache_dir": "Long-term cache folder",
        "paths.download_dir": "Downloads folder", "paths.dsf_dir": "DSF folder",
        "autoortho.maptype_override": "Imagery source", "autoortho.simheaven_compat": "SimHeaven compatibility",
        "autoortho.using_custom_tiles": "Using custom tiles", "autoortho.missing_color": "Missing tile color",
        "autoortho.min_zoom": "Minimum zoom level", "autoortho.max_zoom": "Maximum zoom level",
        "autoortho.max_zoom_near_airports": "Maximum zoom near airports", "autoortho.max_zoom_mode": "Zoom mode",
        "autoortho.dynamic_zoom_steps": "Altitude zoom steps", "autoortho.maxwait": "Maximum wait per chunk (s)",
        "pydds.compressor": "Texture compressor", "pydds.format": "Texture format",
        "pydds.dds_compression": "Texture cache compression", "pydds.dds_compression_level": "Compression level",
        "pydds.water_alpha": "Water transparency",
        "cache.file_cache_size": "Disk cache limit (GB)", "cache.cache_mem_limit": "Memory cache limit (GB)",
        "cache.auto_clean_cache": "Clean cache automatically",
        "flightdata.webui_port": "Map server port", "flightdata.xplane_udp_port": "X-Plane UDP port",
        "simbrief.userid": "SimBrief pilot ID", "simbrief.use_flight_data": "Use flight plan for prefetching",
        "general.console_log_level": "Console log level", "general.file_log_level": "File log level",
        "time_exclusion.enabled": "Exclude imagery at night", "seasons.enabled": "Seasonal imagery",
        "diagnostics.performance_profiling": "Record performance reports",
    ]
    private static let words: [String: String] = [
        "dds": "DDS", "http2": "HTTP/2", "jpegs": "JPEGs", "ui": "UI", "udp": "UDP", "id": "ID", "userid": "user ID",
        "aopipeline": "AO pipeline", "xplane": "X-Plane", "dsf": "DSF", "ter": "terrain", "maxwait": "max wait",
        "mb": "(MB)", "gb": "(GB)", "nm": "(NM)", "sec": "(s)", "seconds": "(s)", "ms": "(ms)", "pct": "(%)",
        "spr": "Spring", "sum": "Summer", "fal": "Autumn", "win": "Winter",
    ]

    /// Sentence-case title, as used by macOS System Settings.
    static func title(for setting: Setting) -> String {
        if let title = titles[setting.id] { return title }
        let parts = setting.key.split(separator: "_").map { words[String($0)] ?? String($0) }
        let text = parts.joined(separator: " ")
        return text.prefix(1).uppercased() + text.dropFirst()
    }

    /// Bounds the engine accepts, so steppers can't produce a value that fails on Apply.
    static func limits(_ id: String) -> ClosedRange<Int>? {
        switch id {
        case "autoortho.min_zoom": return 1...20
        case "autoortho.max_zoom", "autoortho.max_zoom_near_airports": return 12...20
        case "pydds.water_alpha": return 0...255
        case "pydds.dds_compression_level": return 1...19
        case "cache.file_cache_size": return 10...10000
        case "cache.cache_mem_limit": return 2...1024
        case "flightdata.webui_port", "flightdata.xplane_udp_port": return 1024...65535
        default: return nil
        }
    }

    static func choices(_ id: String) -> [String] {
        switch id {
        case "autoortho.maptype_override": return ["Use tile default", "BI", "NAIP", "EOX", "USGS", "Firefly", "GO2", "ARC", "YNDX", "APPLE", "Custom Map"]
        case "autoortho.max_zoom_mode": return ["fixed", "dynamic"]
        case "pydds.compressor": return ["ISPC", "STB"]
        case "pydds.format": return ["BC1", "BC3"]
        case "pydds.dds_compression": return ["none", "zstd"]
        case "general.console_log_level", "general.file_log_level": return ["DEBUG", "INFO", "WARNING", "ERROR", "CRITICAL"]
        default: return []
        }
    }

    /// Help text, replacing engine comments that describe a raw format the app now edits for the user.
    static func help(for setting: Setting) -> String? {
        switch setting.id {
        case "autoortho.dynamic_zoom_steps":
            return "Each step sets the maximum zoom at or above an altitude above ground. The ground step always applies."
        default: return setting.help
        }
    }

    static func isFolder(_ setting: Setting) -> Bool {
        setting.section == "paths" || setting.key == "report_dir"
    }
}
