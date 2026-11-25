import Foundation
import SwiftUI
import UserNotifications

struct VolumeItem: Identifiable, Hashable {
    var id: String { url.path }
    let url: URL
    let name: String
    let fillRoot: URL
    let total: UInt64
    let free: UInt64
    let isInternal: Bool
}

struct VolumeInfo {
    var solidState: Bool?
    var fs: String = "?"
    var fileVault: Bool?
    var snapshots: Int = 0
}

enum Phase: Equatable {
    case idle, running
    case done(String)
    case cancelled
    case failed(String)
}

private func runTool(_ path: String, _ args: [String]) -> Data {
    let p = Process(); p.executableURL = URL(fileURLWithPath: path); p.arguments = args
    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = Pipe()
    do { try p.run() } catch { return Data() }
    let d = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return d
}

@MainActor
final class AppModel: ObservableObject {
    @Published var volumes: [VolumeItem] = []
    @Published var selected: VolumeItem?
    @Published var level = Level.all[1] { didSet { verify = level.verify } }
    @Published var verify = true
    @Published var scrub = true
    @Published var reserveMB = 512
    @Published var phase: Phase = .idle { didSet { phaseChanged(oldValue) } }
    var debugUI: String?
    @Published var progress = WipeProgress()
    @Published var info: VolumeInfo?
    @Published var confirming = false
    @Published var customCount = 3
    @Published var customHex = "AA 55"
    @Published var customPattern = CustomPattern.random
    @Published var reportURL: URL?
    enum Mode: String, CaseIterable, Identifiable { case space = "Wolne miejsce", files = "Pliki i foldery"; var id: String { rawValue } }
    @Published var mode = Mode.space
    @Published var shredItems: [URL] = []
    @Published var schedWeekday = 0
    @Published var schedHour = 3
    @Published var schedInstalled = Scheduler.isInstalled
    private var shredder: FileShredder?

    var passes: [PassKind] { level.id == "custom" ? customPattern.passes(customCount, hex: parseHex(customHex)) : level.passes }
    var levelTitle: String { level.id == "custom" ? "Własny (\(customCount)× \(customPattern.rawValue))" : level.name }

    init() {
        let d = UserDefaults.standard
        if let id = d.string(forKey: "lastLevel"), let l = Level.all.first(where: { $0.id == id }) { level = l; verify = l.verify }
        if d.object(forKey: "lastVerify") != nil { verify = d.bool(forKey: "lastVerify"); scrub = d.bool(forKey: "lastScrub") }
        if d.integer(forKey: "lastReserve") > 0 { reserveMB = d.integer(forKey: "lastReserve") }
        let a = CommandLine.arguments
        if let i = a.firstIndex(of: "--ui"), a.count > i + 1 { debugUI = a[i + 1]; if a[i + 1] == "files" { mode = .files }
            if a[i + 1] == "running" {
                phase = .running
                progress = WipeProgress(pass: 2, passes: 3, phase: String(format: tr("Przebieg %d/%d: %@"), 2, 3, PassKind.byte(0xFF).label),
                                        done: 3_400_000_000, total: 7_000_000_000, speed: 410_000_000, passFraction: 0.62)
            } }
    }

    private func phaseChanged(_ old: Phase) {
        guard old == .running else { return }
        switch phase {
        case .done(let t): notify(tr("Zakończono"), t)
        case .failed(let t): notify(tr("Błąd"), t)
        default: break
        }
    }

    private func notify(_ title: String, _ body: String) {
        let c = UNMutableNotificationContent(); c.title = title; c.body = body; c.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }

    private var engine: WipeEngine?
    private var activity: NSObjectProtocol?

    var gpuName: String { WipeEngine().usesGPU ? "Metal GPU" : tr("CPU (brak Metal)") }

