import Foundation

/// Autotesty: BlankSpace --selftest   (zapisuje ok. 1–2 GB tymczasowo w katalogu tymczasowym)
enum SelfTest {
    static func run() -> Int32 {
        var failed = 0
        func check(_ name: String, _ ok: Bool, _ extra: String = "") {
            print((ok ? "PASS " : "FAIL ") + name + (extra.isEmpty ? "" : " — " + extra)); if !ok { failed += 1 }
        }
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
        func leftovers() -> Int {
            ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [])
                .filter { $0.hasPrefix(WipeEngine.fillPrefix) }.count
        }
        let free = freeBytes(root.path)

        // 1. pełny cykl: 3 przebiegi + weryfikacja + metadane
        do {
            let cfg = WipeConfig(fillRoot: root, passes: Level.all[2].passes, verify: true,
                                 reserve: free - (200 << 20), scrubMetadata: true)
            let r = try WipeEngine().run(cfg)
            check("wipe 3 przebiegi + weryfikacja", r.bytesWritten > (300 << 20), "\(fmtBytes(r.bytesWritten))")
        } catch { check("wipe 3 przebiegi + weryfikacja", false, error.localizedDescription) }
        check("brak plików tymczasowych po wipe", leftovers() == 0)

        // 2. przerwanie w trakcie sprząta po sobie
        do {
            let eng = WipeEngine()
            let cfg = WipeConfig(fillRoot: root, passes: [.random, .random], verify: true,
                                 reserve: freeBytes(root.path) - (1500 << 20), scrubMetadata: false)
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.6) { eng.cancel() }
            _ = try eng.run(cfg)
            check("przerwanie", false, "run nie został przerwany")
        } catch WipeError.cancelled { check("przerwanie zwraca cancelled", true) }
        catch { check("przerwanie", false, error.localizedDescription) }
        check("brak plików tymczasowych po przerwaniu", leftovers() == 0)

        // 3. odmowa przy zbyt małej ilości miejsca
        do {
            _ = try WipeEngine().run(WipeConfig(fillRoot: root, passes: [.byte(0)], verify: false,
                                                reserve: freeBytes(root.path) + (10 << 30), scrubMetadata: false))
            check("odmowa przy braku miejsca", false)
        } catch WipeError.noSpace { check("odmowa przy braku miejsca", true) }
        catch { check("odmowa przy braku miejsca", false, error.localizedDescription) }

        // 4. shredder: pliki, zagnieżdżony folder, symlink, plik tylko do odczytu
        let t = root.appendingPathComponent("bs-shred-\(UUID().uuidString)")
        let fm = FileManager.default
        try? fm.createDirectory(at: t.appendingPathComponent("sub/deep"), withIntermediateDirectories: true)
        try? Data(repeating: 0x41, count: 5 << 20).write(to: t.appendingPathComponent("a.bin"))
        try? Data("tajne".utf8).write(to: t.appendingPathComponent("sub/deep/b.txt"))
        try? fm.createSymbolicLink(at: t.appendingPathComponent("sub/link"), withDestinationURL: t.appendingPathComponent("a.bin"))
        let ro = t.appendingPathComponent("ro.txt"); try? Data("ro".utf8).write(to: ro)
        chmod(ro.path, 0o400)
        do {
            let s = try FileShredder().shred([t], passes: Level.all[2].passes)
            check("shredder: pliki i foldery usunięte", !fm.fileExists(atPath: t.path) && s.failed.isEmpty,
                  "files=\(s.files) failed=\(s.failed.count)")
        } catch { check("shredder", false, error.localizedDescription) }

        // 4b. Gutmann: 35 przebiegów, wzorce wielobajtowe, parser hex
        check("Gutmann ma 35 przebiegów", Level.gutmann.count == 35)
        check("parseHex", parseHex("DE ad be-ef") == [0xDE, 0xAD, 0xBE, 0xEF])
        do {
            let cfg = WipeConfig(fillRoot: root, passes: [.pattern([0x92, 0x49, 0x24]), .pattern([0xDE, 0xAD])], verify: true,
                                 reserve: freeBytes(root.path) - (120 << 20), scrubMetadata: false)
            let r = try WipeEngine().run(cfg)
            check("wipe wzorcem wielobajtowym + weryfikacja", r.bytesWritten > (100 << 20))
        } catch { check("wipe wzorcem wielobajtowym", false, error.localizedDescription) }

        // 5. ochrona ścieżek
        check("ochrona: /", FileShredder.isProtected(URL(fileURLWithPath: "/")))
        check("ochrona: katalog domowy", FileShredder.isProtected(URL(fileURLWithPath: NSHomeDirectory())))
        check("ochrona: /System/Library", FileShredder.isProtected(URL(fileURLWithPath: "/System/Library")))
        check("brak ochrony: plik tymczasowy", !FileShredder.isProtected(root.appendingPathComponent("x.txt")))
        do { _ = try FileShredder().shred([URL(fileURLWithPath: NSHomeDirectory())], passes: [.byte(0)]); check("shredder odmawia $HOME", false) }
        catch { check("shredder odmawia $HOME", true) }

        print(failed == 0 ? "WSZYSTKIE TESTY OK" : "BŁĘDY: \(failed)")
        return failed == 0 ? 0 : 1
    }
}
