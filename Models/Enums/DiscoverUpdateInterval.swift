import Foundation

enum DiscoverUpdateInterval: String, CaseIterable, Codable {
    case daily = "Daily"
    case weekly = "Every week"
    case biweekly = "Every 2 weeks"
    case monthly = "Every month"
    
    var displayName: String {
        switch self {
        case .daily: return String(appLocalized: "Daily")
        case .weekly: return String(appLocalized: "Every week")
        case .biweekly: return String(appLocalized: "Every 2 weeks")
        case .monthly: return String(appLocalized: "Every month")
        }
    }
    
    var timeInterval: TimeInterval {
        switch self {
        case .daily: return 86400 // 1 day
        case .weekly: return 604800 // 7 days
        case .biweekly: return 1209600 // 14 days
        case .monthly: return 2592000 // 30 days
        }
    }
}
