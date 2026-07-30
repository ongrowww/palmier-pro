import Foundation

struct FALMediaUpload: Sendable {
    enum Target: Sendable, Equatable {
        case scalar(String)
        case array(String)
    }

    enum Preparation: Sendable {
        case none
        case compressVideo720
        case trimVideo(TrimmedSource)
        case extractAudio(TrimmedSource)
    }

    let fileURL: URL
    let type: ClipType
    let target: Target
    let preparation: Preparation
}

struct FALMediaGenerationPlan: Identifiable, Sendable {
    let id = UUID()
    let endpoint: String
    let modelName: String
    let input: [String: FALJSONValue]
    let uploads: [FALMediaUpload]
    let generationInput: GenerationInput
    let outputType: ClipType
    let placeholderDuration: Double
    let fileExtension: String
    let estimatedCostMicroUSD: Int
    let folderId: String?
    let replacementClipId: String?

    var estimatedCostLabel: String {
        (Double(estimatedCostMicroUSD) / 1_000_000).formatted(
            .currency(code: "USD").precision(.fractionLength(3))
        )
    }

    var confirmationMessage: String {
        "\(modelName) · \(actionLabel)\n"
            + "Estimated charge: \(estimatedCostLabel). "
            + "fal.ai pricing may change; your fal.ai account is billed directly."
    }

    private var actionLabel: String {
        switch outputType {
        case .video: "Generate video"
        case .audio: "Generate audio"
        case .image: "Upscale image"
        case .text, .lottie, .sequence: "Generate media"
        }
    }
}

enum FALGenerationConfirmation: Identifiable {
    case image(FALImageGenerationPlan)
    case media(FALMediaGenerationPlan)

    var id: UUID {
        switch self {
        case .image(let plan): plan.id
        case .media(let plan): plan.id
        }
    }

    var confirmationMessage: String {
        switch self {
        case .image(let plan): plan.confirmationMessage
        case .media(let plan): plan.confirmationMessage
        }
    }

    var estimatedCostLabel: String {
        switch self {
        case .image(let plan): plan.estimatedCostLabel
        case .media(let plan): plan.estimatedCostLabel
        }
    }
}

enum FALMediaGenerationError: LocalizedError, Equatable {
    case emptyPrompt
    case invalidSettings
    case missingSource
    case unsupportedModel
    case missingResult
    case uploadFailed(String)

    var errorDescription: String? {
        switch self {
        case .emptyPrompt: "Enter a prompt."
        case .invalidSettings: "The selected settings are not supported by this fal.ai model."
        case .missingSource: "Add the required source or reference media."
        case .unsupportedModel: "This fal.ai model is not connected yet."
        case .missingResult: "fal.ai returned no usable media URL."
        case .uploadFailed(let filename): "Could not upload \(filename) to fal.ai."
        }
    }
}

enum FALVideoGenerationPlanner {
    static let supportedModelIds = Set([
        "bytedance/seedance-2.0/fast",
        "bytedance/seedance-2.0",
        "fal-ai/kling-video/v3/standard",
        "fal-ai/veo3.1",
    ])

