import Testing
@testable import PalmierPro

@Suite("FAL failure diagnosis")
struct FALFailureDiagnosisTests {
    @Test func explainsPolicyRejectionAndSuggestsAnotherModel() {
        let diagnosis = FALFailureDiagnosis.make(
            error: "The model rejected this input [content_policy_violation, HTTP 422]"
        )

        #expect(diagnosis.title == "This model rejected the input")
        #expect(diagnosis.explanation.contains("real people"))
        #expect(diagnosis.recovery.contains("Kling v3"))
    }

    @Test func distinguishesCredentialsLimitsValidationAndProviderFailures() {
        #expect(FALFailureDiagnosis.make(error: "failed [HTTP 401]").title
            == "FAL access was rejected")
        #expect(FALFailureDiagnosis.make(error: "failed [HTTP 429]").title
            == "FAL limit reached")
        #expect(FALFailureDiagnosis.make(error: "failed [HTTP 422]").title
            == "The model could not use these settings")
        #expect(FALFailureDiagnosis.make(error: "failed [HTTP 503]").title
            == "FAL is temporarily unavailable")
    }

    @Test func explainsLiveQueueStates() {
        #expect(FALFailureDiagnosis.make(check: .queued(position: 2)).title
            == "The request is still queued")
        #expect(FALFailureDiagnosis.make(check: .inProgress).title
            == "The request is still processing")
        #expect(FALFailureDiagnosis.make(check: .completed).title
            == "FAL completed the request")
        #expect(FALFailureDiagnosis.make(check: .failed(
            message: "Rejected [content_policy_violation, HTTP 422]"
        )).title == "This model rejected the input")
    }
}
