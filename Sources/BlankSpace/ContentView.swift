import SwiftUI

@main
struct BlankSpaceApp: App {
    @StateObject private var model = AppModel()
    init() {
        let a = CommandLine.arguments
        if let i = a.firstIndex(of: "--scheduled"), a.count > i + 3 {
            exit(Scheduler.runScheduled(volume: a[i + 1], levelId: a[i + 2], reserveMB: Int(a[i + 3]) ?? 512))
        }
        if a.contains("--selftest") { exit(SelfTest.run()) }
        // Tryb testowy bez okna: BLANKSPACE_TEST=<MB do zapisania> – uruchamia 3 przebiegi z weryfikacją i kończy.
        if let mb = ProcessInfo.processInfo.environment["BLANKSPACE_TEST"].flatMap({ UInt64($0) }) {
            let root = URL(fileURLWithPath: NSTemporaryDirectory())
            let reserve = freeBytes(root.path) - (mb << 20)
            let eng = WipeEngine()
            eng.onProgress = { p in print(String(format: "%3d%% %@ %.0f MB/s", Int(p.fraction * 100), p.phase, p.speed / 1e6)) }
            let cfg = WipeConfig(fillRoot: root, passes: Level.all[2].passes, verify: true, reserve: reserve, scrubMetadata: true)
            do { let r = try eng.run(cfg); print("OK GPU=\(eng.usesGPU) bytes=\(r.bytesWritten) s=\(r.seconds)") }
            catch { print("FAIL \(error.localizedDescription)") }
            exit(0)
        }
    }
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 820, minHeight: 800)
                .containerBackground(for: .window) {
                    ZStack {
                        LinearGradient(colors: [.blue.opacity(0.35), .purple.opacity(0.28), .pink.opacity(0.22), .orange.opacity(0.15)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing)
                        Rectangle().fill(.thinMaterial)
                    }
                }
                .task { model.refresh() }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        MenuBarExtra {
            MenuBarContent().environmentObject(model)
        } label: { MenuLabel(model: model) }
        .menuBarExtraStyle(.window)
    }
}

extension View {
    func glassCard(selected: Bool = false, radius: CGFloat = 20, tint: Color = .accentColor) -> some View {
        self.padding(14)
            .glassEffect(selected ? .regular.tint(tint.opacity(0.4)).interactive() : .regular,
                         in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

struct ContentView: View {
    @EnvironmentObject var m: AppModel
    @State private var showSchedule = false
    @State private var showAbout = false
    @State private var showSSD = false
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            Group { switch m.phase {
            case .idle: IdleView()
            case .running: RunningView()
            case .done(let s): ResultView(icon: "checkmark.seal.fill", color: .green, title: "Gotowe", text: s)
            case .cancelled: ResultView(icon: "stop.circle.fill", color: .orange, title: "Przerwano",
                                        text: tr("Pliki tymczasowe zostały usunięte. Czyszczenie nie zostało ukończone."))
            case .failed(let e): ResultView(icon: "exclamationmark.triangle.fill", color: .red, title: "Błąd", text: e)
            } }
            .transition(.opacity)
        }
        .animation(.smooth(duration: 0.35), value: m.phase)
        .padding(.horizontal, 28).padding(.top, 36).padding(.bottom, 24)
        .onAppear {
            switch m.debugUI { case "schedule": showSchedule = true; case "about": showAbout = true; case "ssd": showSSD = true; default: break }
        }
        .sheet(isPresented: $showSSD) { SSDGuideView() }
    }

    var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "sparkles.rectangle.stack.fill")
                .font(.system(size: 40)).foregroundStyle(LinearGradient(colors: [.cyan, .blue, .purple, .pink], startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 72, height: 72)
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text("BlankSpace").font(.system(size: 28, weight: .bold, design: .rounded))
                Text("Bezpieczne czyszczenie wolnego miejsca · \(m.gpuName)")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            LanguageMenu()
            Button { showSchedule = true } label: { Image(systemName: m.schedInstalled ? "calendar.badge.checkmark" : "calendar").font(.system(size: 20)) }
                .buttonStyle(.glass).help("Harmonogram")
            Button { showAbout = true } label: { Image(systemName: "info.circle").font(.system(size: 20)) }
                .buttonStyle(.glass).help("O programie")
        }
        .sheet(isPresented: $showSchedule) { ScheduleView().environmentObject(m) }
        .sheet(isPresented: $showAbout) { AboutView() }
    }
}