    @MainActor
    static func makePlan(
        generationInput baseInput: GenerationInput,
        model: VideoModelConfig,
        inputAssets: VideoGenerationSubmission.InputAssets,
        generateAudio: Bool,
        folderId: String?,
        replacementClipId: String?
    ) throws -> FALMediaGenerationPlan {
        guard supportedModelIds.contains(model.id) else {
            throw FALMediaGenerationError.unsupportedModel
        }
        let prompt = baseInput.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { throw FALMediaGenerationError.emptyPrompt }

        var generationInput = baseInput
        generationInput.generationProvider = GenerationProvider.fal.rawValue
        generationInput.generateAudio = generateAudio
        generationInput.imageURLAssetIds = inputAssets.frames.isEmpty
            ? nil : inputAssets.frames.map(\.id)
        generationInput.referenceImageAssetIds = inputAssets.imageRefs.isEmpty
            ? nil : inputAssets.imageRefs.map(\.id)
        generationInput.referenceVideoAssetIds = inputAssets.videoRefs.isEmpty
            ? nil : inputAssets.videoRefs.map(\.id)
        generationInput.referenceAudioAssetIds = inputAssets.audioRefs.isEmpty
            ? nil : inputAssets.audioRefs.map(\.id)

        let endpoint: String
        var request: [String: FALJSONValue]
        var uploads: [FALMediaUpload] = []
        let duration = generationInput.duration
        let resolution = generationInput.resolution
        let aspectRatio = generationInput.aspectRatio

        switch model.id {
        case "bytedance/seedance-2.0/fast", "bytedance/seedance-2.0":
            let hasVisualReferences = !inputAssets.imageRefs.isEmpty
                || !inputAssets.videoRefs.isEmpty
            let hasVisualInput = !inputAssets.frames.isEmpty || hasVisualReferences
            let allowedResolutions = model.id.hasSuffix("/fast")
                ? ["480p", "720p"]
                : (hasVisualInput
                    ? ["480p", "720p", "1080p"]
                    : ["480p", "720p", "1080p", "4k"])
            guard (4...15).contains(duration),
                  let resolution,
                  allowedResolutions.contains(resolution),
                  ["auto", "21:9", "16:9", "4:3", "1:1", "3:4", "9:16"].contains(aspectRatio),
                  inputAssets.audioRefs.isEmpty || hasVisualReferences,
                  inputAssets.videoRefs.allSatisfy({ (2...15).contains($0.duration) })
            else { throw FALMediaGenerationError.invalidSettings }

            request = commonVideoInput(
                prompt: prompt,
                duration: "\(duration)",
                resolution: resolution,
                aspectRatio: aspectRatio,
                generateAudio: generateAudio
            )
            if !inputAssets.allRefs.isEmpty {
                endpoint = "\(model.id)/reference-to-video"
                uploads += arrayUploads(inputAssets.imageRefs, key: "image_urls")
                uploads += arrayUploads(
                    inputAssets.videoRefs,
                    key: "video_urls",
                    preparation: .compressVideo720
                )
                uploads += arrayUploads(inputAssets.audioRefs, key: "audio_urls")
            } else if let first = inputAssets.frames.first {
                endpoint = "\(model.id)/image-to-video"
                uploads.append(upload(first, target: .scalar("image_url")))
                if inputAssets.frames.count > 1 {
                    uploads.append(upload(inputAssets.frames[1], target: .scalar("end_image_url")))
                }
            } else {
                endpoint = "\(model.id)/text-to-video"
            }

        case "fal-ai/kling-video/v3/standard":
            guard (3...15).contains(duration),
                  ["16:9", "9:16", "1:1"].contains(aspectRatio),
                  inputAssets.imageRefs.isEmpty,
                  inputAssets.videoRefs.isEmpty,
                  inputAssets.audioRefs.isEmpty
            else { throw FALMediaGenerationError.invalidSettings }
            request = [
                "prompt": .string(prompt),
                "duration": .string("\(duration)"),
                "generate_audio": .bool(generateAudio),
            ]
            if let first = inputAssets.frames.first {
                endpoint = "\(model.id)/image-to-video"
                uploads.append(upload(first, target: .scalar("start_image_url")))
                if inputAssets.frames.count > 1 {
                    uploads.append(upload(inputAssets.frames[1], target: .scalar("end_image_url")))
                }
            } else {
                endpoint = "\(model.id)/text-to-video"
                request["aspect_ratio"] = .string(aspectRatio)
            }

        case "fal-ai/veo3.1":
            guard [4, 6, 8].contains(duration),
                  let resolution,
                  ["720p", "1080p", "4k"].contains(resolution),
                  ["16:9", "9:16"].contains(aspectRatio),
                  inputAssets.frames.count <= 1,
                  inputAssets.allRefs.isEmpty
            else { throw FALMediaGenerationError.invalidSettings }
            request = commonVideoInput(
                prompt: prompt,
                duration: "\(duration)s",
                resolution: resolution,
                aspectRatio: aspectRatio,
                generateAudio: generateAudio
            )
            request["auto_fix"] = .bool(false)
            request["safety_tolerance"] = .string("4")
            if let first = inputAssets.frames.first {
                endpoint = "\(model.id)/image-to-video"
                uploads.append(upload(first, target: .scalar("image_url")))
            } else {
                endpoint = model.id
            }

        default:
            throw FALMediaGenerationError.unsupportedModel
        }

        generationInput.backendEndpoint = endpoint
        return FALMediaGenerationPlan(
            endpoint: endpoint,
            modelName: model.displayName,
            input: request,
            uploads: uploads,
            generationInput: generationInput,
            outputType: .video,
            placeholderDuration: Double(duration),
            fileExtension: "mp4",
            estimatedCostMicroUSD: try estimatedCostMicroUSD(
                modelId: model.id,
                duration: duration,
                resolution: resolution,
                generateAudio: generateAudio,
                hasVideoReference: !inputAssets.videoRefs.isEmpty
            ),
            folderId: folderId,
            replacementClipId: replacementClipId
        )
    }

