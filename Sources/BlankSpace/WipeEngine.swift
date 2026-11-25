import Foundation

private struct FileRec { let path: String; let size: UInt64; let startChunk: UInt64 }

func freeBytes(_ path: String) -> UInt64 {
    var s = statfs()
    guard statfs(path, &s) == 0 else { return 0 }
    return UInt64(s.f_bavail) * UInt64(s.f_bsize)
}

/// Silnik: wypełnia wolne miejsce plikami tymczasowymi (wzorce / dane losowe z GPU),
/// wymusza zapis na nośnik (F_NOCACHE + F_FULLFSYNC), opcjonalnie weryfikuje odczytem, usuwa pliki.
final class WipeEngine {
    static let fillPrefix = ".blankspace-"
    private static let fileMax: UInt64 = 1 << 30

    var onProgress: ((WipeProgress) -> Void)?
    private let gen = ChunkGen()
    private let lock = NSLock()
    private var _cancel = false
    func cancel() { lock.lock(); _cancel = true; lock.unlock() }
    private var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return _cancel }

    private var prog = WipeProgress()
    private var startTime = Date()
    private var lastReport = Date.distantPast
    private var winTime = Date()
    private var winBytes: UInt64 = 0
    private var speed: Double = 0
    private var reserve: UInt64 = 0
    var usesGPU: Bool { gen.usesGPU }

    /// Usuwa pozostałości po przerwanych sesjach.
    static func cleanStale(in root: URL) {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(atPath: root.path) else { return }
        for i in items where i.hasPrefix(fillPrefix) || i.hasPrefix(".wymaz-") { try? fm.removeItem(at: root.appendingPathComponent(i)) }
    }

    private func report(force: Bool = false) {
        let now = Date()
        guard force || now.timeIntervalSince(lastReport) > 0.1 else { return }
        lastReport = now
        let dt = now.timeIntervalSince(winTime)
        if dt >= 1 {
            let inst = Double(prog.done - winBytes) / dt
            speed = speed == 0 ? inst : speed * 0.6 + inst * 0.4
            winTime = now; winBytes = prog.done
        }
        prog.speed = speed
        onProgress?(prog)
    }

    private func add(_ n: UInt64, passTotal: UInt64, passDone: UInt64) {
        prog.done = min(prog.total, prog.done + n)
        prog.passFraction = Double(passDone) / Double(max(passTotal, 1))
        report()
    }

    func run(_ cfg: WipeConfig) throws -> WipeResult {
        let fm = FileManager.default
        guard fm.isWritableFile(atPath: cfg.fillRoot.path) else { throw WipeError.notWritable(cfg.fillRoot.path) }
        let dir = cfg.fillRoot.appendingPathComponent(Self.fillPrefix + UUID().uuidString)
        do { try fm.createDirectory(at: dir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
        catch { throw WipeError.io(error.localizedDescription) }
        defer { try? fm.removeItem(at: dir) }

        reserve = cfg.reserve
        let free0 = freeBytes(dir.path)
        guard free0 > reserve + (64 << 20) else { throw WipeError.noSpace }
        let target0 = free0 - reserve
        let units = cfg.passes.count + (cfg.verify ? 1 : 0)
        prog = WipeProgress(pass: 0, passes: cfg.passes.count, phase: tr("Start"), done: 0,
                            total: target0 * UInt64(units))
        startTime = Date(); winTime = startTime; winBytes = 0; speed = 0
        var written: UInt64 = 0

        for (idx, kind) in cfg.passes.enumerated() {
            try checkCancel()
            prog.pass = idx + 1; prog.verifying = false
            prog.phase = String(format: tr("Przebieg %d/%d: %@"), idx + 1, cfg.passes.count, kind.label)
            prog.passFraction = 0
            report(force: true)
            let free = freeBytes(dir.path)
            let target = free > reserve ? free - reserve : 0
            let seed = UInt64.random(in: .min ... .max)
            let recs = try fillPass(kind, seed: seed, dir: dir, target: target, index: idx)
            written += recs.reduce(0) { $0 + $1.size }
            if cfg.verify && idx == cfg.passes.count - 1 {
                prog.verifying = true; prog.passFraction = 0
                prog.phase = tr("Weryfikacja ostatniego przebiegu")
                report(force: true)
                try verify(kind, seed: seed, recs: recs)
            }
            for r in recs { unlink(r.path) }
        }

        if cfg.scrubMetadata {
            prog.phase = tr("Czyszczenie nazw i metadanych"); prog.passFraction = 0
            report(force: true)
            try scrubMetadata(in: dir)
        }
        prog.done = prog.total; prog.passFraction = 1; prog.phase = tr("Gotowe")
        report(force: true)
        return WipeResult(bytesWritten: written, passes: cfg.passes.count,
                          seconds: Date().timeIntervalSince(startTime), verified: cfg.verify)
    }

    private func checkCancel() throws { if cancelled { throw WipeError.cancelled } }

    private func fillPass(_ kind: PassKind, seed: UInt64, dir: URL, target: UInt64, index: Int) throws -> [FileRec] {
        var recs: [FileRec] = []
        var written: UInt64 = 0, chunk: UInt64 = 0, fileIdx = 0
        var isRand = false
        isRand = gen.prepare(kind)
        func slot(_ c: UInt64) -> Int { isRand ? Int(c % 2) : 0 }
        var pending = isRand ? gen.produce(seed: seed, chunk: 0, slot: 0) : nil
        defer { pending?.waitUntilCompleted() }

        while written < target {
            try checkCancel()
            let path = dir.appendingPathComponent("p\(index)_\(fileIdx)").path
            fileIdx += 1
            let fd = open(path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
            guard fd >= 0 else {
                if errno == ENOSPC { break }
                throw WipeError.io(String(cString: strerror(errno)))
            }
            _ = fcntl(fd, F_NOCACHE, 1)
            let startChunk = chunk
            let fileTarget = min(Self.fileMax, target - written)
            var inFile: UInt64 = 0
            var stop = false
            while inFile < fileTarget {
                if cancelled { close(fd); throw WipeError.cancelled }
                pending?.waitUntilCompleted()
                let n = Int(min(UInt64(ChunkGen.size), fileTarget - inFile))
                let next = isRand ? gen.produce(seed: seed, chunk: chunk + 1, slot: slot(chunk + 1)) : nil
                let ok = writeAll(fd, gen.ptr(slot(chunk)), n)
                pending = next
                if !ok { stop = true; break }
                inFile += UInt64(n); written += UInt64(n); chunk += 1
                add(UInt64(n), passTotal: target, passDone: written)
                // Zabezpieczenie: nie zjadaj rezerwy dla systemu, jeśli ktoś inny zajmuje miejsce.
                if chunk % 16 == 0 && freeBytes(dir.path) < reserve / 2 { stop = true; break }
            }
            _ = fcntl(fd, F_FULLFSYNC)
            close(fd)
            recs.append(FileRec(path: path, size: inFile, startChunk: startChunk))
            if stop { break }
        }
        return recs
    }

    private func verify(_ kind: PassKind, seed: UInt64, recs: [FileRec]) throws {
        var isRand = false
        isRand = gen.prepare(kind)
        func slot(_ c: UInt64) -> Int { isRand ? Int(c % 2) : 0 }
        var rb: UnsafeMutableRawPointer?
        posix_memalign(&rb, 16384, ChunkGen.size)
        guard let buf = rb else { throw WipeError.io(tr("brak pamięci")) }
        defer { free(buf) }
        let totalBytes = recs.reduce(0) { $0 + $1.size }
        var done: UInt64 = 0

        for r in recs where r.size > 0 {
            let fd = open(r.path, O_RDONLY)
            guard fd >= 0 else { throw WipeError.io(tr("nie można otworzyć pliku do weryfikacji")) }
            _ = fcntl(fd, F_NOCACHE, 1)
            var c = r.startChunk, remaining = r.size
            var pending = isRand ? gen.produce(seed: seed, chunk: c, slot: slot(c)) : nil
            defer { pending?.waitUntilCompleted(); close(fd) }
            while remaining > 0 {
                try checkCancel()
                pending?.waitUntilCompleted()
                let n = Int(min(UInt64(ChunkGen.size), remaining))
                let next = isRand ? gen.produce(seed: seed, chunk: c + 1, slot: slot(c + 1)) : nil
                var got = 0
                while got < n {
                    let k = read(fd, buf + got, n - got)
                    if k <= 0 { throw WipeError.verifyFailed(tr("nie można odczytać danych")) }
                    got += k
                }
                pending = next
                if memcmp(buf, gen.ptr(slot(c)), n) != 0 {
                    throw WipeError.verifyFailed(String(format: tr("dane na nośniku różnią się od zapisanych (blok %lld)"), Int64(c)))
                }
                c += 1; remaining -= UInt64(n); done += UInt64(n)
                add(UInt64(n), passTotal: totalBytes, passDone: done)
            }
        }
    }

    /// Tworzy i usuwa wiele plików o losowych, długich nazwach – nadpisuje wpisy katalogów/metadane po usuniętych plikach.
    private func scrubMetadata(in dir: URL) throws {
        let md = dir.appendingPathComponent("meta")
        try? FileManager.default.createDirectory(at: md, withIntermediateDirectories: false)
        let count = 20_000
        let hex = Array("0123456789abcdef")
        for i in 0..<count {
            if i % 512 == 0 { try checkCancel(); prog.passFraction = Double(i) / Double(count); report() }
            var name = ""
            for _ in 0..<120 { name.append(hex[Int.random(in: 0..<16)]) }
            let fd = open(md.appendingPathComponent(name).path, O_WRONLY | O_CREAT, 0o600)
            if fd >= 0 { close(fd) } else if errno == ENOSPC { break }
        }
        try? FileManager.default.removeItem(at: md)
    }

    private func writeAll(_ fd: Int32, _ p: UnsafeRawPointer, _ n: Int) -> Bool {
        var off = 0
        while off < n {
            let k = write(fd, p + off, n - off)
            if k < 0 { if errno == EINTR { continue }; return false }
            off += k
        }
        return true
    }
}