struct IdleView: View {
    @EnvironmentObject var m: AppModel
    @State private var showSSD = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Picker("", selection: $m.mode) { ForEach(AppModel.Mode.allCases) { Text(LocalizedStringKey($0.rawValue)).tag($0) } }
                .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 380)
            HStack(alignment: .top, spacing: 18) {
                if m.mode == .files { FilesPane() } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Wolumin").font(.headline)
                    ScrollView {
                        VStack(spacing: 8) {
                            ForEach(m.volumes) { v in
                                Button { m.selected = v; m.loadInfo() } label: { VolumeRow(v: v) }
                                    .buttonStyle(.plain)
                            }
                        }.padding(2)
                    }
                    .frame(maxHeight: 230)
                }.frame(maxWidth: .infinity) }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Poziom czyszczenia").font(.headline)
                    VStack(spacing: 8) {
                        ForEach(Level.all) { l in
                            Button { m.level = l } label: { LevelRow(l: l, selected: m.level == l) }
                                .buttonStyle(.plain)
                        }
                    }.padding(2)
                }.frame(maxWidth: .infinity)
            }
            if m.level.id == "custom" {
                HStack(spacing: 18) {
                    Stepper("Przebiegi: \(m.customCount)", value: $m.customCount, in: 1...35)
                    Picker("Wzorzec", selection: $m.customPattern) {
                        ForEach(CustomPattern.allCases) { Text(LocalizedStringKey($0.rawValue)).tag($0) }
                    }.frame(width: 300)
                    if m.customPattern == .hex {
                        TextField("np. DE AD BE EF", text: $m.customHex).textFieldStyle(.roundedBorder).frame(width: 170)
                    }
                    Spacer()
                }.glassCard(radius: 18)
            }
            if m.mode == .space { options; warnings }
            else { Label { Text("Na APFS (copy-on-write) i SSD nadpisanie w miejscu nie gwarantuje zniszczenia starych bloków. Po skasowaniu uruchom czyszczenie wolnego miejsca.").font(.callout) } icon: { Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange) } }
            Spacer(minLength: 0)
            HStack(alignment: .center) {
                if let img = Bundle.main.image(forResource: "podpis_logo") {
                    Image(nsImage: img).resizable().scaledToFit().frame(height: 40).opacity(0.8)
                }
                Spacer()
                Button { m.confirming = true } label: {
                    Label(m.mode == .space ? tr("Rozpocznij czyszczenie") : tr("Zniszcz bezpowrotnie"), systemImage: m.mode == .space ? "play.fill" : "flame.fill").padding(.horizontal, 12).padding(.vertical, 4)
                }
                .buttonStyle(.glassProminent).controlSize(.large)
                .disabled(m.mode == .space ? m.selected == nil : m.shredItems.isEmpty)
            }
        }
        .sheet(isPresented: $showSSD) { SSDGuideView() }
        .alert(m.mode == .space ? tr("Nadpisać wolne miejsce?") : tr("Skasować bezpowrotnie?"), isPresented: $m.confirming) {
            Button(m.mode == .space ? tr("Rozpocznij") : tr("Skasuj"), role: .destructive) { m.mode == .space ? m.start() : m.startShred() }
            Button("Anuluj", role: .cancel) {}
        } message: {
            if m.mode == .files {
                Text("Zostanie bezpowrotnie skasowanych \(m.shredItems.count) pozycji (z zawartością folderów), \(m.passes.count) przebieg(ów). Tego nie można cofnąć.")
            } else if let v = m.selected {
                Text("Wolumin „\(v.name)”: zostanie zapełnione ok. \(fmtBytes(v.free > UInt64(m.reserveMB) << 20 ? v.free - UInt64(m.reserveMB) << 20 : 0)) wolnego miejsca (\(m.passes.count) przebieg(ów)). Istniejące pliki nie są ruszane. Operacja może trwać wiele godzin; nie wyłączaj komputera.")
            }
        }
    }

    var options: some View {
        HStack(spacing: 22) {
            Toggle("Weryfikuj odczytem", isOn: $m.verify).tint(.green)
            Toggle("Czyść nazwy i metadane", isOn: $m.scrub).tint(.teal)
            Spacer()
            Picker("Rezerwa dla systemu", selection: $m.reserveMB) {
                Text("256 MB").tag(256); Text("512 MB").tag(512); Text("1 GB").tag(1024); Text("2 GB").tag(2048)
            }.frame(width: 240)
        }
        .toggleStyle(.switch).glassCard(radius: 18)
    }

    @ViewBuilder var warnings: some View {
        if let i = m.info {
            VStack(alignment: .leading, spacing: 6) {
                if i.solidState == true {
                    HStack {
                        warn("Dysk SSD: wear-leveling i over-provisioning sprawiają, że nadpisanie nie gwarantuje usunięcia każdej kopii danych. Najpewniejsza ochrona to FileVault.", "externaldrive.badge.exclamationmark")
                        Button("Ochrona SSD…") { showSSD = true }.buttonStyle(.glass)
                    }
                }
                if i.snapshots > 0 {
                    HStack {
                        warn("Wykryto \(i.snapshots) lokalnych migawek APFS/Time Machine. Dane w migawkach nie zostaną nadpisane, dopóki migawki nie zostaną usunięte.", "clock.arrow.circlepath")
                        Button("Usuń migawki") { m.deleteSnapshots() }.buttonStyle(.glass)
                    }
                }
                if i.fileVault == false {
                    warn("FileVault jest wyłączony na tym woluminie.", "lock.open")
                }
            }
        }
    }

    func warn(_ t: LocalizedStringKey, _ icon: String) -> some View {
        Label { Text(t).font(.callout).fixedSize(horizontal: false, vertical: true) } icon: { Image(systemName: icon).foregroundStyle(.orange) }
    }
}