    static func estimatedCostMicroUSD(
        modelId: String,
        duration: Int,
        resolution: String?,
        generateAudio: Bool,
        hasVideoReference: Bool = false
    ) throws -> Int {
        guard duration > 0 else { throw FALMediaGenerationError.invalidSettings }
        let perSecond: Double
        switch modelId {
        case "bytedance/seedance-2.0/fast", "bytedance/seedance-2.0":
            guard let resolution else { throw FALMediaGenerationError.invalidSettings }
            let workload: (width: Double, height: Double, tokenRate: Double) = switch resolution {
            case "480p":
                (854, 480, modelId.hasSuffix("/fast") ? 0.0112 : 0.014)
            case "720p":
                (1280, 720, modelId.hasSuffix("/fast") ? 0.0112 : 0.014)
            case "1080p" where !modelId.hasSuffix("/fast"):
                (1920, 1080, 0.014)
            case "4k" where !modelId.hasSuffix("/fast"):
                (3840, 2160, 0.008)
            default: throw FALMediaGenerationError.invalidSettings
            }
            perSecond = workload.width * workload.height * 24 / 1024 / 1000
                * workload.tokenRate
                * (hasVideoReference ? 0.6 : 1)
        case "fal-ai/kling-video/v3/standard":
            perSecond = generateAudio ? 0.126 : 0.084
        case "fal-ai/veo3.1":
            guard let resolution else { throw FALMediaGenerationError.invalidSettings }
            if resolution == "4k" {
                perSecond = generateAudio ? 0.60 : 0.40
            } else {
                perSecond = generateAudio ? 0.40 : 0.20
            }
        default:
            throw FALMediaGenerationError.unsupportedModel
        }
        return Int(ceil(perSecond * Double(duration) * 1_000_000))
    }

    private static func commonVideoInput(
        prompt: String,
        duration: String,
        resolution: String,
        aspectRatio: String,
        generateAudio: Bool
    ) -> [String: FALJSONValue] {
        [
            "prompt": .string(prompt),
            "duration": .string(duration),
            "resolution": .string(resolution),
            "aspect_ratio": .string(aspectRatio),
            "generate_audio": .bool(generateAudio),
        ]
    }

    @MainActor
    private static func upload(
        _ asset: MediaAsset,
        target: FALMediaUpload.Target,
        preparation: FALMediaUpload.Preparation = .none
    ) -> FALMediaUpload {
        FALMediaUpload(
            fileURL: asset.url,
            type: asset.type,
            target: target,
            preparation: preparation
        )
    }

    @MainActor
    private static func arrayUploads(
        _ assets: [MediaAsset],
        key: String,
        preparation: FALMediaUpload.Preparation = .none
    ) -> [FALMediaUpload] {
        assets.map { upload($0, target: .array(key), preparation: preparation) }
    }
}

