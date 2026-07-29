import Foundation
import Testing
@testable import PalmierPro

@Suite("FAL image generation planning")
struct FALImageGenerationPlanTests {
    @Test func mapsNanoBananaSettingsAndPrice() throws {
        let input = try FALImageGenerationPlanner.requestInput(
            modelId: "fal-ai/nano-banana-2",
            prompt: "A bright product photo",
            aspectRatio: "16:9",
            resolution: "1K",
            quality: nil,
            numImages: 2
        )

        #expect(input["aspect_ratio"] == .string("16:9"))
        #expect(input["resolution"] == .string("1K"))
        #expect(input["num_images"] == .number(2))
        #expect(try FALImageGenerationPlanner.estimatedCostMicroUSD(
            modelId: "fal-ai/nano-banana-2",
            aspectRatio: "16:9",
            resolution: "1K",
            quality: nil,
            numImages: 2
        ) == 160_000)
    }

    @Test func mapsGPTImageSizeQualityAndPrice() throws {
        let input = try FALImageGenerationPlanner.requestInput(
            modelId: "openai/gpt-image-2",
            prompt: "A clean editorial illustration",
            aspectRatio: "1:1",
            resolution: "1024x1024",
            quality: "high",
            numImages: 1
        )

        #expect(input["image_size"] == .object([
            "width": .number(1024),
            "height": .number(1024),
        ]))
        #expect(input["quality"] == .string("high"))
        #expect(try FALImageGenerationPlanner.estimatedCostMicroUSD(
            modelId: "openai/gpt-image-2",
            aspectRatio: "1:1",
            resolution: "1024x1024",
            quality: "high",
            numImages: 1
        ) == 211_000)
    }

    @Test func mapsFluxAspectRatioAndMegapixelPrice() throws {
        let input = try FALImageGenerationPlanner.requestInput(
            modelId: "fal-ai/flux-2",
            prompt: "A cinematic landscape",
            aspectRatio: "16:9",
            resolution: nil,
            quality: nil,
            numImages: 1
        )

        #expect(input["image_size"] == .string("landscape_16_9"))
        #expect(try FALImageGenerationPlanner.estimatedCostMicroUSD(
            modelId: "fal-ai/flux-2",
            aspectRatio: "16:9",
            resolution: nil,
            quality: nil,
            numImages: 1
        ) == 7_078)
    }

    @Test func mapsReferenceImagesToEditEndpoints() throws {
        let references = [
            "data:image/jpeg;base64,b25l",
            "data:image/png;base64,dHdv",
        ]
        let nanoInput = try FALImageGenerationPlanner.requestInput(
            modelId: "fal-ai/nano-banana-2",
            prompt: "Combine these references",
            aspectRatio: "1:1",
            resolution: "1K",
            quality: nil,
            numImages: 1,
            isEditing: true,
            referenceURLs: references
        )

        #expect(nanoInput["image_urls"] == .array(references.map(FALJSONValue.string)))
        #expect(FALImageGenerationPlanner.endpoint(
            modelId: "fal-ai/nano-banana-2",
            isEditing: true
        ) == "fal-ai/nano-banana-2/edit")
        #expect(FALImageGenerationPlanner.endpoint(
            modelId: "openai/gpt-image-2",
            isEditing: true
        ) == "openai/gpt-image-2/edit")
        #expect(FALImageGenerationPlanner.endpoint(
            modelId: "fal-ai/flux-2",
            isEditing: true
        ) == "fal-ai/flux-2/edit")
    }

    @Test func usesGPTImageEditPricingWhenReferencesArePresent() throws {
        #expect(try FALImageGenerationPlanner.estimatedCostMicroUSD(
            modelId: "openai/gpt-image-2",
            aspectRatio: "1:1",
            resolution: "1024x1024",
            quality: "high",
            numImages: 1,
            referenceCount: 1
        ) == 219_000)
    }

    @Test func enforcesPublishedReferenceLimits() throws {
        #expect(throws: FALImageGenerationError.tooManyReferences(maximum: 4)) {
            try FALImageGenerationPlanner.validateReferenceCount(
                modelId: "fal-ai/flux-2",
                count: 5
            )
        }
        try FALImageGenerationPlanner.validateReferenceCount(
            modelId: "fal-ai/nano-banana-2",
            count: 14
        )
    }

    @Test func rejectsUnsupportedCountsAndSettings() {
        #expect(throws: FALImageGenerationError.invalidImageCount) {
            try FALImageGenerationPlanner.requestInput(
                modelId: "fal-ai/flux-2",
                prompt: "Test",
                aspectRatio: "1:1",
                resolution: nil,
                quality: nil,
                numImages: 5
            )
        }
        #expect(throws: FALImageGenerationError.invalidSettings) {
            try FALImageGenerationPlanner.requestInput(
                modelId: "fal-ai/nano-banana-2",
                prompt: "Test",
                aspectRatio: "1:1",
                resolution: "8K",
                quality: nil,
                numImages: 1
            )
        }
    }

    @Test func extractsImageURLsFromQueueResult() throws {
        let result: FALJSONValue = .object([
            "images": .array([
                .object(["url": .string("https://fal.media/one.jpg")]),
                .object(["url": .string("https://fal.media/two.jpg")]),
            ]),
        ])

        #expect(try result.imageURLs() == [
            "https://fal.media/one.jpg",
            "https://fal.media/two.jpg",
        ])
    }
}