    func refresh() {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
                                      .volumeIsInternalKey, .volumeIsLocalKey, .volumeIsReadOnlyKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys,
                                                         options: [.skipHiddenVolumes]) ?? []
        var items: [VolumeItem] = []
        for u in urls {
            guard let v = try? u.resourceValues(forKeys: Set(keys)), v.volumeIsLocal == true else { continue }
            let isRoot = u.path == "/"
            if v.volumeIsReadOnly == true && !isRoot { continue }
            let root = isRoot ? URL(fileURLWithPath: NSHomeDirectory()) : u
            WipeEngine.cleanStale(in: root)
            items.append(VolumeItem(url: u, name: v.volumeName ?? u.lastPathComponent, fillRoot: root,
                                    total: UInt64(v.volumeTotalCapacity ?? 0),
                                    free: freeBytes(root.path),
                                    isInternal: v.volumeIsInternal ?? false))
        }
        volumes = items
        if let s = selected, let n = items.first(where: { $0.id == s.id }) { selected = n }
        else { selected = items.first(where: { $0.id == UserDefaults.standard.string(forKey: "lastVolume") }) ?? items.first }
        loadInfo()
    }

    func loadInfo() {
        guard let v = selected else { info = nil; return }
        info = nil
        let path = v.url.path
        Task.detached {
            var i = VolumeInfo()
            let d = runTool("/usr/sbin/diskutil", ["info", "-plist", path])
            if let plist = try? PropertyListSerialization.propertyList(from: d, format: nil) as? [String: Any] {
                i.solidState = plist["SolidState"] as? Bool
                i.fs = (plist["FilesystemType"] as? String) ?? "?"
                i.fileVault = plist["FileVault"] as? Bool
            }
            let t = String(decoding: runTool("/usr/bin/tmutil", ["listlocalsnapshots", path]), as: UTF8.self)
            i.snapshots = t.split(separator: "\n").filter { $0.contains("com.apple") }.count
            await MainActor.run { if self.selected?.url.path == path { self.info = i } }
        }
    }

    func start() {
        guard let v = selected, phase != .running else { return }
        let cfg = WipeConfig(fillRoot: v.fillRoot, passes: passes, verify: verify,
                             reserve: UInt64(reserveMB) << 20, scrubMetadata: scrub)
        let d = UserDefaults.standard
        d.set(level.id, forKey: "lastLevel"); d.set(verify, forKey: "lastVerify"); d.set(scrub, forKey: "lastScrub")
        d.set(reserveMB, forKey: "lastReserve"); d.set(v.id, forKey: "lastVolume")
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        let eng = WipeEngine()
        engine = eng
        phase = .running
        progress = WipeProgress(pass: 0, passes: cfg.passes.count, phase: tr("Przygotowanie…"), total: 1)
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.idleSystemSleepDisabled, .userInitiated], reason: "Czyszczenie wolnego miejsca")
        eng.onProgress = { p in DispatchQueue.main.async { self.progress = p } }
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try eng.run(cfg) }
            DispatchQueue.main.async {
                if let a = self.activity { ProcessInfo.processInfo.endActivity(a); self.activity = nil }
                switch result {
                case .success(let r):
                    let t = Int(r.seconds)
                    self.reportURL = makeReport(volName: v.name, volPath: v.url.path, cfg: cfg, r: r, info: self.info, levelTitle: self.levelTitle)
                    self.phase = .done(String(format: tr("Nadpisano %@ w %lld przebiegach"), fmtBytes(r.bytesWritten), Int64(r.passes))
                        + (r.verified ? tr(", zweryfikowano") : "") + String(format: " (%d min %02d s).", t / 60, t % 60))
                case .failure(let e):
                    if case WipeError.cancelled = e { self.phase = .cancelled }
                    else { self.phase = .failed(e.localizedDescription) }
                }
                self.engine = nil
                self.refresh()
            }
        }
    }

    func cancel() { engine?.cancel(); shredder?.cancel() }

    func addItems(_ urls: [URL]) {
        for u in urls where !shredItems.contains(u) { shredItems.append(u) }
    }

    func startShred() {
        guard phase != .running, !shredItems.isEmpty else { return }
        let items = shredItems, passes = self.passes
        if let bad = items.first(where: { FileShredder.isProtected($0) }) {
            phase = .failed(String(format: tr("Chroniona ścieżka, nie można skasować: %@"), bad.path)); return
        }
        let sh = FileShredder(); shredder = sh
        phase = .running; reportURL = nil
        progress = WipeProgress(pass: 0, passes: passes.count, phase: tr("Przygotowanie…"), total: 1)
        activity = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled, .userInitiated], reason: "Kasowanie plików")
        sh.onProgress = { p in DispatchQueue.main.async { self.progress = p } }
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try sh.shred(items, passes: passes) }
            DispatchQueue.main.async {
                if let a = self.activity { ProcessInfo.processInfo.endActivity(a); self.activity = nil }
                switch result {
                case .success(let s):
                    self.shredItems = []
                    self.phase = s.failed.isEmpty
                        ? .done(String(format: tr("Bezpowrotnie skasowano %lld plików (%@). Na APFS zalecamy potem czyszczenie wolnego miejsca."), Int64(s.files), fmtBytes(s.bytes)))
                        : .failed(String(format: tr("Skasowano %lld, nie udało się: %lld (np. %@)"), Int64(s.files), Int64(s.failed.count), s.failed[0]))
                case .failure(let e):
                    if case WipeError.cancelled = e { self.phase = .cancelled } else { self.phase = .failed(e.localizedDescription) }
                }
                self.shredder = nil
            }
        }
    }

    func deleteSnapshots() {
        guard let v = selected else { return }
        let path = v.url.path
        Task.detached {
            let t = String(decoding: runTool("/usr/bin/tmutil", ["listlocalsnapshots", path]), as: UTF8.self)
            for line in t.split(separator: "\n") where line.contains("com.apple.TimeMachine.") {
                let d = line.replacingOccurrences(of: "com.apple.TimeMachine.", with: "").replacingOccurrences(of: ".local", with: "")
                _ = runTool("/usr/bin/tmutil", ["deletelocalsnapshots", d.trimmingCharacters(in: .whitespaces)])
            }
            await MainActor.run { self.loadInfo() }
        }
    }

    func installSchedule() {
        guard let v = selected else { return }
        let lvl = level.id == "custom" ? "standard" : level.id
        do { try Scheduler.install(weekday: schedWeekday, hour: schedHour, volumePath: v.url.path, levelId: lvl, reserveMB: reserveMB) }
        catch { phase = .failed(error.localizedDescription) }
        schedInstalled = Scheduler.isInstalled
    }
    func removeSchedule() { Scheduler.remove(); schedInstalled = Scheduler.isInstalled }
    func reset() { phase = .idle }
}
