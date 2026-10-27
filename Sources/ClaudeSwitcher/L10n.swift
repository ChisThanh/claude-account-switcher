import Foundation

enum AppLanguage: String, CaseIterable, Identifiable {
    case vi, en

    var id: String { rawValue }
    var name: String { self == .vi ? "Tiếng Việt" : "English" }
}

/// Two languages, side by side in code: `L(vietnamese, english)`. The choice
/// is saved in UserDefaults; until one is picked the app is in Vietnamese.
enum L10n {
    private static let key = "language"

    nonisolated(unsafe) static var current: AppLanguage = {
        if let saved = UserDefaults.standard.string(forKey: key), let lang = AppLanguage(rawValue: saved) { return lang }
        return .vi
    }()

    static func set(_ lang: AppLanguage) {
        current = lang
        UserDefaults.standard.set(lang.rawValue, forKey: key)
    }
}

func L(_ vi: String, _ en: String) -> String {
    L10n.current == .vi ? vi : en
}
