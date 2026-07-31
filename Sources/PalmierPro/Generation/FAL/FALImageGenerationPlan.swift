import Foundation

struct FALImageGenerationPlan: Identifiable, Sendable {
    let id = UUID()
    let endpoint: String
    let modelName: String
    let input: [String: FALJSONValue]
    let generationInput: GenerationInput
    let numImages: Int
    let referenceFileURLs: [URL]
    let estimatedCostMicroUSD: Int
    let folderId: String?
    let replacementClipId: String?

    var isEditing: Bool { !referenceFileURLs.isEmpty }
    var referenceCount: Int { referenceFileURLs.count }

    var confirmationMessage: String {
        let action = isEditing ? "Edit" : "Generate"
        let imageLabel = "image\(numImages == 1 ? "" : "s")"
        let referenceLabel = isEditing
            ? " from \(referenceCount) reference\(referenceCount == 1 ? "" : "s")"
            : ""
        return "\(modelName) · \(action) \(numImages) \(imageLabel)\(referenceLabel)\n"
            + "Estimated charge: \(estimatedCostLabel). "
            + "Input-dependent charges and fal.ai pricing may change; "
            + "your fal.ai account is billed directly."
    }

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
        references: [MediaAsset],
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
            numImages: numImages,
            isEditing: !references.isEmpty
        )
        let cost = try estimatedCostMicroUSD(
            modelId: model.id,
            aspectRatio: generationInput.aspectRatio,
            resolution: generationInput.resolution,
            quality: generationInput.quality,
            numImages: numImages,
            referenceCount: references.count
        )
        try validateReferenceCount(modelId: model.id, count: references.count)
        return FALImageGenerationPlan(
            endpoint: endpoint(modelId: model.id, isEditing: !references.isEmpty),
            modelName: model.displayName,
            input: input,
            generationInput: generationInput,
            numImages: numImages,
            referenceFileURLs: references.map(\.url),
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
        numImages: Int,
        isEditing: Bool = false,
        referenceURLs: [String] = []
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
            var input: [String: FALJSONValue] = [
                "prompt": .string(prompt),
                "num_images": .number(Double(numImages)),
                "aspect_ratio": .string(aspectRatio),
                "resolution": .string(resolution),
                "output_format": .string("jpeg"),
                "limit_generations": .bool(true),
                "enable_web_search": .bool(false),
            ]
            if isEditing {
                input["image_urls"] = .array(referenceURLs.map(FALJSONValue.string))
            }
            return input
        case "openai/gpt-image-2":
            guard let resolution,
                  let dimensions = ImageModelConfig.parseWxH(resolution),
                  let quality,
                  ["low", "medium", "high"].contains(quality) else {
                throw FALImageGenerationError.invalidSettings
            }
            var input: [String: FALJSONValue] = [
                "prompt": .string(prompt),
                "image_size": .object([
                    "width": .number(Double(dimensions.0)),
                    "height": .number(Double(dimensions.1)),
                ]),
                "quality": .string(quality),
                "num_images": .number(Double(numImages)),
                "output_format": .string("jpeg"),
            ]
            if isEditing {
                input["image_urls"] = .array(referenceURLs.map(FALJSONValue.string))
            }
            return input
        case "fal-ai/flux-2":
            var input: [String: FALJSONValue] = [
                "prompt": .string(prompt),
                "image_size": .string(try fluxImageSize(for: aspectRatio)),
                "num_images": .number(Double(numImages)),
                "acceleration": .string("regular"),
                "enable_safety_checker": .bool(true),
                "output_format": .string("jpeg"),
            ]
            if isEditing {
                input["image_urls"] = .array(referenceURLs.map(FALJSONValue.string))
            }
            return input
        default:
            throw FALImageGenerationError.unsupportedModel
        }
    }

    static func estimatedCostMicroUSD(
        modelId: String,
        aspectRatio: String,
        resolution: String?,
        quality: String?,
        numImages: Int,
        referenceCount: Int = 0
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
            perImage = try gptImageCost(
                resolution: resolution,
                quality: quality,
                isEditing: referenceCount > 0
            )
        case "fal-ai/flux-2":
            let pixels = try fluxPixelCount(for: aspectRatio)
            perImage = Int(ceil(Double(pixels) / 1_000_000 * 12_000))
        default:
            throw FALImageGenerationError.unsupportedModel
        }
        return perImage * numImages
    }

    static func endpoint(modelId: String, isEditing: Bool) -> String {
        isEditing ? "\(modelId)/edit" : modelId
    }

    static func referenceLimit(modelId: String) -> Int {
        switch modelId {
        case "fal-ai/nano-banana-2": 14
        case "openai/gpt-image-2": 16
        case "fal-ai/flux-2": 4
        default: 0
        }
    }

    static func validateReferenceCount(modelId: String, count: Int) throws {
        guard count >= 0, count <= referenceLimit(modelId: modelId) else {
            throw FALImageGenerationError.tooManyReferences(
                maximum: referenceLimit(modelId: modelId)
            )
        }
    }

    private static func gptImageCost(
        resolution: String,
        quality: String,
        isEditing: Bool
    ) throws -> Int {
        let generationValues: [String: [String: Int]] = [
            "1024x768": ["low": 5_000, "medium": 37_000, "high": 145_000],
            "1024x1024": ["low": 6_000, "medium": 53_000, "high": 211_000],
            "1024x1536": ["low": 5_000, "medium": 42_000, "high": 165_000],
            "1536x1024": ["low": 5_000, "medium": 42_000, "high": 165_000],
            "1920x1080": ["low": 5_000, "medium": 40_000, "high": 158_000],
            "2560x1440": ["low": 7_000, "medium": 56_000, "high": 222_000],
            "3840x2160": ["low": 12_000, "medium": 101_000, "high": 401_000],
        ]
        let editValues: [String: [String: Int]] = [
            "1024x768": ["low": 11_000, "medium": 43_000, "high": 151_000],
            "1024x1024": ["low": 15_000, "medium": 61_000, "high": 219_000],
            "1024x1536": ["low": 18_000, "medium": 54_000, "high": 178_000],
            "1536x1024": ["low": 18_000, "medium": 54_000, "high": 178_000],
            "1920x1080": ["low": 17_000, "medium": 53_000, "high": 158_000],
            "2560x1440": ["low": 19_000, "medium": 68_000, "high": 234_000],
            "3840x2160": ["low": 24_000, "medium": 113_000, "high": 413_000],
        ]
        let values = isEditing ? editValues : generationValues
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
    case tooManyReferences(maximum: Int)
    case unreadableReference(String)

    var errorDescription: String? {
        switch self {
        case .emptyPrompt: "Enter a prompt."
        case .invalidImageCount: "Choose between one and four images."
        case .invalidSettings: "The selected settings are not supported by this fal.ai model."
        case .unsupportedModel: "This fal.ai model is not connected yet."
        case .missingImages: "fal.ai returned no image URLs."
        case .timedOut: "fal.ai generation timed out."
        case .tooManyReferences(let maximum):
            "This fal.ai model accepts at most \(maximum) reference images."
        case .unreadableReference(let filename):
            "Could not prepare reference image \(filename) for fal.ai."
        }
    }
}
