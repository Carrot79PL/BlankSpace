import Foundation

func makeReport(volName: String, volPath: String, cfg: WipeConfig, r: WipeResult,
                info i: VolumeInfo?, levelTitle: String, source: String = "ręcznie") -> URL? {
    let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd HH:mm:ss"
    let fdf = DateFormatter(); fdf.dateFormat = "yyyyMMdd-HHmmss"
    var t = "RAPORT CZYSZCZENIA WOLNEGO MIEJSCA — BlankSpace\n"
    t += "Data: \(df.string(from: Date())) (\(source))\nWolumin: \(volName) (\(volPath))\n"
    t += "System plików: \(i?.fs ?? "?"), SSD: \(i?.solidState.map { $0 ? "tak" : "nie" } ?? "?"), FileVault: \(i?.fileVault.map { $0 ? "włączony" : "wyłączony" } ?? "?")\n"
    t += "Lokalne migawki: \(i?.snapshots ?? 0)\n"
    t += "Poziom: \(levelTitle)\nPrzebiegi: \(cfg.passes.count)\n"
    for (n, p) in cfg.passes.enumerated() { t += String(format: "  %2d. %@\n", n + 1, p.label) }
    t += "Weryfikacja odczytem: \(r.verified ? "tak, zakończona powodzeniem" : "nie")\n"
    t += "Czyszczenie metadanych: \(cfg.scrubMetadata ? "tak" : "nie")\nRezerwa systemowa: \(cfg.reserve >> 20) MB\n"
    t += "Zapisano łącznie: \(fmtBytes(r.bytesWritten))\nCzas: \(Int(r.seconds)) s\n\n"
    t += "Uwaga: na SSD nadpisanie nie gwarantuje usunięcia wszystkich kopii (wear-leveling, migawki).\n"
    let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("BlankSpace-raporty")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let u = dir.appendingPathComponent("raport-\(fdf.string(from: Date())).txt")
    return (try? t.write(to: u, atomically: true, encoding: .utf8)) != nil ? u : nil
}
