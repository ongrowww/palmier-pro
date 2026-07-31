import Foundation

@MainActor
struct FALPreviewCatalog {
    static let shared = FALPreviewCatalog()

    let video: [VideoModelConfig]
    let image: [ImageModelConfig]
    let audio: [AudioModelConfig]
    let upscale: [UpscaleModelConfig]

    private init() {
        let entries = Self.entries
        video = entries.compactMap {
            guard case .video(let caps) = $0.uiCapabilities else { return nil }
            return VideoModelConfig(entry: $0, caps: caps)
        }
        image = entries.compactMap {
            guard case .image(let caps) = $0.uiCapabilities else { return nil }
            return ImageModelConfig(entry: $0, caps: caps)
        }
        audio = entries.compactMap {
            guard case .audio(let caps) = $0.uiCapabilities else { return nil }
            return AudioModelConfig(entry: $0, caps: caps)
        }
        upscale = entries.compactMap {
            guard case .upscale(let caps) = $0.uiCapabilities else { return nil }
            return UpscaleModelConfig(entry: $0, caps: caps)
        }
    }

    private static let entries: [CatalogEntry] = [
        image(
            id: "fal-ai/nano-banana-2",
            name: "Nano Banana 2",
            vendor: "Google",
            endpoints: ["fal-ai/nano-banana-2", "fal-ai/nano-banana-2/edit"],
            resolutions: ["0.5K", "1K", "2K", "4K"],
            aspectRatios: commonImageAspectRatios,
            qualities: nil,
            supportsReferences: true,
            maxImages: 4
        ),
        image(
            id: "openai/gpt-image-2",
            name: "GPT Image 2",
            vendor: "OpenAI",
            endpoints: ["openai/gpt-image-2", "openai/gpt-image-2/edit"],
            resolutions: [
                "1024x768", "1024x1024", "1536x1024", "1024x1536",
                "1920x1080", "2560x1440", "3840x2160",
            ],
            aspectRatios: [],
            qualities: ["low", "medium", "high"],
            supportsReferences: true,
            maxImages: 4
        ),
        image(
            id: "fal-ai/flux-2",
            name: "FLUX.2",
            vendor: "Black Forest Labs",
            endpoints: ["fal-ai/flux-2"],
            resolutions: nil,
            aspectRatios: ["16:9", "4:3", "1:1", "3:4", "9:16"],
            qualities: nil,
            supportsReferences: true,
            maxImages: 4
        ),
        video(
            id: "bytedance/seedance-2.0/fast",
            name: "Seedance 2.0 Fast",
            vendor: "ByteDance",
            endpoints: [
                "bytedance/seedance-2.0/fast/text-to-video",
                "bytedance/seedance-2.0/fast/image-to-video",
                "bytedance/seedance-2.0/fast/reference-to-video",
            ],
            durations: Array(4...15),
            resolutions: ["480p", "720p"],
            aspectRatios: commonVideoAspectRatios,
            firstFrame: true,
            lastFrame: true,
            referenceImages: 9,
            referenceVideos: 3,
            referenceAudios: 3,
            totalReferences: 12,
            exclusiveModes: true
        ),
        video(
            id: "bytedance/seedance-2.0",
            name: "Seedance 2.0",
            vendor: "ByteDance",
            endpoints: [
                "bytedance/seedance-2.0/text-to-video",
                "bytedance/seedance-2.0/image-to-video",
                "bytedance/seedance-2.0/reference-to-video",
            ],
            durations: Array(4...15),
            resolutions: ["480p", "720p", "1080p", "4k"],
            aspectRatios: commonVideoAspectRatios,
            firstFrame: true,
            lastFrame: true,
            referenceImages: 9,
            referenceVideos: 3,
            referenceAudios: 3,
            totalReferences: 12,
            exclusiveModes: true
        ),
        video(
            id: "fal-ai/kling-video/v3/standard",
            name: "Kling 3.0 Standard",
            vendor: "Kuaishou",
            endpoints: [
                "fal-ai/kling-video/v3/standard/text-to-video",
                "fal-ai/kling-video/v3/standard/image-to-video",
            ],
            durations: Array(3...15),
            resolutions: nil,
            aspectRatios: ["16:9", "9:16", "1:1"],
            firstFrame: true,
            lastFrame: true,
            referenceImages: 0,
            referenceVideos: 0,
            referenceAudios: 0,
            totalReferences: 0,
            exclusiveModes: false
        ),
        video(
            id: "fal-ai/veo3.1",
            name: "Veo 3.1",
            vendor: "Google",
            endpoints: ["fal-ai/veo3.1", "fal-ai/veo3.1/image-to-video"],
            durations: [4, 6, 8],
            resolutions: ["720p", "1080p", "4k"],
            aspectRatios: ["16:9", "9:16"],
            firstFrame: true,
            lastFrame: false,
            referenceImages: 0,
            referenceVideos: 0,
            referenceAudios: 0,
            totalReferences: 0,
            exclusiveModes: false
        ),
        audio(
            id: "fal-ai/elevenlabs/tts/eleven-v3",
            name: "ElevenLabs v3 TTS",
            category: "tts",
            endpoints: ["fal-ai/elevenlabs/tts/eleven-v3"],
            voices: ["Rachel", "Aria", "Roger"],
            defaultVoice: "Rachel"
        ),
        audio(
            id: "fal-ai/elevenlabs/music",
            name: "ElevenLabs Music",
            category: "music",
            endpoints: ["fal-ai/elevenlabs/music"],
            supportsInstrumental: true,
            durationRange: AudioDurationRange(minimum: 3, maximum: 600, defaultValue: 30)
        ),
        audio(
            id: "fal-ai/elevenlabs/sound-effects/v2",
            name: "ElevenLabs Sound Effects",
            category: "sfx",
            endpoints: ["fal-ai/elevenlabs/sound-effects/v2"],
            durationRange: AudioDurationRange(minimum: 1, maximum: 22, defaultValue: 5)
        ),
        audio(
            id: "fal-ai/elevenlabs/audio-isolation",
            name: "ElevenLabs Audio Isolation",
            category: "cleanup",
            endpoints: ["fal-ai/elevenlabs/audio-isolation"],
            inputs: ["audio", "video"],
            minPromptLength: 0
        ),
        audio(
            id: "fal-ai/elevenlabs/dubbing",
            name: "ElevenLabs Dubbing",
            category: "dubbing",
            endpoints: ["fal-ai/elevenlabs/dubbing"],
            inputs: ["audio", "video"],
            minPromptLength: 0,
            targetLanguages: [
                "ar", "bg", "zh", "hr", "cs", "da", "nl", "en", "fi", "fr",
                "de", "el", "hi", "hu", "id", "it", "ja", "ko", "ms", "no",
                "pl", "pt", "ro", "ru", "sk", "es", "sv", "ta", "tr", "uk",
            ],
            defaultTargetLanguage: "de"
        ),
        upscale(
            id: "fal-ai/topaz/upscale/image",
            name: "Topaz Image",
            endpoints: ["fal-ai/topaz/upscale/image"],
            supportedTypes: ["image"],
            maximumUpscaleFactor: 8,
            settings: [
                selectSetting(
                    id: "enhancementModel",
                    label: "Enhancement",
                    values: [
                        ("Low Resolution V2", "Low Resolution V2"),
                        ("Standard V2", "Standard V2"),
                        ("High Fidelity V2", "High Fidelity V2"),
                        ("Recovery V2", "Recovery V2"),
                        ("CGI", "CGI"),
                        ("Text Refine", "Text Refine"),
                        ("Recovery", "Recovery"),
                        ("Redefine", "Redefine"),
                        ("Standard MAX", "Standard MAX"),
                        ("Wonder", "Wonder"),
                        ("Wonder 3", "Wonder 3"),
                    ],
                    defaultValue: "Standard V2"
                ),
                selectSetting(
                    id: "targetResolution",
                    label: "Resolution",
                    values: [
                        ("1080p", "1080p"),
                        ("1440p", "1440p"),
                        ("4k", "4K"),
                    ],
                    defaultValue: "4k"
                ),
            ]
        ),
        upscale(
            id: "fal-ai/topaz/upscale/video",
            name: "Topaz Video",
            endpoints: ["fal-ai/topaz/upscale/video"],
            supportedTypes: ["video"],
            maximumUpscaleFactor: 8,
            settings: [
                selectSetting(
                    id: "enhancementModel",
                    label: "Enhancement",
                    values: [
                        ("Proteus", "Proteus"),
                        ("Artemis HQ", "Artemis HQ"),
                        ("Artemis MQ", "Artemis MQ"),
                        ("Artemis LQ", "Artemis LQ"),
                        ("Nyx", "Nyx"),
                        ("Nyx Fast", "Nyx Fast"),
                        ("Nyx XL", "Nyx XL"),
                        ("Nyx HF", "Nyx HF"),
                        ("Gaia HQ", "Gaia HQ"),
                        ("Gaia CG", "Gaia CG"),
                        ("Gaia 2", "Gaia 2"),
                        ("Starlight Precise 2.5", "Starlight Precise 2.5"),
                        ("Starlight HQ", "Starlight HQ"),
                        ("Starlight Mini", "Starlight Mini"),
                        ("Starlight Sharp", "Starlight Sharp"),
                        ("Starlight Fast 2", "Starlight Fast 2"),
                    ],
                    defaultValue: "Proteus"
                ),
                selectSetting(
                    id: "targetResolution",
                    label: "Resolution",
                    values: [
                        ("720p", "720p"),
                        ("1080p", "1080p"),
                        ("1440p", "1440p"),
                        ("4k", "4K"),
                    ],
                    defaultValue: "4k"
                ),
                selectSetting(
                    id: "targetFPS",
                    label: "Frame Rate",
                    values: [("source", "Original"), ("30", "30 FPS"), ("60", "60 FPS")],
                    defaultValue: "source"
                ),
            ]
        ),
        upscale(
            id: "fal-ai/seedvr/upscale",
            name: "SeedVR2",
            endpoints: ["fal-ai/seedvr/upscale/image", "fal-ai/seedvr/upscale/video"],
            supportedTypes: ["image", "video"],
            maximumUpscaleFactor: 10,
            settings: [
                selectSetting(
                    id: "targetResolution",
                    label: "Resolution",
                    values: [
                        ("720p", "720p"),
                        ("1080p", "1080p"),
                        ("1440p", "1440p"),
                        ("4k", "4K"),
                    ],
                    defaultValue: "4k"
                ),
            ]
        ),
    ]

