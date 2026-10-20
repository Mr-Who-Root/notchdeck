import Foundation

/// How long the vault keeps what is dropped in before clearing it by itself.
enum VaultClearAfter: String, CaseIterable, Identifiable {
    case never, hour, day, week

    var id: String { rawValue }

    var interval: TimeInterval? {
        switch self {
        case .never: return nil
        case .hour: return 3600
        case .day: return 86_400
        case .week: return 7 * 86_400
        }
    }

    var title: String {
        switch self {
        case .never: return L10n.t("Never")
        case .hour: return L10n.t("After an hour")
        case .day: return L10n.t("After a day")
        case .week: return L10n.t("After a week")
        }
    }
}
