import Foundation

/// Cykliczne czyszczenie przez launchd (agent użytkownika). Uruchamia tę samą aplikację w trybie CLI.
enum Scheduler {
    static let label = "studio.tm.blankspace.schedule"
    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }
    static var isInstalled: Bool { FileManager.default.fileExists(atPath: plistURL.path) }

    private static func launchctl(_ args: [String]) {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/launchctl"); p.arguments = args
        p.standardOutput = Pipe(); p.standardError = Pipe()
        try? p.run(); p.waitUntilExit()
    }

    static func install(weekday: Int, hour: Int, volumePath: String, levelId: String, reserveMB: Int) throws {
        guard let exe = Bundle.main.executablePath else { throw WipeError.io("brak ścieżki aplikacji") }
        let dict: [String: Any] = [
            "Label": label,
            "ProgramArguments": [exe, "--scheduled", volumePath, levelId, String(reserveMB)],
            "StartCalendarInterval": ["Weekday": weekday, "Hour": hour, "Minute": 0],
            "ProcessType": "Background", "LowPriorityIO": true,
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
        try FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        launchctl(["bootout", "gui/\(getuid())/\(label)"])
        try data.write(to: plistURL, options: .atomic)
        launchctl(["bootstrap", "gui/\(getuid())", plistURL.path])
    }

    static func remove() {
        launchctl(["bootout", "gui/\(getuid())/\(label)"])
        try? FileManager.default.removeItem(at: plistURL)
    }

    /// Tryb CLI: BlankSpace --scheduled <wolumin> <id poziomu> <rezerwa MB>
    static func runScheduled(volume: String, levelId: String, reserveMB: Int) -> Int32 {
        guard let level = Level.all.first(where: { $0.id == levelId && $0.id != "custom" }) else { print("Nieznany poziom"); return 2 }
        let root = volume == "/" ? URL(fileURLWithPath: NSHomeDirectory()) : URL(fileURLWithPath: volume)
        let cfg = WipeConfig(fillRoot: root, passes: level.passes, verify: level.verify,
                             reserve: UInt64(reserveMB) << 20, scrubMetadata: true)
        do {
            let r = try WipeEngine().run(cfg)
            let u = makeReport(volName: root.lastPathComponent, volPath: volume, cfg: cfg, r: r, info: nil,
                               levelTitle: level.name, source: "harmonogram")
            print("OK \(u?.path ?? "")"); return 0
        } catch { print("FAIL \(error.localizedDescription)"); return 1 }
    }
}