    private static let commonImageAspectRatios = [
        "auto", "21:9", "16:9", "3:2", "4:3", "1:1", "3:4", "2:3", "9:16",
    ]

    private static let commonVideoAspectRatios = ["auto", "21:9", "16:9", "4:3", "1:1", "3:4", "9:16"]

    private static func image(
        id: String,
        name: String,
        vendor: String,
        endpoints: [String],
        resolutions: [String]?,
        aspectRatios: [String],
        qualities: [String]?,
        supportsReferences: Bool,
        maxImages: Int
    ) -> CatalogEntry {
        CatalogEntry(
            id: id,
            kind: .image,
            displayName: name,
            providerName: vendor,
            allowedEndpoints: endpoints,
            responseShape: .images,
            uiCapabilities: .image(ImageCaps(
                resolutions: resolutions,
                aspectRatios: aspectRatios,
                qualities: qualities,
                supportsImageReference: supportsReferences,
                maxImages: maxImages
            )),
            qualities: qualities
        )
    }

    private static func video(
        id: String,
        name: String,
        vendor: String,
        endpoints: [String],
        durations: [Int],
        resolutions: [String]?,
        aspectRatios: [String],
        firstFrame: Bool,
        lastFrame: Bool,
        referenceImages: Int,
        referenceVideos: Int,
        referenceAudios: Int,
        totalReferences: Int,
        exclusiveModes: Bool
    ) -> CatalogEntry {
        CatalogEntry(
            id: id,
            kind: .video,
            displayName: name,
            providerName: vendor,
            allowedEndpoints: endpoints,
            responseShape: .video,
            uiCapabilities: .video(VideoCaps(
                supportsPrompt: true,
                durations: durations,
                resolutions: resolutions,
                aspectRatios: aspectRatios,
                supportsFirstFrame: firstFrame,
                supportsLastFrame: lastFrame,
                maxReferenceImages: referenceImages,
                maxReferenceVideos: referenceVideos,
                maxReferenceAudios: referenceAudios,
                maxTotalReferences: totalReferences,
                maxCombinedVideoRefSeconds: 15,
                maxCombinedAudioRefSeconds: 15,
                framesAndReferencesExclusive: exclusiveModes,
                referenceTagNoun: "Image",
                requiresSourceVideo: false,
                maxSourceVideoSeconds: nil,
                maxSourceVideoResolution: nil,
                requiredSourceVideoEncoding: nil,
                requiresReferenceImage: false,
                requiresReferenceAudio: false
            )),
            audioDiscountRate: ["": 1]
        )
    }

