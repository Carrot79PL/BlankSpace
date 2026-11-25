import Foundation

/// Bezpieczne kasowanie wybranych plików/folderów: nadpisanie w miejscu, obcięcie, zmiana nazwy, usunięcie.
/// UWAGA: na APFS (copy-on-write) stare bloki mogą przetrwać – po kasowaniu uruchom czyszczenie wolnego miejsca.
final class FileShredder {
    struct Summary { var files = 0; var bytes: UInt64 = 0; var failed: [String] = [] }

    var onProgress: ((WipeProgress) -> Void)?
    private let gen = ChunkGen()
    private let lock = NSLock()
    private var _cancel = false
    func cancel() { lock.lock(); _cancel = true; lock.unlock() }
    private var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return _cancel }
    private var prog = WipeProgress()
    private var last = Date.distantPast
    private let start = Date()

    static func isProtected(_ u: URL) -> Bool {
        let p = u.standardizedFileURL.resolvingSymlinksInPath().path
        let h = NSHomeDirectory()
        let exact: Set<String> = ["/", "/Users", "/System", "/Library", "/Applications", "/usr", "/bin", "/sbin",
                                  "/private", "/private/var", "/private/etc", "/Volumes", "/var", "/etc",
                                  h, h + "/Library", h + "/Desktop", h + "/Documents", h + "/Downloads"]
        if exact.contains(p) { return true }
        for pre in ["/System/", "/usr/", "/bin/", "/sbin/", "/Library/", "/private/etc", "/private/var/db"]
        where p.hasPrefix(pre) { return true }
        if p.hasPrefix("/Volumes/") && p.split(separator: "/").count <= 2 { return true }
        return false
    }

    func shred(_ urls: [URL], passes: [PassKind]) throws -> Summary {
        var files: [(String, UInt64)] = [], dirs: [String] = []
        for u in urls {
            if Self.isProtected(u) { throw WipeError.io(String(format: tr("Chroniona ścieżka, nie można skasować: %@"), u.path)) }
            var st = stat()
            guard lstat(u.path, &st) == 0 else { continue }
            if (st.st_mode & S_IFMT) == S_IFDIR {
                dirs.append(u.path)
                if let en = FileManager.default.enumerator(atPath: u.path) {
                    for case let rel as String in en {
                        let p = u.path + "/" + rel
                        var s2 = stat(); guard lstat(p, &s2) == 0 else { continue }
                        if (s2.st_mode & S_IFMT) == S_IFDIR { dirs.append(p) }
                        else { files.append((p, (s2.st_mode & S_IFMT) == S_IFREG ? UInt64(s2.st_size) : 0)) }
                    }
                }
            } else { files.append((u.path, (st.st_mode & S_IFMT) == S_IFREG ? UInt64(st.st_size) : 0)) }
        }
        prog = WipeProgress(pass: 0, passes: passes.count, phase: tr("Kasowanie plików"), done: 0,
                            total: max(1, files.reduce(0) { $0 + $1.1 } * UInt64(passes.count)))
        var sum = Summary()
        for (p, size) in files {
            if cancelled { throw WipeError.cancelled }
            prog.phase = tr("Plik: ") + (p as NSString).lastPathComponent
            if shredFile(p, size: size, passes: passes) { sum.files += 1; sum.bytes += size } else { sum.failed.append(p) }
            if cancelled { throw WipeError.cancelled }
        }
        for d in dirs.sorted(by: { $0.count > $1.count }) { rmdir(d) }
        prog.done = prog.total; prog.phase = tr("Gotowe"); onProgress?(prog)
        return sum
    }

    private func shredFile(_ path: String, size: UInt64, passes: [PassKind]) -> Bool {
        var st = stat()
        guard lstat(path, &st) == 0 else { return false }
        if (st.st_mode & S_IFMT) != S_IFREG { return unlink(path) == 0 }   // symlink itp. – tylko usuń
        chmod(path, 0o600)
        let fd = open(path, O_WRONLY)
        guard fd >= 0 else { return false }
        _ = fcntl(fd, F_NOCACHE, 1)
        var ok = true
        for kind in passes where size > 0 {
            if cancelled { close(fd); return false }
            var isRand = false
            isRand = gen.prepare(kind)
            let seed = UInt64.random(in: .min ... .max)
            lseek(fd, 0, SEEK_SET)
            var off: UInt64 = 0, c: UInt64 = 0
            while off < size {
                let n = Int(min(UInt64(ChunkGen.size), size - off))
                if isRand { gen.produce(seed: seed, chunk: c, slot: 0)?.waitUntilCompleted() }
                var w = 0
                while w < n { let k = write(fd, gen.ptr(0) + w, n - w); if k < 0 { ok = false; break }; w += k }
                if !ok { break }
                off += UInt64(n); c += 1
                prog.done = min(prog.total, prog.done + UInt64(n))
                if Date().timeIntervalSince(last) > 0.1 {
                    last = Date()
                    prog.speed = Double(prog.done) / max(0.001, Date().timeIntervalSince(start))
                    prog.passFraction = Double(off) / Double(size)
                    onProgress?(prog)
                }
            }
            _ = fcntl(fd, F_FULLFSYNC)
        }
        ftruncate(fd, 0)
        close(fd)
        let dir = (path as NSString).deletingLastPathComponent
        let newPath = dir + "/" + String((0..<16).map { _ in "0123456789abcdef".randomElement()! })
        if rename(path, newPath) == 0 { return unlink(newPath) == 0 && ok }
        return unlink(path) == 0 && ok
    }
}