enum FALAudioGenerationPlanner {
    static let supportedModelIds = Set([
        "fal-ai/elevenlabs/tts/eleven-v3",
        "fal-ai/elevenlabs/music",
        "fal-ai/elevenlabs/sound-effects/v2",
        "fal-ai/elevenlabs/audio-isolation",
        "fal-ai/elevenlabs/dubbing",
    ])

    @MainActor
    static func makePlan(
        generationInput baseInput: GenerationInput,
        model: AudioModelConfig,
        source: MediaAsset?,
        duration: Int,
        voice: String?,
        instrumental: Bool,
        targetLanguage: String?,
        trimmedSource: TrimmedSource?,
        folderId: String?,
        replacementClipId: String?
    ) throws -> FALMediaGenerationPlan {
        guard supportedModelIds.contains(model.id) else {
            throw FALMediaGenerationError.unsupportedModel
        }
        let prompt = baseInput.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        var generationInput = baseInput
        generationInput.generationProvider = GenerationProvider.fal.rawValue
        generationInput.audioInput = source.map {
            $0.type == .video ? AudioModelConfig.Input.video.rawValue : AudioModelConfig.Input.audio.rawValue
        } ?? AudioModelConfig.Input.text.rawValue

        var request: [String: FALJSONValue]
        var uploads: [FALMediaUpload] = []
        let outputType: ClipType
        let placeholderDuration: Double
        let fileExtension: String

        switch model.id {
        case "fal-ai/elevenlabs/tts/eleven-v3":
            guard !prompt.isEmpty, let voice, !voice.isEmpty else {
                throw FALMediaGenerationError.invalidSettings
            }
            request = ["text": .string(prompt), "voice": .string(voice)]
            outputType = .audio
            placeholderDuration = AudioGenerationSubmission.placeholderDuration(
                model: model,
                params: AudioGenerationParams(
                    prompt: prompt, voice: voice, lyrics: nil, styleInstructions: nil,
                    instrumental: false, durationSeconds: nil
                )
            )
            fileExtension = "mp3"

        case "fal-ai/elevenlabs/music":
            guard !prompt.isEmpty, (3...600).contains(duration) else {
                throw FALMediaGenerationError.invalidSettings
            }
            request = [
                "prompt": .string(prompt),
                "music_length_ms": .number(Double(duration * 1000)),
                "force_instrumental": .bool(instrumental),
                "output_format": .string("mp3_44100_128"),
            ]
            outputType = .audio
            placeholderDuration = Double(duration)
            fileExtension = "mp3"

        case "fal-ai/elevenlabs/sound-effects/v2":
            guard !prompt.isEmpty, (1...22).contains(duration) else {
                throw FALMediaGenerationError.invalidSettings
            }
            request = [
                "text": .string(prompt),
                "duration_seconds": .number(Double(duration)),
                "output_format": .string("mp3_44100_128"),
            ]
            outputType = .audio
            placeholderDuration = Double(duration)
            fileExtension = "mp3"

        case "fal-ai/elevenlabs/audio-isolation":
            guard let source else { throw FALMediaGenerationError.missingSource }
            request = [:]
            let key = source.type == .video ? "video_url" : "audio_url"
            uploads = [FALMediaUpload(
                fileURL: source.url,
                type: source.type,
                target: .scalar(key),
                preparation: sourcePreparation(source: source, trimmedSource: trimmedSource)
            )]
            generationInput.setAudioSourceAsset(source)
            outputType = .audio
            placeholderDuration = Double(duration)
            fileExtension = "mp3"

        case "fal-ai/elevenlabs/dubbing":
            guard let source, let targetLanguage, !targetLanguage.isEmpty else {
                throw FALMediaGenerationError.missingSource
            }
            request = [
                "target_lang": .string(targetLanguage),
                "highest_resolution": .bool(true),
            ]
            let key = source.type == .video ? "video_url" : "audio_url"
            uploads = [FALMediaUpload(
                fileURL: source.url,
                type: source.type,
                target: .scalar(key),
                preparation: sourcePreparation(source: source, trimmedSource: trimmedSource)
            )]
            generationInput.setAudioSourceAsset(source)
            outputType = source.type == .video ? .video : .audio
            placeholderDuration = Double(duration)
            fileExtension = source.type == .video ? "mp4" : "mp3"

        default:
            throw FALMediaGenerationError.unsupportedModel
        }

        generationInput.backendEndpoint = model.id
        return FALMediaGenerationPlan(
            endpoint: model.id,
            modelName: model.displayName,
            input: request,
            uploads: uploads,
            generationInput: generationInput,
            outputType: outputType,
            placeholderDuration: placeholderDuration,
            fileExtension: fileExtension,
            estimatedCostMicroUSD: try estimatedCostMicroUSD(
                modelId: model.id,
                prompt: prompt,
                duration: duration
            ),
            folderId: folderId,
            replacementClipId: replacementClipId
        )
    }

