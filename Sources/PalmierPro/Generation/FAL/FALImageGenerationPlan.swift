import Foundation

struct FALImageGenerationPlan: Identifiable, Sendable {
    let id = UUID()
    let endpoint: String
    let modelName: String
    let input: [String: FALJSONValue]
    let generationInput: GenerationInput
    let numImages: Int
    let estimatedCostMicroUSD: Int
    let folderId: String?
    let replacementClipId: String?

    var estimatedCostLabel: String {
        (Double(estimatedCostMicroUSD) / 1_000_000).formatted(
            .currency(code: "USD").precision(.fractionLength(3))
        )
    }
}

enum FALImageGenerationPlanner {
    static let supportedModelIds = Set([
        "fal-ai/nano-banana-2",
        "openai/gpt-image-2",
        "fal-ai/flux-2",
    ])

    @MainActor
    static func makePlan(
        generationInput: GenerationInput,
        model: ImageModelConfig,
        numImages: Int,
        folderId: String?,
        replacementClipId: String?
    ) throws -> FALImageGenerationPlan {
        guard supportedModelIds.contains(model.id) else {
            throw FALImageGenerationError.unsupportedModel
        }
        let input = try requestInput(
            modelId: model.id,
            prompt: generationInput.prompt,
            aspectRatio: generationInput.aspectRatio,
            resolution: generationInput.resolution,
            quality: generationInput.quality,
            numImages: numImages
        )
        let cost = try estimatedCostMicroUSD(
            modelId: model.id,
            aspectRatio: generationInput.aspectRatio,
            resolution: generationInput.resolution,
            quality: generationInput.quality,
            numImages: numImages
        )
        return FALImageGenerationPlan(
            endpoint: model.id,
            modelName: model.displayName,
            input: input,
            generationInput: generationInput,
            numImages: numImages,
            estimatedCostMicroUSD: cost,
            folderId: folderId,
            replacementClipId: replacementClipId
        )
    }

    static func requestInput(
        modelId: String,
        prompt: String,
        aspectRatio: String,
        resolution: String?,
        quality: String?,
        numImages: Int
    ) throws -> [String: FALJSONValue] {
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw FALImageGenerationError.emptyPrompt
        }
        guard (1...4).contains(numImages) else {
            throw FALImageGenerationError.invalidImageCount
        }

        switch modelId {
        case "fal-ai/nano-banana-2":
            guard let resolution, ["0.5K", "1K", "2K", "4K"].contains(resolution) else {
                throw FALImageGenerationError.invalidSettings
            }
            return [
                "prompt": .string(prompt),
                "num_images": .number(Double(numImages)),
                "aspect_ratio": .string(aspectRatio),
                "resolution": .string(resolution),
                "output_format": .string("jpeg"),
                "limit_generations": .bool(true),
                "enable_web_search": .bool(false),
            ]
        case "openai/gpt-image-2":
            guard let resolution,
                  let dimensions = ImageModelConfig.parseWxH(resolution),
                  let quality,
                  ["low", "medium", "high"].contains(quality) else {
                throw FALImageGenerationError.invalidSettings
            }
            return [
                "prompt": .string(prompt),
                "image_size": .object([
                    "width": .number(Double(dimensions.0)),
                    "height": .number(Double(dimensions.1)),
                ]),
                "quality": .string(quality),
                "num_images": .number(Double(numImages)),
                "output_format": .string("jpeg"),
            ]
        case "fal-ai/flux-2":
            return [
                "prompt": .string(prompt),
                "image_size": .string(try fluxImageSize(for: aspectRatio)),
                "num_images": .number(Double(numImages)),
                "acceleration": .string("regular"),
                "enable_safety_checker": .bool(true),
                "output_format": .string("jpeg"),
            ]
        default:
            throw FALImageGenerationError.unsupportedModel
        }
    }

    static func estimatedCostMicroUSD(
        modelId: String,
        aspectRatio: String,
        resolution: String?,
        quality: String?,
        numImages: Int
    ) throws -> Int {
        guard (1...4).contains(numImages) else {
            throw FALImageGenerationError.invalidImageCount
        }
        let perImage: Int
        switch modelId {
        case "fal-ai/nano-banana-2":
            perImage = switch resolution {
            case "0.5K": 60_000
            case "1K": 80_000
            case "2K": 120_000
            case "4K": 160_000
            default: throw FALImageGenerationError.invalidSettings
            }
        case "openai/gpt-image-2":
            guard let resolution, let quality else {
                throw FALImageGenerationError.invalidSettings
            }
            perImage = try gptImageCost(resolution: resolution, quality: quality)
        case "fal-ai/flux-2":
            let pixels = try fluxPixelCount(for: aspectRatio)
            perImage = Int(ceil(Double(pixels) / 1_000_000 * 12_000))
        default:
            throw FALImageGenerationError.unsupportedModel
        }
        return perImage * numImages
    }

    private static func gptImageCost(resolution: String, quality: String) throws -> Int {
        let values: [String: [String: Int]] = [
            "1024x768": ["low": 5_000, "medium": 37_000, "high": 145_000],
            "1024x1024": ["low": 6_000, "medium": 53_000, "high": 211_000],
            "1024x1536": ["low": 5_000, "medium": 42_000, "high": 165_000],
            "1536x1024": ["low": 5_000, "medium": 42_000, "high": 165_000],
            "1920x1080": ["low": 5_000, "medium": 40_000, "high": 158_000],
            "2560x1440": ["low": 7_000, "medium": 56_000, "high": 222_000],
            "3840x2160": ["low": 12_000, "medium": 101_000, "high": 401_000],
        ]
        guard let cost = values[resolution]?[quality] else {
            throw FALImageGenerationError.invalidSettings
        }
        return cost
    }

    private static func fluxImageSize(for aspectRatio: String) throws -> String {
        switch aspectRatio {
        case "1:1": "square_hd"
        case "4:3": "landscape_4_3"
        case "16:9": "landscape_16_9"
        case "3:4": "portrait_4_3"
        case "9:16": "portrait_16_9"
        default: throw FALImageGenerationError.invalidSettings
        }
    }

    private static func fluxPixelCount(for aspectRatio: String) throws -> Int {
        switch try fluxImageSize(for: aspectRatio) {
        case "square_hd": 1024 * 1024
        case "landscape_4_3", "portrait_4_3": 1024 * 768
        case "landscape_16_9", "portrait_16_9": 1024 * 576
        default: throw FALImageGenerationError.invalidSettings
        }
    }
}

enum FALImageGenerationError: LocalizedError, Equatable {
    case emptyPrompt
    case invalidImageCount
    case invalidSettings
    case unsupportedModel
    case missingImages
    case timedOut

    var errorDescription: String? {
        switch self {
        case .emptyPrompt: "Enter a prompt."
        case .invalidImageCount: "Choose between one and four images."
        case .invalidSettings: "The selected settings are not supported by this fal.ai model."
        case .unsupportedModel: "This fal.ai model is not connected yet."
        case .missingImages: "fal.ai returned no image URLs."
        case .timedOut: "fal.ai generation timed out."
        }
    }
}