struct VolumeRow: View {
    @EnvironmentObject var m: AppModel
    let v: VolumeItem
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: v.isInternal ? "internaldrive.fill" : "externaldrive.fill")
                .font(.system(size: 32)).frame(width: 44).foregroundStyle(v.isInternal ? Color.cyan : Color.teal)
            VStack(alignment: .leading, spacing: 2) {
                Text(v.name).fontWeight(.semibold)
                Text("Wolne: \(fmtBytes(v.free)) z \(fmtBytes(v.total))").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if m.selected?.id == v.id { Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(selected: m.selected?.id == v.id, radius: 16)
    }
}

struct LevelRow: View {
    let l: Level
    let selected: Bool
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: l.symbol).font(.system(size: 28)).frame(width: 44).foregroundStyle(l.color)
            VStack(alignment: .leading, spacing: 2) {
                Text(LocalizedStringKey(l.name)).fontWeight(.semibold)
                Text(LocalizedStringKey(l.detail)).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if selected { Image(systemName: "checkmark.circle.fill").foregroundStyle(l.color) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(selected: selected, radius: 16, tint: l.color)
    }
}

struct RunningView: View {
    @EnvironmentObject var m: AppModel
    var body: some View {
        let p = m.progress
        let eta = p.speed > 1 ? Double(p.total - min(p.done, p.total)) / p.speed : 0
        VStack(spacing: 20) {
            HStack(spacing: 28) {
                ZStack {
                    Circle().stroke(.quaternary, lineWidth: 14)
                    Circle().trim(from: 0, to: p.fraction)
                        .stroke(AngularGradient(colors: [.cyan, .blue, .purple, .pink, .orange, .cyan], center: .center),
                                style: StrokeStyle(lineWidth: 14, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.smooth, value: p.fraction)
                    VStack {
                        Text("\(Int(p.fraction * 100))%").font(.system(size: 44, weight: .bold, design: .rounded))
                            .monospacedDigit()
                        Text(p.verifying ? tr("weryfikacja") : tr("nadpisywanie")).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(width: 190, height: 190)
                VStack(alignment: .leading, spacing: 12) {
                    Text(p.phase).font(.headline)
                    stat("Prędkość", p.speed > 0 ? "\(fmtBytes(UInt64(p.speed)))/s" : "—")
                    stat("Przetworzono", String(format: tr("%@ z %@"), fmtBytes(p.done), fmtBytes(p.total)))
                    stat("Pozostało", eta > 0 ? fmtETA(eta) : "—")
                }
                .glassCard()
                Spacer(minLength: 0)
            }
            BlockMap(fraction: p.passFraction, pass: p.pass, verifying: p.verifying)
                .frame(height: 150).glassCard()
            HStack {
                Text("Nie wyłączaj komputera. Przerwanie bezpiecznie usuwa pliki tymczasowe.")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Przerwij", role: .destructive) { m.cancel() }
                    .buttonStyle(.glass).controlSize(.large)
            }
            Spacer(minLength: 0)
        }
    }

    func stat(_ k: String, _ v: String) -> some View {
        HStack { Text(LocalizedStringKey(k)).foregroundStyle(.secondary).frame(width: 100, alignment: .leading); Text(v).monospacedDigit() }
    }
    func fmtETA(_ s: Double) -> String {
        let t = Int(s); return t >= 3600 ? String(format: "%d h %02d min", t / 3600, t % 3600 / 60)
            : String(format: "%d min %02d s", t / 60, t % 60)
    }
}

struct BlockMap: View {
    let fraction: Double, pass: Int, verifying: Bool
    var body: some View {
        Canvas { ctx, size in
            let cols = 56, rows = 8
            let gap: CGFloat = 3
            let w = (size.width - gap * CGFloat(cols - 1)) / CGFloat(cols)
            let h = (size.height - gap * CGFloat(rows - 1)) / CGFloat(rows)
            let lit = Int(fraction * Double(cols * rows))
            let hue = verifying ? 0.38 : (0.55 + Double(pass) * 0.09).truncatingRemainder(dividingBy: 1)
            for i in 0..<(cols * rows) {
                let r = i / cols, c = i % cols
                let rect = CGRect(x: CGFloat(c) * (w + gap), y: CGFloat(r) * (h + gap), width: w, height: h)
                let color: Color = i < lit ? Color(hue: hue, saturation: 0.6, brightness: 0.95)
                    : (i == lit ? .white.opacity(0.9) : Color.primary.opacity(0.10))
                ctx.fill(Path(roundedRect: rect, cornerRadius: 3), with: .color(color))
            }
        }
    }
}

struct ResultView: View {
    @EnvironmentObject var m: AppModel
    let icon: String, color: Color, title: String, text: String
    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: icon).font(.system(size: 72)).foregroundStyle(color)
            Text(LocalizedStringKey(title)).font(.system(size: 30, weight: .bold, design: .rounded))
            Text(text).multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 520)
            if let u = m.reportURL, title == "Gotowe" {
                Button("Pokaż raport") { NSWorkspace.shared.activateFileViewerSelecting([u]) }.buttonStyle(.glass)
            }
            if m.mode == .space && title == "Gotowe" {
                Button("Powtórz") { m.reset(); m.confirming = true }.buttonStyle(.glass).controlSize(.large)
            }
            Button("Wróć") { m.reset() }.buttonStyle(.glassProminent).controlSize(.large)
            Spacer()
        }.frame(maxWidth: .infinity)
    }
}

