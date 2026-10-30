import AppKit
import ServiceManagement
import SwiftUI


enum Marks {
    private static var cache: [String: NSImage] = [:]

    static func image(_ v: Vendor) -> NSImage {
        if let i = cache[v.mark] { return i }
        let url = Bundle.main.resourceURL?.appendingPathComponent("marks/\(v.mark).svg")
        let img = url.flatMap { NSImage(contentsOf: $0) } ?? NSImage()
        img.size = NSSize(width: 16, height: 16)
        img.isTemplate = true
        cache[v.mark] = img
        return img
    }
}

extension Color {
    static let claude = Color(red: 0xD9 / 255, green: 0x77 / 255, blue: 0x57 / 255)
    static let hot = Color(nsColor: .systemRed)
    static let geminiGradient = LinearGradient(colors: [Color(red: 0x3D / 255, green: 0x8B / 255, blue: 1),
                                                       Color(red: 0xB0 / 255, green: 0x6B / 255, blue: 0xDB / 255)],
                                              startPoint: .leading, endPoint: .trailing)
}

private let staleAfter: TimeInterval = 45 * 60

private func isStale(_ s: Snapshot?) -> Bool {
    guard let m = s?.measuredAt else { return true }
    return Date().timeIntervalSince(m) > staleAfter
}

private extension TrayStatus {
    var color: Color {
        switch self {
        case .gettingClose: .blue
        case .goodToGo: .green
        case .nearlyExhausted: .hot
        case .unknown: .primary
        }
    }

    var description: String {
        switch self {
        case .gettingClose: "Below 20% remaining"
        case .goodToGo: "At least 20% remaining"
        case .nearlyExhausted: "1% or less remaining"
        case .unknown: "Usage unknown"
        }
    }
}

// MARK: - Tray: provider logos coloured by usage; all window details remain in the panel

struct TrayView: View {
    @ObservedObject var store: Store

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { _ in
            HStack(spacing: 8) {
                ForEach(store.installed, id: \.self) { v in
                    let s = store.snaps[v]
                    let status = s?.trayStatus() ?? .unknown
                    Image(nsImage: Marks.image(v)).renderingMode(.template).resizable()
                        .interpolation(.high).frame(width: 13, height: 13)
                        .foregroundStyle(status.color)
                        .accessibilityLabel(v.name)
                        .accessibilityValue(status.description)
                }
            }
            .padding(.horizontal, 7)
            .frame(height: 22)
            .fixedSize()
        }
    }

}

// MARK: - Panel: 328 pt glass, one section per vendor, bars in brand colours

struct PanelView: View {
    @ObservedObject var store: Store
    var onQuit: () -> Void
    @State private var login = SMAppService.mainApp.status == .enabled

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { _ in
            VStack(spacing: 0) {
                ForEach(Array(store.installed.enumerated()), id: \.element) { i, v in
                    if i > 0 { Hairline() }
                    VendorSection(vendor: v, snap: store.snaps[v], busy: store.busy.contains(v), connectMuse: store.connectMuse)
                }
                let missing = Vendor.activeVendors.filter { !store.installed.contains($0) }
                if !missing.isEmpty {
                    if !store.installed.isEmpty { Hairline() }
                    MissingRow(vendors: missing)
                }
                Hairline()
                footer
            }
            .frame(width: 328)
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            FooterButton(title: store.busy.isEmpty ? "Refresh" : "Refreshing…") { store.refresh(force: true) }
                .disabled(!store.busy.isEmpty)
            Spacer()
            HStack(spacing: 6) {
                Text("Launch at Login").font(.system(size: 12))
                Toggle("", isOn: Binding(get: { login }, set: { on in
                    do {
                        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                    } catch {}
                    login = SMAppService.mainApp.status == .enabled
                })).toggleStyle(.switch).controlSize(.mini).labelsHidden()
            }
            Spacer()
            FooterButton(title: "Quit", action: onQuit)
        }
        .padding(EdgeInsets(top: 6, leading: 8, bottom: 8, trailing: 8))
    }
}

private struct Hairline: View {
    var body: some View { Rectangle().fill(Color.primary.opacity(0.12)).frame(height: 0.5) }
}

private struct FooterButton: View {
    let title: String
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 12)).padding(.horizontal, 6).padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(hover ? 0.1 : 0)))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

