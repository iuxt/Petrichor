import Foundation

enum RepeatMode {
    case off
    case one
    case all

    /// Human-readable description of the current repeat mode, used for control tooltips.
    var tooltip: String {
        switch self {
        case .off: return String(appLocalized: "Repeat: Off")
        case .one: return String(appLocalized: "Repeat: Current Track")
        case .all: return String(appLocalized: "Repeat: All")
        }
    }
}
