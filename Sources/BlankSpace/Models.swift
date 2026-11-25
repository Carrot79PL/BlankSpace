import SwiftUI

enum PassKind: Hashable {
    case byte(UInt8)
    case pattern([UInt8])
    case random
    var label: String {
        switch self {
        case .byte(0): return tr("zera (0x00)")
        case .byte(0xFF): return tr("jedynki (0xFF)")
        case .byte(let b): return String(format: tr("wzorzec 0x%02X"), b)
        case .pattern(let a): return tr("wzorzec ") + a.map { String(format: "%02X", $0) }.joined(separator: " ")
        case .random: return tr("dane losowe (GPU)")
        }
    }
}

struct Level: Identifiable, Hashable {
    let id: String
    let name: String
    let detail: String
    let symbol: String
    let passes: [PassKind]
    let verify: Bool
    var color: Color {
        switch id {
        case "quick": return .mint
        case "standard": return .blue
        case "dod3": return .purple
        case "dod7": return .orange
        case "gutmann": return .red
        default: return .pink
        }
    }

    static let all: [Level] = [
        Level(id: "quick", name: "Szybki", detail: "1 przebieg zerami. Ochrona przed zwykłym odzyskiwaniem.",
              symbol: "hare", passes: [.byte(0)], verify: false),
        Level(id: "standard", name: "Standardowy", detail: "1 przebieg danymi losowymi + weryfikacja.",
              symbol: "shield.lefthalf.filled", passes: [.random], verify: true),
        Level(id: "dod3", name: "DoD 5220.22-M", detail: "3 przebiegi: 0x00, 0xFF, losowe + weryfikacja.",
              symbol: "lock.shield", passes: [.byte(0), .byte(0xFF), .random], verify: true),
        Level(id: "dod7", name: "Rozszerzony", detail: "7 przebiegów (DoD ECE) + weryfikacja. Najdłużej.",
              symbol: "lock.shield.fill",
              passes: [.byte(0), .byte(0xFF), .random, .byte(0), .byte(0xFF), .random, .random], verify: true),
        Level(id: "gutmann", name: "Gutmann (35)", detail: "35 przebiegów (pełna sekwencja). Głównie dla zgodności; na SSD bez sensu i bardzo długo.",
              symbol: "infinity", passes: gutmann, verify: true),
        Level(id: "custom", name: "Własny", detail: "Wybierz liczbę przebiegów i wzorzec.",
              symbol: "slider.horizontal.3", passes: [], verify: true),
    ]

    /// Pełna sekwencja Gutmanna: 4 losowe, 27 wzorców (w tym 3-bajtowe), 4 losowe.
    static let gutmann: [PassKind] = {
        let tri: [[UInt8]] = [[0x92, 0x49, 0x24], [0x49, 0x24, 0x92], [0x24, 0x92, 0x49]]
        let tri2: [[UInt8]] = [[0x6D, 0xB6, 0xDB], [0xB6, 0xDB, 0x6D], [0xDB, 0x6D, 0xB6]]
        var p: [PassKind] = Array(repeating: .random, count: 4)
        p += [.byte(0x55), .byte(0xAA)]
        p += tri.map { .pattern($0) }
        p += stride(from: 0, through: 255, by: 0x11).map { .byte(UInt8($0)) }
        p += tri.map { .pattern($0) }
        p += tri2.map { .pattern($0) }
        p += Array(repeating: .random, count: 4)
        return p
    }()
}

struct WipeProgress {
    var pass = 0
    var passes = 0
    var phase = ""
    var done: UInt64 = 0
    var total: UInt64 = 1
    var speed: Double = 0          // B/s
    var passFraction: Double = 0
    var verifying = false
    var fraction: Double { min(1, Double(done) / Double(max(total, 1))) }
}

struct WipeConfig {
    var fillRoot: URL
    var passes: [PassKind]
    var verify: Bool
    var reserve: UInt64
    var scrubMetadata: Bool
}

struct WipeResult {
    var bytesWritten: UInt64
    var passes: Int
    var seconds: Double
    var verified: Bool
}

enum WipeError: LocalizedError {
    case noSpace, notWritable(String), cancelled, io(String), verifyFailed(String)
    var errorDescription: String? {
        switch self {
        case .noSpace: return tr("Za mało wolnego miejsca do przeprowadzenia czyszczenia.")
        case .notWritable(let p): return String(format: tr("Brak uprawnień zapisu w: %@"), p)
        case .cancelled: return tr("Przerwano przez użytkownika.")
        case .io(let s): return String(format: tr("Błąd wejścia/wyjścia: %@"), s)
        case .verifyFailed(let s): return String(format: tr("Weryfikacja nie powiodła się: %@"), s)
        }
    }
}

func fmtBytes(_ b: UInt64) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(b), countStyle: .file)
}

enum CustomPattern: String, CaseIterable, Identifiable {
    case random = "Losowe (GPU)", hex = "Własny wzorzec hex", zero = "Zera 0x00", ones = "Jedynki 0xFF", alt = "Naprzemienne 0xAA/0x55"
    var id: String { rawValue }
    func passes(_ n: Int, hex: [UInt8] = []) -> [PassKind] {
        (0..<n).map { i in
            switch self {
            case .hex: return hex.isEmpty ? .byte(0) : (hex.count == 1 ? .byte(hex[0]) : .pattern(hex))
            case .random: return .random
            case .zero: return .byte(0)
            case .ones: return .byte(0xFF)
            case .alt: return .byte(i % 2 == 0 ? 0xAA : 0x55)
            }
        }
    }
}

func parseHex(_ t: String) -> [UInt8] {
    let clean = t.filter { $0.isHexDigit }
    var out: [UInt8] = [], i = clean.startIndex
    while clean.distance(from: i, to: clean.endIndex) >= 2 {
        let j = clean.index(i, offsetBy: 2); out.append(UInt8(clean[i..<j], radix: 16)!); i = j
    }
    return Array(out.prefix(16))
}

func tr(_ s: String) -> String { NSLocalizedString(s, comment: "") }
