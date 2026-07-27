import Foundation

enum GenerationProvider: String, CaseIterable, Identifiable {
    case palmierCloud
    case fal

    var id: String { rawValue }

    static var defaultProvider: GenerationProvider {
        BackendConfig.palmierCloudAvailable ? .palmierCloud : .fal
    }

    var isAvailable: Bool {
        switch self {
        case .palmierCloud: BackendConfig.palmierCloudAvailable
        case .fal: true
        }
    }

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
        case .palmierCloud where !isAvailable: "Unavailable in this build"
        case .palmierCloud: "Palmier account and credits"
        case .fal: "Bring your own FAL API key"
        }
    }
}
