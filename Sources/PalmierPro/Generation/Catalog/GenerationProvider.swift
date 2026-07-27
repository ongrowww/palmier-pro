import Foundation

enum GenerationProvider: String, CaseIterable, Identifiable {
    case palmierCloud
    case fal

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .palmierCloud: "Palmier"
        case .fal: "fal.ai"
        }
    }

    var toolbarDisplayName: String {
        switch self {
        case .palmierCloud: displayName
        case .fal: "\(displayName) · BYOK"
        }
    }

    var icon: String {
        switch self {
        case .palmierCloud: "cloud"
        case .fal: "key.horizontal"
        }
    }

    var detail: String {
        switch self {
        case .palmierCloud: "Palmier account and credits"
        case .fal: "Bring your own FAL API key"
        }
    }
}