struct FilesPane: View {
    @EnvironmentObject var m: AppModel
    @State private var targeted = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Pliki i foldery").font(.headline)
                Spacer()
                Button("Dodaj…") {
                    let p = NSOpenPanel(); p.canChooseFiles = true; p.canChooseDirectories = true
                    p.allowsMultipleSelection = true; p.showsHiddenFiles = true
                    if p.runModal() == .OK { m.addItems(p.urls) }
                }.buttonStyle(.glass)
                if !m.shredItems.isEmpty { Button("Wyczyść listę") { m.shredItems = [] }.buttonStyle(.glass) }
            }
            ScrollView {
                if m.shredItems.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "square.and.arrow.down").font(.system(size: 34))
                        Text("Przeciągnij tutaj pliki lub foldery").foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, minHeight: 190)
                } else {
                    VStack(spacing: 6) {
                        ForEach(m.shredItems, id: \.self) { u in
                            HStack {
                                Image(nsImage: NSWorkspace.shared.icon(forFile: u.path)).resizable().frame(width: 22, height: 22)
                                Text(u.lastPathComponent).lineLimit(1)
                                Spacer()
                                Button { m.shredItems.removeAll { $0 == u } } label: { Image(systemName: "xmark.circle.fill") }
                                    .buttonStyle(.plain).foregroundStyle(.secondary)
                            }.padding(.horizontal, 10).padding(.vertical, 6)
                        }
                    }
                }
            }
            .frame(maxHeight: 230)
            .glassEffect(targeted ? .regular.tint(.red.opacity(0.3)) : .regular, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .dropDestination(for: URL.self) { urls, _ in m.addItems(urls); return true } isTargeted: { targeted = $0 }
        }.frame(maxWidth: .infinity)
    }
}

