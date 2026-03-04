import Foundation

public extension PollingInterval {
    var displayName: String {
        switch self {
        case .oneSecond:
            return "1s"
        case .fiveSeconds:
            return "5s"
        case .fifteenSeconds:
            return "15s"
        case .oneMinute:
            return "1m"
        case .none:
            return "None"
        }
    }
}
