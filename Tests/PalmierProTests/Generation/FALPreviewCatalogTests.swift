import Testing
@testable import PalmierPro

@Suite("FAL provider preview catalog")
@MainActor
struct FALPreviewCatalogTests {
    @Test func offersEveryGenerationType() {
        let catalog = FALPreviewCatalog.shared

        #expect(!catalog.image.isEmpty)
        #expect(!catalog.video.isEmpty)
        #expect(!catalog.audio.isEmpty)
        #expect(!catalog.upscale.isEmpty)
    }

    @Test func exposesTheReferenceAndFrameControlsNeededForVideo() throws {
        let model = try #require(FALPreviewCatalog.shared.video.first {
            $0.id == "bytedance/seedance-2.0/fast"
        })

        #expect(model.supportsFirstFrame)
        #expect(model.supportsLastFrame)
        #expect(model.maxReferenceImages > 0)
        #expect(model.maxReferenceVideos > 0)
        #expect(model.maxReferenceAudios > 0)
    }

    @Test func coversThePlannedAudioWorkflows() {
        let categories = Set(FALPreviewCatalog.shared.audio.map(\.category))

        #expect(categories.contains(.tts))
        #expect(categories.contains(.music))
        #expect(categories.contains(.sfx))
        #expect(categories.contains(.cleanup))
        #expect(categories.contains(.dubbing))
    }

    @Test func connectsEveryAdvertisedFALModel() {
        let catalog = FALPreviewCatalog.shared
        #expect(Set(catalog.video.map(\.id)) == FALVideoGenerationPlanner.supportedModelIds)
        #expect(Set(catalog.audio.map(\.id)) == FALAudioGenerationPlanner.supportedModelIds)
        #expect(Set(catalog.upscale.map(\.id)) == FALUpscaleGenerationPlanner.supportedModelIds)
    }

    @Test func separatesExecutionProviderFromModelVendor() {
        let model = FALPreviewCatalog.shared.image.first {
            $0.id == "fal-ai/nano-banana-2"
        }

        #expect(GenerationProvider.fal.displayName == "fal.ai")
        #expect(GenerationProvider.fal.toolbarDisplayName == "fal.ai · BYOK")
        #expect(model?.entry.providerName == "Google")
    }

    @Test func exposesTheFirstConnectedImageModels() {
        let models = FALPreviewCatalog.shared.image.filter {
            FALImageGenerationPlanner.supportedModelIds.contains($0.id)
        }

        #expect(Set(models.map(\.id)) == [
            "fal-ai/nano-banana-2",
            "openai/gpt-image-2",
            "fal-ai/flux-2",
        ])
        #expect(models.allSatisfy { $0.supportsImageReference })
    }

    @Test func fallsBackToFALWhenPalmierCloudIsUnavailable() {
        #expect(GenerationProvider.palmierCloud.isAvailable == BackendConfig.palmierCloudAvailable)
        if !BackendConfig.palmierCloudAvailable {
            #expect(GenerationProvider.defaultProvider == .fal)
            #expect(GenerationProvider.palmierCloud.detail == "Unavailable in this build")
        }
    }
}