struct ScheduleView: View {
    @EnvironmentObject var m: AppModel
    @Environment(\.dismiss) var dismiss
    let days = ["Niedziela", "Poniedziałek", "Wtorek", "Środa", "Czwartek", "Piątek", "Sobota"]
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Harmonogram").font(.title2.bold())
            Text("Cykliczne czyszczenie wolnego miejsca przez launchd. Używa wybranego woluminu (\(m.selected?.name ?? "—")) i poziomu „\(m.level.id == "custom" ? tr("Standardowy") : tr(m.level.name))”. Aplikacja musi pozostać w obecnym miejscu, a komputer być włączony o tej porze. Raport trafia do Dokumenty/BlankSpace-raporty.")
                .font(.callout).foregroundStyle(.secondary)
            Picker("Dzień", selection: $m.schedWeekday) { ForEach(0..<7, id: \.self) { Text(LocalizedStringKey(days[$0])).tag($0) } }
            Picker("Godzina", selection: $m.schedHour) { ForEach(0..<24, id: \.self) { Text(String(format: "%02d:00", $0)).tag($0) } }
            Label(m.schedInstalled ? "Harmonogram jest aktywny" : "Harmonogram nieaktywny",
                  systemImage: m.schedInstalled ? "checkmark.circle.fill" : "circle").foregroundStyle(m.schedInstalled ? .green : .secondary)
            HStack {
                Button("Zainstaluj / zaktualizuj") { m.installSchedule() }.buttonStyle(.glassProminent).disabled(m.selected == nil)
                if m.schedInstalled { Button("Usuń") { m.removeSchedule() }.buttonStyle(.glass) }
                Spacer()
                Button("Zamknij") { dismiss() }.buttonStyle(.glass)
            }
        }.padding(24).frame(width: 480)
    }
}

struct AboutView: View {
    @Environment(\.dismiss) var dismiss
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "sparkles.rectangle.stack.fill").font(.system(size: 48)).foregroundStyle(.tint)
            Text("BlankSpace").font(.system(size: 26, weight: .bold, design: .rounded))
            Text("Wersja 1.0.1 · Swift + Metal").foregroundStyle(.secondary)
            Text("Nadpisuje wolne miejsce i niszczy pliki bez możliwości odzyskania. Bez dostępu do sieci. Na SSD i APFS pełną ochronę daje dopiero FileVault.")
                .multilineTextAlignment(.center).font(.callout).frame(maxWidth: 380)
            if let img = Bundle.main.image(forResource: "podpis_logo") {
                Image(nsImage: img).resizable().scaledToFit().frame(height: 50).opacity(0.85)
            }
            Button("Zamknij") { dismiss() }.buttonStyle(.glassProminent)
        }.padding(28).frame(width: 460)
    }
}

