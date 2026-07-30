import Foundation

enum FALProblemCheck: Equatable, Sendable {
    case queued(position: Int?)
    case inProgress
    case completed
    case failed(message: String)

    var technicalDescription: String {
        switch self {
        case .queued(let position):
            if let position {
                return "FAL status: queued (position \(position))"
            }
            return "FAL status: queued"
        case .inProgress:
            return "FAL status: in progress"
        case .completed:
            return "FAL status: completed successfully"
        case .failed(let message):
            return "FAL result: \(message)"
        }
    }
}

struct FALFailureDiagnosis: Equatable, Sendable {
    let title: String
    let explanation: String
    let recovery: String

    static func make(error: String) -> Self {
        let normalized = error.lowercased()

        if normalized.contains("content_policy_violation")
            || normalized.contains("safety policy") {
            return Self(
                title: "This model rejected the input",
                explanation: "Some model safety policies reject photos of real people, even when you have permission to use them.",
                recovery: "Try Kling v3 or another model, or remove the reference media."
            )
        }

        if normalized.contains("http 401") || normalized.contains("http 403") {
            return Self(
                title: "FAL access was rejected",
                explanation: "The saved API key is invalid or does not have access to this model.",
                recovery: "Open Settings, replace the FAL API key, then try again."
            )
        }

        if normalized.contains("http 429") {
            return Self(
                title: "FAL limit reached",
                explanation: "The account has reached a rate limit or does not have enough balance for this request.",
                recovery: "Check the FAL account balance and limits, then try again."
            )
        }

        if normalized.contains("http 422") {
            return Self(
                title: "The model could not use these settings",
                explanation: "One or more inputs or settings are not supported by the selected model.",
                recovery: "Review the reference media, first and last frames, duration, and resolution."
            )
        }

        if (500...599).contains(where: { normalized.contains("http \($0)") }) {
            return Self(
                title: "FAL is temporarily unavailable",
                explanation: "The provider or selected model returned a server error.",
                recovery: "Try again later or select another model."
            )
        }

        return Self(
            title: "Generation could not be completed",
            explanation: "The provider returned an error for this request.",
            recovery: "Review the technical details below, adjust the input, or try another model."
        )
    }

    static func make(check: FALProblemCheck) -> Self {
        switch check {
        case .queued:
            return Self(
                title: "The request is still queued",
                explanation: "FAL has accepted the request but has not started processing it.",
                recovery: "Wait a moment, then check the problem again."
            )
        case .inProgress:
            return Self(
                title: "The request is still processing",
                explanation: "FAL is currently generating the requested media.",
                recovery: "Wait for the generation to finish, then check again."
            )
        case .completed:
            return Self(
                title: "FAL completed the request",
                explanation: "FAL no longer reports a generation error for this request.",
                recovery: "Use Retry Download if available. Otherwise, run the generation again."
            )
        case .failed(let message):
            return make(error: message)
        }
    }
}
