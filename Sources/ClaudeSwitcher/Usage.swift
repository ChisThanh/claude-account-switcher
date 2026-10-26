import Foundation

/// One plan limit as `claude -p /usage` prints it, e.g.
/// "Current session: 19% used · resets Oct 23 at 4:59pm (Asia/Saigon)".
struct UsageWindow: Codable, Equatable, Identifiable {
    let label: String
    let percent: Int
    let resetsAt: Date?
    let resetText: String?

    var id: String { label }
    static let sessionLabel = "Current session"
    static let weekLabel = "Current week (all models)"

    var title: String {
        switch label {
        case Self.sessionLabel: return L("Phiên 5 giờ", "5-hour session")
        case Self.weekLabel: return L("Tuần · mọi model", "Week · all models")
        default:
            if label.hasPrefix("Current week ("), let open = label.firstIndex(of: "(") {
                return L("Tuần · ", "Week · ") + label[label.index(after: open)...].dropLast()
            }
            return label
        }
    }

    var shortTitle: String {
        switch label {
        case Self.sessionLabel: return L("Phiên", "Session")
        case Self.weekLabel: return L("Tuần", "Week")
        default: return title
        }
    }

    /// Once its reset time has passed the window is empty again, whatever the
    /// snapshot said.
    var currentPercent: Int {
        if let resetsAt, resetsAt <= Date() { return 0 }
        return percent
    }
}

struct UsageSnapshot: Codable, Equatable {
    let fetchedAt: Date
    let windows: [UsageWindow]

    var session: UsageWindow? { windows.first { $0.label == UsageWindow.sessionLabel } }
    var week: UsageWindow? { windows.first { $0.label == UsageWindow.weekLabel } }

    /// How close the account is to being blocked: the fuller of session and week.
    var load: Int {
        let main = [session, week].compactMap { $0?.currentPercent }
        return (main.isEmpty ? windows.map(\.currentPercent) : main).max() ?? 0
    }
}

enum UsageParser {
    private static let line = try! NSRegularExpression(
        pattern: #"^(Current [^:]+):\s+(\d+)% used(?:\s+·\s+resets\s+(.+?))?\s*$"#,
        options: [.anchorsMatchLines])

    static func parse(_ text: String, now: Date = Date()) -> UsageSnapshot? {
        let ns = text as NSString
        var windows: [UsageWindow] = []
        for m in line.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let label = ns.substring(with: m.range(at: 1))
            let percent = Int(ns.substring(with: m.range(at: 2))) ?? 0
            let reset = m.range(at: 3).location == NSNotFound ? nil : ns.substring(with: m.range(at: 3))
            windows.append(UsageWindow(label: label, percent: percent,
                                       resetsAt: reset.flatMap { resetDate($0, now: now) }, resetText: reset))
        }
        return windows.isEmpty ? nil : UsageSnapshot(fetchedAt: now, windows: windows)
    }

    /// "Oct 23 at 4:59pm (Asia/Saigon)", "Oct 24 at 11pm (Asia/Saigon)", or a bare time.
    static func resetDate(_ raw: String, now: Date) -> Date? {
        var text = raw
        var tz = TimeZone.current
        if let r = text.range(of: #"\s*\(([^)]+)\)$"#, options: .regularExpression) {
            let name = text[r].trimmingCharacters(in: CharacterSet(charactersIn: " ()"))
            tz = TimeZone(identifier: name) ?? tz
            text.removeSubrange(r)
        }
        text = text.replacingOccurrences(of: "am", with: "AM").replacingOccurrences(of: "pm", with: "PM")

        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = tz
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz

        let year = cal.component(.year, from: now)
        for fmt in ["MMM d 'at' h:mma", "MMM d 'at' ha", "MMM d"] {
            f.dateFormat = "yyyy " + fmt
            if var d = f.date(from: "\(year) \(text)") {
                if d < now.addingTimeInterval(-2 * 86400) { d = cal.date(byAdding: .year, value: 1, to: d) ?? d }
                return d
            }
        }
        for fmt in ["h:mma", "ha"] {
            f.dateFormat = fmt
            guard let t = f.date(from: text) else { continue }
            let hm = cal.dateComponents([.hour, .minute], from: t)
            guard var d = cal.date(bySettingHour: hm.hour ?? 0, minute: hm.minute ?? 0, second: 0, of: now) else { continue }
            if d < now { d = cal.date(byAdding: .day, value: 1, to: d) ?? d }
            return d
        }
        return nil
    }
}