    static func estimatedCostMicroUSD(
        modelId: String,
        prompt: String,
        duration: Int
    ) throws -> Int {
        switch modelId {
        case "fal-ai/elevenlabs/tts/eleven-v3":
            return Int(ceil(Double(prompt.count) / 1000 * 100_000))
        case "fal-ai/elevenlabs/music":
            return max(1, Int(ceil(Double(duration) / 60))) * 800_000
        case "fal-ai/elevenlabs/sound-effects/v2":
            return duration * 2_000
        case "fal-ai/elevenlabs/audio-isolation":
            return Int(ceil(Double(duration) / 60 * 100_000))
        case "fal-ai/elevenlabs/dubbing":
            return max(1, Int(ceil(Double(duration) / 60))) * 900_000
        default:
            throw FALMediaGenerationError.unsupportedModel
        }
    }

    private static func sourcePreparation(
        source: MediaAsset,
        trimmedSource: TrimmedSource?
    ) -> FALMediaUpload.Preparation {
        guard let trimmedSource, trimmedSource.hasTrim else { return .none }
        return source.type == .video
            ? .trimVideo(trimmedSource)
            : .extractAudio(trimmedSource)
    }
}

enum FALUpscaleGenerationPlanner {
    static let supportedModelIds = Set([
        "fal-ai/topaz/upscale/image",
        "fal-ai/topaz/upscale/video",
        "fal-ai/seedvr/upscale",
    ])

