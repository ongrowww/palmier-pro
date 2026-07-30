import Foundation
import Testing
@testable import PalmierPro

@Suite("FAL media generation planning")
struct FALMediaGenerationPlanTests {
    @Test func pricesVideoModelsUsingPublishedRates() throws {
        #expect(try FALVideoGenerationPlanner.estimatedCostMicroUSD(
            modelId: "fal-ai/kling-video/v3/standard",
            duration: 5,
            resolution: nil,
            generateAudio: false
        ) == 420_000)
        #expect(try FALVideoGenerationPlanner.estimatedCostMicroUSD(
            modelId: "fal-ai/kling-video/v3/standard",
            duration: 5,
            resolution: nil,
            generateAudio: true
        ) == 630_000)
        #expect(try FALVideoGenerationPlanner.estimatedCostMicroUSD(
            modelId: "fal-ai/veo3.1",
            duration: 8,
            resolution: "4k",
            generateAudio: true
        ) == 4_800_000)
    }

    @Test func pricesAudioModelsUsingTheirBillingUnits() throws {
        #expect(try FALAudioGenerationPlanner.estimatedCostMicroUSD(
            modelId: "fal-ai/elevenlabs/tts/eleven-v3",
            prompt: String(repeating: "a", count: 500),
            duration: 0
        ) == 50_000)
        #expect(try FALAudioGenerationPlanner.estimatedCostMicroUSD(
            modelId: "fal-ai/elevenlabs/music",
            prompt: "Ambient",
            duration: 61
        ) == 1_600_000)
        #expect(try FALAudioGenerationPlanner.estimatedCostMicroUSD(
            modelId: "fal-ai/elevenlabs/dubbing",
            prompt: "",
            duration: 61
        ) == 1_800_000)
    }

    @Test func pricesUpscaleModelsFromOutputWorkload() throws {
        #expect(try FALUpscaleGenerationPlanner.estimatedCostMicroUSD(
            modelId: "fal-ai/topaz/upscale/image",
            sourceType: .image,
            width: 1920,
            height: 1080,
            fps: nil,
            duration: 1,
            targetLongEdge: 3840,
            targetFPS: nil
        ) == 80_000)
        #expect(try FALUpscaleGenerationPlanner.estimatedCostMicroUSD(
            modelId: "fal-ai/topaz/upscale/video",
            sourceType: .video,
            width: 1280,
            height: 720,
            fps: 30,
            duration: 10,
            targetLongEdge: 3840,
            targetFPS: "60"
        ) == 1_600_000)
    }

    @Test @MainActor func mapsSeedanceTextAndReferenceEndpoints() throws {
        let model = try #require(FALPreviewCatalog.shared.video.first {
            $0.id == "bytedance/seedance-2.0"
        })
        let input = GenerationInput(
            prompt: "Camera circles the product",
            model: model.id,
            duration: 8,
            aspectRatio: "16:9",
            resolution: "1080p"
        )
        let textPlan = try FALVideoGenerationPlanner.makePlan(
            generationInput: input,
            model: model,
            inputAssets: .init(),
            generateAudio: true,
            folderId: nil,
            replacementClipId: nil
        )
        #expect(textPlan.endpoint == "bytedance/seedance-2.0/text-to-video")
        #expect(textPlan.input["duration"] == .string("8"))
        #expect(textPlan.input["generate_audio"] == .bool(true))

        let image = MediaAsset(
            url: URL(fileURLWithPath: "/tmp/reference.png"),
            type: .image,
            name: "Reference"
        )
        let referencePlan = try FALVideoGenerationPlanner.makePlan(
            generationInput: input,
            model: model,
            inputAssets: .init(imageRefs: [image]),
            generateAudio: false,
            folderId: nil,
            replacementClipId: nil
        )
        #expect(referencePlan.endpoint == "bytedance/seedance-2.0/reference-to-video")
        #expect(referencePlan.uploads.first?.target == .array("image_urls"))
    }

    @Test @MainActor func mapsKlingAndVeoFrameInputs() throws {
        let frame = MediaAsset(
            url: URL(fileURLWithPath: "/tmp/frame.png"),
            type: .image,
            name: "Frame"
        )
        let kling = try #require(FALPreviewCatalog.shared.video.first {
            $0.id == "fal-ai/kling-video/v3/standard"
        })
        let klingPlan = try FALVideoGenerationPlanner.makePlan(
            generationInput: GenerationInput(
                prompt: "The subject looks toward camera",
                model: kling.id,
                duration: 5,
                aspectRatio: "16:9",
                resolution: nil
            ),
            model: kling,
            inputAssets: .init(frames: [frame]),
            generateAudio: true,
            folderId: nil,
            replacementClipId: nil
        )
        #expect(klingPlan.endpoint == "fal-ai/kling-video/v3/standard/image-to-video")
        #expect(klingPlan.uploads.first?.target == .scalar("start_image_url"))
        #expect(klingPlan.input["aspect_ratio"] == nil)

        let veo = try #require(FALPreviewCatalog.shared.video.first {
            $0.id == "fal-ai/veo3.1"
        })
        let veoPlan = try FALVideoGenerationPlanner.makePlan(
            generationInput: GenerationInput(
                prompt: "A slow dolly forward",
                model: veo.id,
                duration: 6,
                aspectRatio: "9:16",
                resolution: "1080p"
            ),
            model: veo,
            inputAssets: .init(frames: [frame]),
            generateAudio: false,
            folderId: nil,
            replacementClipId: nil
        )
        #expect(veoPlan.endpoint == "fal-ai/veo3.1/image-to-video")
        #expect(veoPlan.input["duration"] == .string("6s"))
        #expect(veoPlan.uploads.first?.target == .scalar("image_url"))
    }

    @Test @MainActor func mapsAudioGenerationAndSourceWorkflows() throws {
        let music = try #require(FALPreviewCatalog.shared.audio.first {
            $0.id == "fal-ai/elevenlabs/music"
        })
        let musicPlan = try FALAudioGenerationPlanner.makePlan(
            generationInput: GenerationInput(
                prompt: "Warm electronic instrumental",
                model: music.id,
                duration: 30,
                aspectRatio: "",
                resolution: nil
            ),
            model: music,
            source: nil,
            duration: 30,
            voice: nil,
            instrumental: true,
            targetLanguage: nil,
            trimmedSource: nil,
            folderId: nil,
            replacementClipId: nil
        )
        #expect(musicPlan.input["music_length_ms"] == .number(30_000))
        #expect(musicPlan.input["force_instrumental"] == .bool(true))
        #expect(musicPlan.outputType == .audio)

        let dubbing = try #require(FALPreviewCatalog.shared.audio.first {
            $0.id == "fal-ai/elevenlabs/dubbing"
        })
        let video = MediaAsset(
            url: URL(fileURLWithPath: "/tmp/source.mov"),
            type: .video,
            name: "Source",
            duration: 12
        )
        let dubbingPlan = try FALAudioGenerationPlanner.makePlan(
            generationInput: GenerationInput(
                prompt: "",
                model: dubbing.id,
                duration: 12,
                aspectRatio: "",
                resolution: nil
            ),
            model: dubbing,
            source: video,
            duration: 12,
            voice: nil,
            instrumental: false,
            targetLanguage: "de",
            trimmedSource: nil,
            folderId: nil,
            replacementClipId: nil
        )
        #expect(dubbingPlan.input["target_lang"] == .string("de"))
        #expect(dubbingPlan.uploads.first?.target == .scalar("video_url"))
        #expect(dubbingPlan.outputType == .video)
    }

    @Test @MainActor func mapsTopazAndSeedVRUpscaleInputs() throws {
        let image = MediaAsset(
            url: URL(fileURLWithPath: "/tmp/source.png"),
            type: .image,
            name: "Source",
            duration: 1
        )
        image.sourceWidth = 1024
        image.sourceHeight = 768

        let topaz = try #require(FALPreviewCatalog.shared.upscale.first {
            $0.id == "fal-ai/topaz/upscale/image"
        })
        let topazPlan = try FALUpscaleGenerationPlanner.makePlan(
            generationInput: GenerationInput(
                prompt: "",
                model: topaz.id,
                duration: 1,
                aspectRatio: "",
                resolution: nil
            ),
            model: topaz,
            source: image,
            settings: UpscaleSettings(selections: [
                "enhancementModel": "High Fidelity V2",
                "targetResolution": "4k",
            ]),
            trimmedSource: nil,
            folderId: nil,
            replacementClipId: nil
        )
        #expect(topazPlan.endpoint == "fal-ai/topaz/upscale/image")
        #expect(topazPlan.input["model"] == .string("High Fidelity V2"))
        #expect(topazPlan.uploads.first?.target == .scalar("image_url"))

        let seedVR = try #require(FALPreviewCatalog.shared.upscale.first {
            $0.id == "fal-ai/seedvr/upscale"
        })
        let seedPlan = try FALUpscaleGenerationPlanner.makePlan(
            generationInput: GenerationInput(
                prompt: "",
                model: seedVR.id,
                duration: 1,
                aspectRatio: "",
                resolution: nil
            ),
            model: seedVR,
            source: image,
            settings: UpscaleSettings(selections: ["targetResolution": "1440p"]),
            trimmedSource: nil,
            folderId: nil,
            replacementClipId: nil
        )
        #expect(seedPlan.endpoint == "fal-ai/seedvr/upscale/image")
        #expect(seedPlan.input["target_resolution"] == .string("1440p"))
    }

    @Test @MainActor func rejectsSeedanceAudioWithoutVisualReference() throws {
        let model = try #require(FALPreviewCatalog.shared.video.first {
            $0.id == "bytedance/seedance-2.0"
        })
        let audio = MediaAsset(
            url: URL(fileURLWithPath: "/tmp/reference.mp3"),
            type: .audio,
            name: "Audio",
            duration: 5
        )
        #expect(throws: FALMediaGenerationError.invalidSettings) {
            try FALVideoGenerationPlanner.makePlan(
                generationInput: GenerationInput(
                    prompt: "Follow the rhythm",
                    model: model.id,
                    duration: 5,
                    aspectRatio: "16:9",
                    resolution: "720p"
                ),
                model: model,
                inputAssets: .init(audioRefs: [audio]),
                generateAudio: true,
                folderId: nil,
                replacementClipId: nil
            )
        }
    }

    @Test func extractsVideoAudioAndSingleImageResults() throws {
        let video: FALJSONValue = .object([
            "video": .object(["url": .string("https://v3.fal.media/video.mp4")]),
        ])
        let audio: FALJSONValue = .object([
            "audio": .object(["url": .string("https://v3.fal.media/audio.mp3")]),
        ])
        let image: FALJSONValue = .object([
            "image": .object(["url": .string("https://v3.fal.media/image.jpg")]),
        ])

        #expect(try video.mediaURLs() == ["https://v3.fal.media/video.mp4"])
        #expect(try audio.mediaURLs() == ["https://v3.fal.media/audio.mp3"])
        #expect(try image.mediaURLs() == ["https://v3.fal.media/image.jpg"])
    }
}