struct SSDGuideView: View {
    @Environment(\.dismiss) var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Ochrona danych na SSD").font(.title2.bold())
            Text("Kontroler SSD przenosi dane między komórkami (wear-leveling) i ma ukrytą rezerwę, do której system nie ma dostępu. Dlatego nadpisanie wolnego miejsca zmniejsza ryzyko odzyskania danych, ale go nie eliminuje. Skuteczniejsze są metody kryptograficzne:")
                .font(.callout).foregroundStyle(.secondary)
            Label("Włącz FileVault: dane na dysku są szyfrowane, a po usunięciu klucza nie do odczytu.", systemImage: "lock.fill")
            Label("Przed oddaniem Maca: Ustawienia systemowe → Ogólne → Przenieś lub zresetuj → Skasuj całą zawartość i ustawienia. Usuwa klucz szyfrowania.", systemImage: "arrow.counterclockwise")
            Label("Usuń lokalne migawki (przycisk przy ostrzeżeniu), aby ich dane również zostały nadpisane.", systemImage: "clock.arrow.circlepath")
            Label("Przy dysku zewnętrznym: sformatuj go z szyfrowaniem APFS (Szyfrowany), a potem skasuj — klucz znika razem z woluminem.", systemImage: "externaldrive.fill")
            HStack {
                Button("Otwórz ustawienia FileVault") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension")!)
                }.buttonStyle(.glassProminent)
                Spacer()
                Button("Zamknij") { dismiss() }.buttonStyle(.glass)
            }
        }.padding(24).frame(width: 560)
    }
}

struct LanguageMenu: View {
    @AppStorage("BSLang") private var lang = "system"
    var body: some View {
        Menu {
            ForEach([("system", "System"), ("pl", "Polski"), ("en", "English")], id: \.0) { code, name in
                Button { choose(code) } label: { if lang == code { Label(name, systemImage: "checkmark") } else { Text(name) } }
            }
        } label: { Image(systemName: "globe").font(.system(size: 20)) }
            .menuStyle(.button).buttonStyle(.glass).menuIndicator(.hidden).fixedSize().help("Język / Language")
    }

    /// Język aplikacji wybiera się przy starcie, więc po zmianie uruchamiamy aplikację ponownie.
    private func choose(_ code: String) {
        guard code != lang else { return }
        lang = code
        if code == "system" { UserDefaults.standard.removeObject(forKey: "AppleLanguages") }
        else { UserDefaults.standard.set([code], forKey: "AppleLanguages") }
        UserDefaults.standard.synchronize()
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 0.7; open -n \"\(Bundle.main.bundlePath)\""]
        try? p.run()
        NSApp.terminate(nil)
    }
}

struct MenuLabel: View {
    @ObservedObject var model: AppModel
    var body: some View {
        if model.phase == .running {
            Label("\(Int(model.progress.fraction * 100))%", systemImage: "sparkles")
        } else { Image(systemName: "sparkles") }
    }
}

struct MenuBarContent: View {
    @EnvironmentObject var m: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("BlankSpace").font(.headline)
            if m.phase == .running {
                Text(m.progress.phase).font(.callout).lineLimit(2)
                ProgressView(value: m.progress.fraction)
                HStack {
                    Text(m.progress.speed > 0 ? "\(fmtBytes(UInt64(m.progress.speed)))/s" : "—").monospacedDigit().foregroundStyle(.secondary)
                    Spacer()
                    Button("Przerwij", role: .destructive) { m.cancel() }
                }
            } else {
                Text("Bezczynny").foregroundStyle(.secondary)
            }
            Divider()
            Button("Otwórz BlankSpace") { NSApp.activate(ignoringOtherApps: true); NSApp.windows.first?.makeKeyAndOrderFront(nil) }
            Button("Zakończ") { NSApp.terminate(nil) }
        }.padding(14).frame(width: 260)
    }
}