    @MainActor
    static func makePlan(
        generationInput baseInput: GenerationInput,
        model: UpscaleModelConfig,
        source: MediaAsset,
        settings: UpscaleSettings,
        trimmedSource: TrimmedSource?,
        folderId: String?,
        replacementClipId: String?
    ) throws -> FALMediaGenerationPlan {
        guard supportedModelIds.contains(model.id),
              let width = source.sourceWidth,
              let height = source.sourceHeight
        else { throw FALMediaGenerationError.unsupportedModel }

        var generationInput = baseInput
        generationInput.generationProvider = GenerationProvider.fal.rawValue
        generationInput.imageURLAssetIds = [source.id]
        generationInput.upscaleSettings = settings
        generationInput.upscaleSourceWidth = width
        generationInput.upscaleSourceHeight = height
        generationInput.upscaleSourceFPS = source.sourceFPS

        let target = settings.selections["targetResolution"] ?? "4k"
        let targetLongEdge = Double(targetLongEdge(target))
        let factor = min(8, max(1, targetLongEdge / Double(max(width, height))))
        let effectiveDuration = source.type == .image
            ? Defaults.imageDurationSeconds
            : max(1, trimmedSource?.hasTrim == true
                ? trimmedSource?.durationSeconds ?? source.duration
                : source.duration)
        let endpoint: String
        var request: [String: FALJSONValue]

        switch model.id {
        case "fal-ai/topaz/upscale/image":
            guard source.type == .image else { throw FALMediaGenerationError.invalidSettings }
            endpoint = model.id
            request = [
                "model": .string(settings.selections["enhancementModel"] ?? "Standard V2"),
                "upscale_factor": .number(factor),
                "output_format": .string("jpeg"),
            ]
        case "fal-ai/topaz/upscale/video":
            guard source.type == .video else { throw FALMediaGenerationError.invalidSettings }
            endpoint = model.id
            request = [
                "model": .string(settings.selections["enhancementModel"] ?? "Proteus"),
                "upscale_factor": .number(factor),
                "H264_output": .bool(true),
            ]
            if let fps = settings.selections["targetFPS"], fps != "source",
               let value = Double(fps) {
                request["target_fps"] = .number(value)
            }
        case "fal-ai/seedvr/upscale":
            endpoint = source.type == .video ? "\(model.id)/video" : "\(model.id)/image"
            request = [
                "upscale_mode": .string("target"),
                "target_resolution": .string(target == "4k" ? "2160p" : target),
                "noise_scale": .number(0.1),
            ]
            if source.type == .video {
                request["output_format"] = .string("X264 (.mp4)")
                request["output_quality"] = .string("high")
                request["output_write_mode"] = .string("balanced")
            } else {
                request["output_format"] = .string("jpg")
            }
        default:
            throw FALMediaGenerationError.unsupportedModel
        }

        generationInput.backendEndpoint = endpoint
        let sourceKey = source.type == .video ? "video_url" : "image_url"
        return FALMediaGenerationPlan(
            endpoint: endpoint,
            modelName: model.displayName,
            input: request,
            uploads: [FALMediaUpload(
                fileURL: source.url,
                type: source.type,
                target: .scalar(sourceKey),
                preparation: {
                    guard source.type == .video,
                          let trimmedSource,
                          trimmedSource.hasTrim else { return .none }
                    return .trimVideo(trimmedSource)
                }()
            )],
            generationInput: generationInput,
            outputType: source.type,
            placeholderDuration: effectiveDuration,
            fileExtension: source.type == .image ? "jpg" : "mp4",
            estimatedCostMicroUSD: try estimatedCostMicroUSD(
                modelId: model.id,
                sourceType: source.type,
                width: width,
                height: height,
                fps: source.sourceFPS,
                duration: effectiveDuration,
                targetLongEdge: Int(targetLongEdge),
                targetFPS: settings.selections["targetFPS"]
            ),
            folderId: folderId,
            replacementClipId: replacementClipId
        )
    }

    static func estimatedCostMicroUSD(
        modelId: String,
        sourceType: ClipType,
        width: Int,
        height: Int,
        fps: Double?,
        duration: Double,
        targetLongEdge: Int,
        targetFPS: String?
    ) throws -> Int {
        let sourceLong = max(width, height)
        let scale = max(1, Double(targetLongEdge) / Double(sourceLong))
        let outputMegapixels = Double(width) * scale * Double(height) * scale / 1_000_000

        switch modelId {
        case "fal-ai/topaz/upscale/image":
            let cost: Double = switch outputMegapixels {
            case ...24: 0.08
            case ...48: 0.16
            case ...96: 0.32
            default: min(1.36, 0.32 * ceil(outputMegapixels / 96))
            }
            return Int(ceil(cost * 1_000_000))
        case "fal-ai/topaz/upscale/video":
            let rate = targetLongEdge <= 1280 ? 0.01 : targetLongEdge <= 1920 ? 0.02 : 0.08
            let multiplier = targetFPS == "60" ? 2.0 : 1.0
            return Int(ceil(rate * duration * multiplier * 1_000_000))
        case "fal-ai/seedvr/upscale":
            if sourceType == .image {
                return Int(ceil(outputMegapixels * 1_000))
            }
            let frameRate = targetFPS.flatMap(Double.init) ?? fps ?? 30
            return Int(ceil(outputMegapixels * frameRate * duration * 1_000))
        default:
            throw FALMediaGenerationError.unsupportedModel
        }
    }

    static func targetLongEdge(_ value: String) -> Int {
        switch value {
        case "720p": 1280
        case "1080p": 1920
        case "1440p": 2560
        default: 3840
        }
    }
}
