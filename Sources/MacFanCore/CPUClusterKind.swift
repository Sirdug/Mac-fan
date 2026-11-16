import Foundation

/// Names differ between M1 (E/P clusters) and newer chips (named tiers).
public enum CPUClusterKind {
    case efficiency, performance, superCore, unknown

    public init(clusterName: String) {
        let name = clusterName.lowercased()
        if name == "efficiency" || name.hasPrefix("e-cluster") || name.range(of: "^e[0-9]+-cluster", options: .regularExpression) != nil {
            self = .efficiency
        } else if name == "performance" || name.hasPrefix("p-cluster") || name.range(of: "^p[0-9]+-cluster", options: .regularExpression) != nil {
            self = .performance
        } else if name == "super" || name.hasPrefix("s-cluster") {
            self = .superCore
        } else {
            self = .unknown
        }
    }

    public var badge: String {
        switch self {
        case .efficiency: return "E"
        case .performance: return "P"
        case .superCore: return "S"
        case .unknown: return "—"
        }
    }
}