private struct VendorSection: View {
    let vendor: Vendor
    let snap: Snapshot?
    let busy: Bool
    let connectMuse: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 8) {
                markView.frame(width: 18, height: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(vendor.name).font(.system(size: 13, weight: .semibold)).tracking(-0.2)
                    Text(planLine).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Text(ageText).font(.system(size: 11)).foregroundStyle(.tertiary).padding(.top, 1)
            }
            let windows = snap?.windows ?? []
            ForEach(Array(windows.enumerated()), id: \.offset) { i, w in
                MeterRow(window: w, vendor: vendor,
                         style: i == 0 ? .primary : (w.label == "5-hour" || w.label == "Week" || vendor == .cursor ? .normal : .quiet))
                    .padding(.top, 7)
                    .opacity(isStale(snap) ? 0.48 : 1)
            }
            if snap?.state == .signedOut {
                Text("Signed out — \(vendor.loginHint)").font(.system(size: 12)).foregroundStyle(.secondary)
                    .textSelection(.enabled).padding(.top, 7)
            } else if Vendor.activeVendors.contains(.muse) && vendor == .muse && (snap?.state == .setup || snap?.state == .permissionNeeded) {
                HStack(spacing: 6) {
                    FooterButton(title: "Connect Muse", action: connectMuse).disabled(busy)
                    if busy { ProgressView().controlSize(.small) }
                }.padding(.top, 7)
            } else if snap?.state == .setup {
                Text("Not set up").font(.system(size: 12)).foregroundStyle(.secondary).padding(.top, 7)
            } else if windows.isEmpty {
                Text(busy ? "Reading…" : "—").font(.system(size: 12)).foregroundStyle(.secondary).padding(.top, 7)
            }
            ForEach(snap?.notes ?? [], id: \.self) { n in
                Text(n).font(.system(size: 11)).foregroundStyle(.tertiary).padding(.top, 6)
            }
            if let e = snap?.error {
                Text(e).font(.system(size: 11)).foregroundStyle(.secondary).padding(.top, 6)
            }
        }
        .padding(EdgeInsets(top: 8, leading: 12, bottom: 9, trailing: 12))
    }

    @ViewBuilder private var markView: some View {
        let img = Image(nsImage: Marks.image(vendor)).renderingMode(.template).resizable().interpolation(.high)
            .frame(width: 16, height: 16)
        switch vendor {
        case .claude: img.foregroundStyle(Color.claude)
        case .gemini: img.foregroundStyle(Color.geminiGradient)
        default: img.foregroundStyle(Color.primary)
        }
    }

    private var planLine: String {
        let plan = snap?.plan ?? ""
        return plan.isEmpty ? vendor.product : "\(vendor.product) · \(plan)"
    }

    private var ageText: String {
        if busy && snap?.measuredAt == nil { return "reading…" }
        guard let m = snap?.measuredAt else { return "" }
        let s = Int(Date().timeIntervalSince(m))
        let t = s < 60 ? "just now" : s < 3600 ? "\(s / 60) min ago" : s < 86400 ? "\(s / 3600) h ago" : "\(s / 86400) d ago"
        return "updated " + t
    }
}

/// CLIs that aren't installed: one quiet line, so the panel says what limitbar can read once they are.
private struct MissingRow: View {
    let vendors: [Vendor]
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Not installed").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            Text(vendors.map { "\($0.name) (\($0.product))" }.joined(separator: " · "))
                .font(.system(size: 11)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(EdgeInsets(top: 8, leading: 12, bottom: 9, trailing: 12))
    }
}

private struct MeterRow: View {
    enum Style { case primary, normal, quiet }
    let window: Window
    let vendor: Vendor
    let style: Style

    var body: some View {
        let due = window.resetPassed
        let hot = !due && (window.used ?? 0) >= 90
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(window.label).lineLimit(1).truncationMode(.tail)
                    .font(.system(size: style == .quiet ? 11 : 12, weight: style == .primary ? .semibold : .regular))
                    .foregroundStyle(style == .quiet ? .secondary : .primary)
                Text(resetText(due)).font(.system(size: 11)).foregroundStyle(due ? .secondary : .tertiary)
            }
            .frame(width: 118, alignment: .leading)
            if !due {
                Track(fraction: (window.used ?? 0) / 100, height: style == .quiet ? 4 : 5, vendor: vendor, hot: hot)
            } else {
                Spacer()
            }
            Text(due || window.used == nil ? "—" : percentText(window.used) + "%")
                .font(.system(size: style == .quiet ? 12 : 13,
                              weight: hot ? .bold : style == .primary ? .semibold : .medium).monospacedDigit())
                .foregroundStyle(hot ? Color.hot : (style == .quiet || due ? Color.secondary : Color.primary))
                .frame(width: 40, alignment: .trailing)
        }
    }

    private func resetText(_ due: Bool) -> String {
        if due { return "reset — awaiting update" }
        // Gemini rows are named after the model group, so the window length goes on this line.
        let kind = vendor == .gemini ? (window.short == "5h" ? "5-hour · " : "week · ") : ""
        guard let r = window.resetsAt else { return kind.isEmpty ? "" : String(kind.dropLast(3)) }
        let f = DateFormatter()
        // Beyond a week (Cursor's billing cycle) a weekday alone would be ambiguous: show the date.
        f.dateFormat = Calendar.current.isDateInToday(r) ? "HH:mm" : r.timeIntervalSinceNow > 7 * 86400 ? "d MMM" : "EEE HH:mm"
        return kind + "resets " + f.string(from: r)
    }
}

private struct Track: View {
    let fraction: Double
    let height: CGFloat
    let vendor: Vendor
    let hot: Bool

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.16))
                fill.frame(width: max(fraction > 0 ? height : 0, g.size.width * min(1, max(0, fraction))))
            }
        }
        .frame(height: height)
    }

    @ViewBuilder private var fill: some View {
        if hot { Capsule().fill(Color.hot) }
        else {
            switch vendor {
            case .claude: Capsule().fill(Color.claude)
            case .gemini: Capsule().fill(Color.geminiGradient)
            default: Capsule().fill(Color.primary)
            }
        }
    }
}


// MARK: - Offscreen preview (`LimitBar --render-preview`, see main.swift)

@MainActor func renderPreview(_ snaps: [Vendor: Snapshot], to path: String, dark: Bool) -> Bool {
    let store = Store(preview: snaps)
    let surface = dark ? Color(white: 0.17) : Color(white: 0.93)       // stands in for the popover glass
    let view = VStack(alignment: .leading, spacing: 12) {
        TrayView(store: store).background(RoundedRectangle(cornerRadius: 5).fill(surface))
        PanelView(store: store, onQuit: {})
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(surface))
    }
    .padding(14)
    .background(dark ? Color(white: 0.08) : Color(white: 0.78))
    .environment(\.colorScheme, dark ? .dark : .light)
    var png: Data?
    NSAppearance(named: dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
        let r = ImageRenderer(content: view)
        r.scale = 2
        if let cg = r.cgImage { png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) }
    }
    guard let data = png else { return false }
    return (try? data.write(to: URL(fileURLWithPath: path))) != nil
}