    private static func audio(
        id: String,
        name: String,
        category: String,
        endpoints: [String],
        voices: [String]? = nil,
        defaultVoice: String? = nil,
        supportsInstrumental: Bool = false,
        durationRange: AudioDurationRange? = nil,
        inputs: [String] = ["text"],
        minPromptLength: Int = 1,
        targetLanguages: [String]? = nil,
        defaultTargetLanguage: String? = nil
    ) -> CatalogEntry {
        CatalogEntry(
            id: id,
            kind: .audio,
            displayName: name,
            providerName: "ElevenLabs",
            allowedEndpoints: endpoints,
            responseShape: .audio,
            uiCapabilities: .audio(AudioCaps(
                category: category,
                voices: voices,
                defaultVoice: defaultVoice,
                supportsLyrics: false,
                supportsInstrumental: supportsInstrumental,
                supportsStyleInstructions: false,
                durations: nil,
                durationRange: durationRange,
                minPromptLength: minPromptLength,
                maxReferenceImages: nil,
                maxReferenceAudios: nil,
                maxReferenceAudioSeconds: nil,
                referenceAudioExtensions: nil,
                referenceImagesAndAudiosExclusive: nil,
                supportsMultilingual: nil,
                inputs: inputs,
                promptLabel: nil,
                minSeconds: 1,
                maxSeconds: 600,
                targetLanguages: targetLanguages,
                defaultTargetLanguage: defaultTargetLanguage
            ))
        )
    }

    private static func upscale(
        id: String,
        name: String,
        endpoints: [String],
        supportedTypes: [String],
        maximumUpscaleFactor: Double,
        settings: [UpscaleSelectSetting]
    ) -> CatalogEntry {
        CatalogEntry(
            id: id,
            kind: .upscale,
            displayName: name,
            providerName: id.contains("topaz") ? "Topaz Labs" : "ByteDance",
            allowedEndpoints: endpoints,
            responseShape: .upscaledImage,
            uiCapabilities: .upscale(UpscaleCaps(
                speed: "Medium",
                p75DurationSeconds: 60,
                maximumUpscaleFactor: maximumUpscaleFactor,
                supportedTypes: supportedTypes,
                selectSettings: settings,
                numericSettings: nil,
                toggleSettings: nil
            ))
        )
    }

    private static func selectSetting(
        id: String,
        label: String,
        values: [(String, String)],
        defaultValue: String
    ) -> UpscaleSelectSetting {
        UpscaleSelectSetting(
            id: id,
            label: label,
            options: values.map {
                UpscaleSelectOption(
                    value: $0.0,
                    label: $0.1,
                    description: nil,
                    group: nil,
                    groupDescription: nil
                )
            },
            defaultValue: defaultValue
        )
    }
}
