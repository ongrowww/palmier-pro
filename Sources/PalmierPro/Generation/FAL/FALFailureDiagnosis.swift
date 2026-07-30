import Foundation

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
}
