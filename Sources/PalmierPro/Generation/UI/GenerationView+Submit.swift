import SwiftUI

// Cost estimation, preflight validation, submission, and panel seeding/reset.
extension GenerationView {

    var canSubmit: Bool {
        guard canAffordGeneration else { return false }
        if selectedType == .upscale {
            guard let source = upscaleSource,
                  source.sourceWidth != nil, source.sourceHeight != nil,
                  source.type != .video || source.sourceFPS != nil,
                  enabledUpscaleModels.contains(where: { $0.index == selectedUpscaleModelIndex }) else { return false }
            return upscaleModel.selectSettings.allSatisfy { setting in
                let value = upscaleSettings.selections[setting.id] ?? setting.defaultValue
                return availableUpscaleOptions(setting).contains(where: { $0.value == value })
            }
        }
        if selectedType == .video && videoModel.requiresSourceVideo {
            guard sourceVideo != nil else { return false }
            if videoModel.requiresReferenceImage && imageReferences.isEmpty { return false }
            if !videoModel.supportsReferences && isPromptEmpty { return false }
            return true
        }
        if selectedType == .video && videoModel.framesAndReferencesExclusive
            && framesRefsMode == .reference && refImages.isEmpty
            && refVideos.isEmpty && refAudios.isEmpty {
            return false
        }
        if selectedType == .audio {
            if audioUsesSource {
                guard audioSource != nil else { return false }
                guard let languages = audioModel.targetLanguages else { return true }
                return languages.contains(selectedTargetLanguage)
            }
            return trimmedPrompt.count >= max(1, audioModel.minPromptLength)
        }
        return !isPromptEmpty
    }

    /// Live credit estimate for the current form state.
    private var estimatedCost: Int? {
        switch selectedType {
        case .video:
            return CostEstimator.videoCost(
                model: videoModel,
                durationSeconds: effectiveVideoSeconds,
                resolution: effectiveResolution,
                generateAudio: effectiveGenerateAudio
            )
        case .image:
            let quality = imageModel.qualities != nil ? selectedQuality : nil
            return CostEstimator.imageCost(
                model: imageModel,
                resolution: effectiveResolution,
                quality: quality,
                numImages: selectedNumImages
            )
        case .audio:
            let duration: Int? = audioUsesSource
                ? (audioSource == nil ? nil : effectiveAudioSourceSeconds)
                : (audioModel.hasDurationControl ? selectedAudioDuration : nil)
            return CostEstimator.audioCost(
                model: audioModel,
                prompt: trimmedPrompt,
                durationSeconds: duration,
                input: activeAudioInput
            )
        case .upscale:
            return CostEstimator.upscaleCost(
                model: upscaleModel,
                durationSeconds: effectiveUpscaleSeconds,
                settings: upscaleSettings,
                sourceWidth: upscaleSource?.sourceWidth,
                sourceHeight: upscaleSource?.sourceHeight,
                sourceFPS: upscaleSource?.sourceFPS
            )
        }
    }

    private var remainingCredits: Int? {
        guard selectedProvider == .palmierCloud else { return nil }
        guard let budget = AccountService.shared.budgetCredits else { return nil }
        return max(0, budget - AccountService.shared.spentCredits)
    }

    private var hasInsufficientCredits: Bool {
        guard let cost = estimatedCost, let left = remainingCredits else { return false }
        return cost > left
    }

    private var canAffordGeneration: Bool {
        guard let left = remainingCredits else { return true }
        if let cost = estimatedCost { return cost <= left }
        return left > 0
    }

    private var estimatedFALCostMicroUSD: Int? {
        guard selectedProvider == .fal else { return nil }
        switch selectedType {
        case .image:
            let imageCount = imageModel.maxImages > 1
                ? min(imageModel.maxImages, max(1, selectedNumImages)) : 1
            return try? FALImageGenerationPlanner.estimatedCostMicroUSD(
                modelId: imageModel.id,
                aspectRatio: selectedAspectRatio,
                resolution: effectiveResolution,
                quality: imageModel.qualities != nil ? selectedQuality : nil,
                numImages: imageCount,
                referenceCount: imageReferences.count
            )
        case .video:
            return try? FALVideoGenerationPlanner.estimatedCostMicroUSD(
                modelId: videoModel.id,
                duration: effectiveVideoSeconds,
                resolution: effectiveResolution,
                generateAudio: effectiveGenerateAudio,
                hasVideoReference: !refVideos.isEmpty
            )
        case .audio:
            let duration = audioUsesSource
                ? effectiveAudioSourceSeconds
                : (audioModel.hasDurationControl ? selectedAudioDuration : 0)
            return try? FALAudioGenerationPlanner.estimatedCostMicroUSD(
                modelId: audioModel.id,
                prompt: trimmedPrompt,
                duration: duration
            )
        case .upscale:
            guard let source = upscaleSource,
                  let width = source.sourceWidth,
                  let height = source.sourceHeight else { return nil }
            let target = upscaleSettings.selections["targetResolution"] ?? "4k"
            return try? FALUpscaleGenerationPlanner.estimatedCostMicroUSD(
                modelId: upscaleModel.id,
                sourceType: source.type,
                width: width,
                height: height,
                fps: source.sourceFPS,
                duration: Double(effectiveUpscaleSeconds),
                targetLongEdge: FALUpscaleGenerationPlanner.targetLongEdge(target),
                targetFPS: upscaleSettings.selections["targetFPS"]
            )
        }
    }

    private var costHelpText: String {
        if selectedProvider == .fal {
            guard let cost = estimatedFALCostMicroUSD else {
                return "This fal.ai model is not connected yet."
            }
            let label = (Double(cost) / 1_000_000).formatted(
                .currency(code: "USD").precision(.fractionLength(3))
            )
            let hasReferences = !imageReferences.isEmpty
                || firstFrame != nil || lastFrame != nil
                || !refImages.isEmpty || !refVideos.isEmpty || !refAudios.isEmpty
            let referenceNote = hasReferences
                ? " Reference inputs may add usage-based charges." : ""
            return "\(label) estimated.\(referenceNote) Your fal.ai account is billed directly; pricing may change."
        }
        guard let cost = estimatedCost else {
            return "Estimated cost. Actual billing may differ slightly."
        }
        guard let left = remainingCredits else {
            return "\(cost) credits estimated. Actual billing may differ."
        }
        if cost > left {
            return "\(cost) credits needed. Only \(left.formatted()) remaining."
        }
        return "\(cost) credits. \((left - cost).formatted()) credits remaining after this generation."
    }

    var costEstimateLabel: some View {
        HStack(spacing: AppTheme.Spacing.xs) {
            Image(systemName: "dollarsign.circle.fill")
                .font(.system(size: AppTheme.FontSize.sm))
            Text(costEstimateText)
                .font(.system(size: AppTheme.FontSize.xs, weight: .medium))
                .monospacedDigit()
                .lineLimit(1)
        }
        .foregroundStyle(hasInsufficientCredits ? .red : AppTheme.Text.secondaryColor)
        .help(costHelpText)
    }

    private var costEstimateText: String {
        if selectedProvider == .fal {
            guard let cost = estimatedFALCostMicroUSD else { return "—" }
            return (Double(cost) / 1_000_000).formatted(
                .currency(code: "USD").precision(.fractionLength(3))
            )
        }
        return estimatedCost.map { $0.formatted() } ?? "—"
    }

    @ViewBuilder
    var submitButton: some View {
        if selectedProvider == .fal {
            let connected = isCurrentFALModelConnected
            Button {
                if !falCredentials.hasKey {
                    SettingsWindowController.shared.show(tab: .providers)
                } else if connected {
                    prepareFALGeneration()
                }
            } label: {
                Image(systemName: falCredentials.hasKey && connected
                    ? "arrow.up" : falCredentials.hasKey ? "hammer.fill" : "key.horizontal")
                    .font(.system(size: AppTheme.FontSize.sm, weight: .bold))
                    .frame(width: AppTheme.IconSize.sm, height: AppTheme.IconSize.sm)
            }
            .buttonStyle(.glassProminent)
            .buttonBorderShape(.circle)
            .controlSize(.regular)
            .tint(AppTheme.Accent.primary)
            .disabled(falCredentials.hasKey && (!connected || !canSubmit))
            .opacity(
                falCredentials.hasKey && (!connected || !canSubmit)
                    ? AppTheme.Opacity.strong : AppTheme.Opacity.opaque
            )
            .accessibilityLabel(
                !falCredentials.hasKey ? "Add FAL API key"
                    : connected ? "Generate with fal.ai" : "FAL integration preview"
            )
            .help(
                !falCredentials.hasKey ? "Add a fal.ai API key in Settings."
                    : connected ? "Review estimated fal.ai cost and generate."
                    : "This fal.ai media type is not connected yet."
            )
        } else {
            Button {
                if aiAllowed { submitGeneration() }
                else if !account.isMisconfigured { Task { await account.signInWithGoogle() } }
            } label: {
                Image(systemName: aiAllowed ? "arrow.up" : "person.crop.circle")
                    .font(.system(size: AppTheme.FontSize.sm, weight: .bold))
                    .frame(width: AppTheme.IconSize.sm, height: AppTheme.IconSize.sm)
            }
            .buttonStyle(.glassProminent)
            .buttonBorderShape(.circle)
            .controlSize(.regular)
            .tint(AppTheme.Accent.primary)
            .accessibilityLabel(aiAllowed ? (selectedType == .upscale ? "Upscale" : "Generate") : "Sign in")
            .disabled(aiAllowed ? !canSubmit : account.isMisconfigured || account.isSigningIn)
            .opacity((aiAllowed ? canSubmit : !account.isMisconfigured && !account.isSigningIn) ? AppTheme.Opacity.opaque : AppTheme.Opacity.strong)
            .help(aiAllowed
                ? (selectedType == .upscale ? "Upscale source media" : "")
                : (account.isMisconfigured ? "AI is unavailable" : account.isSigningIn ? "Opening Google" : "Sign in to generate"))
        }
    }

    // MARK: - Actions

    private var isCurrentFALModelConnected: Bool {
        switch selectedType {
        case .image: FALImageGenerationPlanner.supportedModelIds.contains(imageModel.id)
        case .video: FALVideoGenerationPlanner.supportedModelIds.contains(videoModel.id)
        case .audio: FALAudioGenerationPlanner.supportedModelIds.contains(audioModel.id)
        case .upscale: FALUpscaleGenerationPlanner.supportedModelIds.contains(upscaleModel.id)
        }
    }

    private func prepareFALGeneration() {
        guard selectedProvider == .fal else { return }
        guard falCredentials.hasKey else {
            SettingsWindowController.shared.show(tab: .providers)
            return
        }
        let audioDuration = selectedType == .audio
            ? (audioUsesSource
                ? effectiveAudioSourceSeconds
                : (audioModel.hasDurationControl ? selectedAudioDuration : 0))
            : 0
        if let error = preflightValidation(audioDuration: audioDuration) {
            flashDropError(error)
            return
        }

        do {
            switch selectedType {
            case .image:
                let imageCount = imageModel.maxImages > 1
                    ? min(imageModel.maxImages, max(1, selectedNumImages)) : 1
                var input = GenerationInput(
                    prompt: prompt,
                    model: imageModel.id,
                    duration: 0,
                    aspectRatio: selectedAspectRatio,
                    resolution: effectiveResolution,
                    quality: imageModel.qualities != nil ? selectedQuality : nil,
                    numImages: imageCount > 1 ? imageCount : nil
                )
                input.generationProvider = GenerationProvider.fal.rawValue
                input.backendEndpoint = FALImageGenerationPlanner.endpoint(
                    modelId: imageModel.id,
                    isEditing: !imageReferences.isEmpty
                )
                input.imageURLAssetIds = imageReferences.isEmpty ? nil : imageReferences.map(\.id)
                pendingFALConfirmation = .image(try FALImageGenerationPlanner.makePlan(
                    generationInput: input,
                    model: imageModel,
                    numImages: imageCount,
                    references: imageReferences,
                    folderId: editFolderId
                        ?? imageReferences.last?.folderId
                        ?? editor.mediaPanelCurrentFolderId,
                    replacementClipId: editor.pendingEditReplacementClipId
                ))
            case .video:
                let assets = videoInputAssets(for: videoModel)
                let input = GenerationInput(
                    prompt: prompt,
                    model: videoModel.id,
                    duration: effectiveVideoSeconds,
                    aspectRatio: selectedAspectRatio,
                    resolution: effectiveResolution,
                    generateAudio: effectiveGenerateAudio
                )
                pendingFALConfirmation = .media(try FALVideoGenerationPlanner.makePlan(
                    generationInput: input,
                    model: videoModel,
                    inputAssets: assets,
                    generateAudio: effectiveGenerateAudio,
                    folderId: editFolderId
                        ?? assets.textToVideoReferences.last?.folderId
                        ?? editor.mediaPanelCurrentFolderId,
                    replacementClipId: editor.pendingEditReplacementClipId
                ))
            case .audio:
                let source = audioUsesSource ? audioSource : nil
                let input = GenerationInput(
                    prompt: prompt,
                    model: audioModel.id,
                    duration: audioDuration,
                    aspectRatio: "",
                    resolution: nil,
                    voice: audioModel.voices != nil && !selectedVoice.isEmpty ? selectedVoice : nil,
                    instrumental: audioModel.supportsInstrumental ? instrumental : nil,
                    targetLanguage: audioModel.targetLanguages != nil ? selectedTargetLanguage : nil
                )
                pendingFALConfirmation = .media(try FALAudioGenerationPlanner.makePlan(
                    generationInput: input,
                    model: audioModel,
                    source: source,
                    duration: audioDuration,
                    voice: input.voice,
                    instrumental: instrumental,
                    targetLanguage: input.targetLanguage,
                    trimmedSource: source.flatMap(audioSourceTrimmedSource),
                    folderId: editFolderId
                        ?? source?.folderId
                        ?? editor.mediaPanelCurrentFolderId,
                    replacementClipId: editor.pendingEditReplacementClipId
                ))
            case .upscale:
                guard let source = upscaleSource else {
                    throw FALMediaGenerationError.missingSource
                }
                var input = EditSubmitter.upscaleSeed(
                    for: source,
                    model: upscaleModel,
                    trimmedSource: editor.pendingEditTrimmedSource
                )
                input.upscaleSettings = upscaleSettings
                pendingFALConfirmation = .media(try FALUpscaleGenerationPlanner.makePlan(
                    generationInput: input,
                    model: upscaleModel,
                    source: source,
                    settings: upscaleSettings,
                    trimmedSource: editor.pendingEditTrimmedSource,
                    folderId: editFolderId ?? source.folderId ?? editor.mediaPanelCurrentFolderId,
                    replacementClipId: editor.pendingEditReplacementClipId
                ))
            }
        } catch {
            flashDropError(error.localizedDescription)
        }
    }

    func submitConfirmedFALGeneration(_ confirmation: FALGenerationConfirmation) {
        switch confirmation {
        case .image(let plan): submitConfirmedFALImage(plan)
        case .media(let plan): submitConfirmedFALMedia(plan)
        }
    }

    func submitConfirmedFALImage(_ plan: FALImageGenerationPlan) {
        let editorRef = editor
        if let clipId = plan.replacementClipId {
            editor.markPendingReplacement(clipId: clipId)
        }
        let onComplete: (@MainActor (MediaAsset) -> Void)? = {
            guard let clipId = plan.replacementClipId else { return nil }
            let firstOnly = FirstOnlyFlag()
            return { [weak editorRef] asset in
                guard firstOnly.fire() else { return }
                editorRef?.replaceClipMediaRef(
                    clipId: clipId,
                    newAssetId: asset.id,
                    resetTrim: false
                )
                editorRef?.clearPendingReplacement(clipId: clipId)
            }
        }()
        let onFailure: (@MainActor () -> Void)? = {
            guard let clipId = plan.replacementClipId else { return nil }
            return { [weak editorRef] in
                editorRef?.clearPendingReplacement(clipId: clipId)
            }
        }()

        let assetId = editor.generationService.generateFALImage(
            plan: plan,
            projectURL: editor.projectURL,
            editor: editor,
            onComplete: onComplete,
            onFailure: onFailure
        )
        if plan.replacementClipId == nil {
            editor.selectMediaPanelItem(assetId)
        }
        editor.clearPendingGenerationPanelState()
        prompt = ""
        editFolderId = nil
        clearReferences()
    }

    private func submitConfirmedFALMedia(_ plan: FALMediaGenerationPlan) {
        let editorRef = editor
        let pendingAudioPlacement = plan.outputType == .audio
            ? editor.pendingEditAudioPlacement : nil
        let transitionPlacement = plan.outputType == .video
            ? editor.pendingEditTransitionPlacement : nil
        if let clipId = plan.replacementClipId {
            editor.markPendingReplacement(clipId: clipId)
        }
        let replacementComplete: (@MainActor (MediaAsset) -> Void)? = {
            guard let clipId = plan.replacementClipId else { return nil }
            return { [weak editorRef] asset in
                editorRef?.replaceClipMediaRef(
                    clipId: clipId,
                    newAssetId: asset.id,
                    resetTrim: false
                )
                editorRef?.clearPendingReplacement(clipId: clipId)
            }
        }()
        let onComplete: (@MainActor (MediaAsset) -> Void)? = {
            guard pendingAudioPlacement != nil || transitionPlacement != nil else {
                return replacementComplete
            }
            return { [weak editorRef] asset in
                if pendingAudioPlacement != nil {
                    editorRef?.finalizeGeneratingClip(placeholderId: asset.id, asset: asset)
                }
                if transitionPlacement != nil {
                    editorRef?.finalizeTransitionClip(placeholderId: asset.id, asset: asset)
                }
                replacementComplete?(asset)
            }
        }()
        let onFailure: (@MainActor () -> Void)? = {
            guard let clipId = plan.replacementClipId else { return nil }
            return { [weak editorRef] in
                editorRef?.clearPendingReplacement(clipId: clipId)
            }
        }()
        let assetId = editor.generationService.generateFALMedia(
            plan: plan,
            projectURL: editor.projectURL,
            editor: editor,
            onComplete: onComplete,
            onFailure: onFailure
        )
        if let placement = pendingAudioPlacement {
            editor.placeGeneratingAudioClip(
                placeholderId: assetId,
                startFrame: placement.startFrame,
                spanSeconds: placement.spanSeconds,
                actionName: placement.actionName
            )
        }
        if let placement = transitionPlacement {
            editor.placeGeneratingTransitionClip(placeholderId: assetId, placement: placement)
        }
        if plan.replacementClipId == nil {
            editor.selectMediaPanelItem(assetId)
        }
        editor.clearPendingGenerationPanelState()
        prompt = ""
        editFolderId = nil
        clearReferences()
    }

    func videoInputAssets(for model: VideoModelConfig) -> VideoGenerationSubmission.InputAssets {
        if model.requiresSourceVideo {
            return VideoGenerationSubmission.InputAssets(
                sourceVideo: sourceVideo,
                imageRefs: model.supportsReferences ? Array(imageReferences.prefix(1)) : []
            )
        }

        var frames: [MediaAsset] = []
        if showsFrameStrip {
            if let firstFrame { frames.append(firstFrame) }
            if let lastFrame { frames.append(lastFrame) }
        }
        return VideoGenerationSubmission.InputAssets(
            frames: frames,
            imageRefs: showsRefSections ? refImages : [],
            videoRefs: showsRefSections ? refVideos : [],
            audioRefs: showsRefSections ? refAudios : []
        )
    }

    func audioInputAssets(for model: AudioModelConfig) -> AudioGenerationSubmission.InputAssets {
        guard model.supportsReferences else { return AudioGenerationSubmission.InputAssets() }
        return AudioGenerationSubmission.InputAssets(imageRefs: refImages, audioRefs: refAudios)
    }

    private func preflightValidation(audioDuration: Int) -> String? {
        switch selectedType {
        case .video:
            let inputAssets = videoInputAssets(for: videoModel)
            let modelError: String?
            if videoModel.requiresSourceVideo {
                modelError = videoModel.validate(duration: 0, aspectRatio: "", resolution: nil)
            } else {
                modelError = videoModel.validate(
                    duration: selectedDuration,
                    aspectRatio: selectedAspectRatio,
                    resolution: effectiveResolution
                )
            }
            return modelError ?? inputAssets.validate(for: videoModel)
        case .image:
            let quality = imageModel.qualities != nil ? selectedQuality : nil
            let imageCount = imageModel.maxImages > 1
                ? min(imageModel.maxImages, max(1, selectedNumImages)) : 1
            return imageModel.validate(
                aspectRatio: selectedAspectRatio,
                resolution: effectiveResolution,
                quality: quality,
                imageRefCount: imageReferences.count,
                numImages: imageCount
            )
        case .audio:
            let inputAssets = audioInputAssets(for: audioModel)
            if audioUsesSource {
                guard audioSource != nil else { return "Add source media." }
                return audioModel.validate(spanSeconds: effectiveAudioSourceSpanSeconds)
                    ?? audioModel.validate(params: audioParams(audioDuration: audioDuration))
            }
            return audioModel.validate(params: audioParams(audioDuration: audioDuration))
                ?? inputAssets.validate(for: audioModel)
        case .upscale:
            guard let source = upscaleSource else { return "Add source media." }
            guard upscaleModel.supportedTypes.contains(source.type) else {
                return "\(upscaleModel.displayName) does not support this media type."
            }
            guard source.sourceWidth != nil, source.sourceHeight != nil else {
                return "Loading source dimensions…"
            }
            if source.type == .video {
                guard source.sourceFPS != nil else { return "Loading source frame rate…" }
                guard upscaleModel.supports(source: source) else {
                    return "This model cannot cap the output at 60 FPS."
                }
            }
            return nil
        }
    }

    private func audioParams(audioDuration: Int, videoURL: String? = nil) -> AudioGenerationParams {
        AudioGenerationParams(
            prompt: prompt,
            voice: audioModel.voices != nil && !selectedVoice.isEmpty ? selectedVoice : nil,
            lyrics: audioModel.supportsLyrics && !lyrics.isEmpty ? lyrics : nil,
            styleInstructions: audioModel.supportsStyleInstructions && !styleInstructions.isEmpty
                ? styleInstructions : nil,
            instrumental: audioModel.supportsInstrumental ? instrumental : false,
            durationSeconds: (audioModel.hasDurationControl || audioModel.acceptsSourceMedia) ? audioDuration : nil,
            videoURL: videoURL,
            sourceURL: nil,
            targetLanguage: audioModel.targetLanguages != nil ? selectedTargetLanguage : nil,
            multilingual: audioModel.supportsMultilingual ? multilingual : nil
        )
    }

    private func submitGeneration() {
        if currentModelLocked {
            SettingsWindowController.shared.show(tab: .account)
            return
        }
        let audioDuration: Int = {
            guard selectedType == .audio else { return 0 }
            if audioUsesSource { return effectiveAudioSourceSeconds }
            return audioModel.hasDurationControl ? selectedAudioDuration : 0
        }()
        if let err = preflightValidation(audioDuration: audioDuration) {
            flashDropError(err)
            return
        }
        let inputDuration: Int = switch selectedType {
        case .video: effectiveVideoSeconds
        case .audio: audioDuration
        case .upscale: effectiveUpscaleSeconds
        case .image: 0
        }
        var genInput = GenerationInput(
            prompt: prompt,
            model: currentModelId,
            duration: inputDuration,
            aspectRatio: selectedAspectRatio,
            resolution: effectiveResolution,
            quality: selectedType == .image && imageModel.qualities != nil ? selectedQuality : nil,
            voice: selectedType == .audio && audioModel.voices != nil && !selectedVoice.isEmpty
                ? selectedVoice : nil,
            lyrics: selectedType == .audio && audioModel.supportsLyrics && !lyrics.isEmpty
                ? lyrics : nil,
            styleInstructions: selectedType == .audio && audioModel.supportsStyleInstructions && !styleInstructions.isEmpty
                ? styleInstructions : nil,
            instrumental: selectedType == .audio && audioModel.supportsInstrumental
                ? instrumental : nil,
            targetLanguage: selectedType == .audio && audioModel.targetLanguages != nil
                ? selectedTargetLanguage : nil,
            multilingual: selectedType == .audio && audioModel.supportsMultilingual
                ? multilingual : nil,
            generateAudio: supportsAudioToggle ? generateAudio : nil
        )
        let imageCount: Int = {
            guard selectedType == .image, imageModel.maxImages > 1 else { return 1 }
            return min(imageModel.maxImages, max(1, selectedNumImages))
        }()
        if imageCount > 1 {
            genInput.numImages = imageCount
        }
        if selectedType == .audio {
            genInput.audioInput = activeAudioInput.rawValue
        }

        let replacementClipId = editor.pendingEditReplacementClipId
        let pendingAudioPlacement = selectedType == .audio ? editor.pendingEditAudioPlacement : nil
        let transitionPlacement = selectedType == .video ? editor.pendingEditTransitionPlacement : nil
        let editorRef = editor
        if let clipId = replacementClipId {
            editor.markPendingReplacement(clipId: clipId)
        }
        let makeOnComplete: (Bool) -> (@MainActor (MediaAsset) -> Void)? = { resetTrim in
            guard let clipId = replacementClipId else { return nil }
            let firstOnly = FirstOnlyFlag()
            return { [weak editorRef] newAsset in
                guard firstOnly.fire() else { return }
                editorRef?.replaceClipMediaRef(clipId: clipId, newAssetId: newAsset.id, resetTrim: resetTrim)
                editorRef?.clearPendingReplacement(clipId: clipId)
            }
        }
        let onFailure: (@MainActor () -> Void)? = {
            guard let clipId = replacementClipId else { return nil }
            return { [weak editorRef] in
                editorRef?.clearPendingReplacement(clipId: clipId)
            }
        }()

        let autoOpenPreview: (String) -> Void = { newAssetId in
            guard replacementClipId == nil else { return }
            editorRef.selectMediaPanelItem(newAssetId)
        }

        switch selectedType {
        case .video:
            let model = videoModel
            let inputAssets = videoInputAssets(for: model)
            let trimmedSource: TrimmedSource? = {
                guard model.requiresSourceVideo,
                      let trim = editor.pendingEditTrimmedSource,
                      let sv = sourceVideo,
                      trim.sourceURL == sv.url else { return nil }
                return trim
            }()
            let placeholderDuration: Double
            if model.requiresSourceVideo {
                if let trim = trimmedSource, trim.hasTrim {
                    placeholderDuration = trim.durationSeconds
                } else {
                    placeholderDuration = sourceVideo?.duration ?? 5
                }
            } else {
                placeholderDuration = Double(selectedDuration)
            }
            let videoFolderId: String? = editFolderId ?? (
                model.requiresSourceVideo
                    ? (inputAssets.sourceVideo?.folderId ?? inputAssets.imageRefs.last?.folderId)
                    : inputAssets.textToVideoReferences.last?.folderId
            ) ?? editor.mediaPanelCurrentFolderId
            let baseOnComplete = makeOnComplete(trimmedSource?.hasTrim == true)
            let videoOnComplete: (@MainActor (MediaAsset) -> Void)? = {
                guard transitionPlacement != nil else { return baseOnComplete }
                return { [weak editorRef] asset in
                    editorRef?.finalizeTransitionClip(placeholderId: asset.id, asset: asset)
                    baseOnComplete?(asset)
                }
            }()
            let videoAssetId = VideoGenerationSubmission.make(
                genInput: genInput,
                model: model,
                inputAssets: inputAssets,
                placeholderDuration: placeholderDuration,
                trimmedSourceOverride: trimmedSource,
                folderId: videoFolderId,
                generateAudio: effectiveGenerateAudio
            ).submit(
                service: editor.generationService,
                projectURL: editor.projectURL,
                editor: editor,
                onComplete: videoOnComplete,
                onFailure: onFailure
            )
            if let placement = transitionPlacement {
                editor.placeGeneratingTransitionClip(placeholderId: videoAssetId, placement: placement)
            }
            autoOpenPreview(videoAssetId)
        case .image:
            let model = imageModel
            let imageAssetId = ImageGenerationSubmission.make(
                genInput: genInput,
                model: model,
                references: imageReferences,
                numImages: imageCount,
                folderId: editFolderId ?? imageReferences.last?.folderId ?? editor.mediaPanelCurrentFolderId
            ).submit(
                service: editor.generationService,
                projectURL: editor.projectURL,
                editor: editor,
                onComplete: makeOnComplete(false),
                onFailure: onFailure
            )
            autoOpenPreview(imageAssetId)
        case .audio:
            let model = audioModel
            let inputAssets = audioInputAssets(for: model)
            let onCompleteAudio = makeOnComplete(false)
            let sourceAsset = model.acceptsSourceMedia ? audioSource : nil
            if let sourceAsset {
                genInput.setAudioSourceAsset(sourceAsset)
            }
            let audioOnComplete: (@MainActor (MediaAsset) -> Void)? = {
                guard pendingAudioPlacement != nil else { return onCompleteAudio }
                return { [weak editorRef] asset in
                    editorRef?.finalizeGeneratingClip(placeholderId: asset.id, asset: asset)
                    onCompleteAudio?(asset)
                }
            }()
            let audioAssetId = AudioGenerationSubmission.make(
                genInput: genInput,
                model: model,
                params: audioParams(audioDuration: audioDuration),
                folderId: editFolderId
                    ?? sourceAsset?.folderId
                    ?? inputAssets.references.last?.folderId
                    ?? editor.mediaPanelCurrentFolderId,
                references: model.supportsReferences
                    ? inputAssets.references : sourceAsset.map { [$0] } ?? [],
                trimmedSourceOverride: sourceAsset.flatMap(audioSourceTrimmedSource)
            ).submit(
                service: editor.generationService,
                projectURL: editor.projectURL,
                editor: editor,
                onComplete: audioOnComplete,
                onFailure: onFailure
            )
            if let placement = pendingAudioPlacement {
                editor.placeGeneratingAudioClip(
                    placeholderId: audioAssetId,
                    startFrame: placement.startFrame,
                    spanSeconds: placement.spanSeconds,
                    actionName: placement.actionName
                )
            }
        case .upscale:
            guard let source = upscaleSource else { return }
            let trim: TrimmedSource? = {
                guard let pending = editor.pendingEditTrimmedSource,
                      pending.sourceURL == source.url else { return nil }
                return pending
            }()
            let assetId = EditSubmitter.submitUpscale(
                asset: source,
                model: upscaleModel,
                editor: editor,
                settings: upscaleSettings,
                trimmedSource: trim,
                onComplete: makeOnComplete(trim?.hasTrim == true),
                onFailure: onFailure
            )
            if let assetId { autoOpenPreview(assetId) }
        }
        editor.clearPendingGenerationPanelState()
        lyrics = ""
        styleInstructions = ""
        prompt = ""
        editFolderId = nil
        clearReferences()
    }

    // MARK: - Panel seeding / reset

    func consumePendingPanelSeed() {
        guard let seed = editor.pendingPanelSeed else { return }
        populatePanel(asset: seed.asset, stored: seed.stored)
        editor.pendingPanelSeed = nil
    }

    private func populatePanel(asset: MediaAsset, stored: GenerationInput) {
        if stored.generationProvider == GenerationProvider.fal.rawValue {
            isPopulatingPanel = true
            selectedProvider = .fal
            if let idx = FALPreviewCatalog.shared.video.firstIndex(where: {
                $0.id == stored.model
            }) {
                selectedType = .video
                selectedVideoModelIndex = idx
            } else if let idx = FALPreviewCatalog.shared.image.firstIndex(where: {
                $0.id == stored.model
            }) {
                selectedType = .image
                selectedImageModelIndex = idx
            } else if let idx = FALPreviewCatalog.shared.audio.firstIndex(where: {
                $0.id == stored.model
            }) {
                selectedType = .audio
                selectedAudioModelIndex = idx
            } else if let idx = FALPreviewCatalog.shared.upscale.firstIndex(where: {
                $0.id == stored.model
            }) {
                selectedType = .upscale
                selectedUpscaleModelIndex = idx
            } else {
                isPopulatingPanel = false
                return
            }
        } else {
            switch ModelRegistry.byId[stored.model] {
            case .video:
                guard let idx = videoModels.firstIndex(where: { $0.id == stored.model }) else { return }
                isPopulatingPanel = true
                selectedType = .video
                selectedVideoModelIndex = idx
            case .image:
                guard let idx = imageModels.firstIndex(where: { $0.id == stored.model }) else { return }
                isPopulatingPanel = true
                selectedType = .image
                selectedImageModelIndex = idx
            case .audio:
                guard let idx = audioModels.firstIndex(where: { $0.id == stored.model }) else { return }
                isPopulatingPanel = true
                selectedType = .audio
                selectedAudioModelIndex = idx
            case .upscale:
                guard let idx = upscaleModels.firstIndex(where: { $0.id == stored.model }) else { return }
                isPopulatingPanel = true
                selectedType = .upscale
                selectedUpscaleModelIndex = idx
            case .none:
                return
            }
        }
        defer { DispatchQueue.main.async { isPopulatingPanel = false } }

        prompt = stored.prompt
        if !stored.aspectRatio.isEmpty { selectedAspectRatio = stored.aspectRatio }
        if let r = stored.resolution { selectedResolution = r }
        if let q = stored.quality { selectedQuality = q }
        if stored.duration > 0 {
            selectedDuration = stored.duration
            selectedAudioDuration = stored.duration
        }
        if let n = stored.numImages { selectedNumImages = max(1, n) }
        if let v = stored.voice, !v.isEmpty { selectedVoice = v }
        if let language = stored.targetLanguage,
           audioModel.targetLanguages?.contains(language) == true {
            selectedTargetLanguage = language
        } else if selectedType == .audio {
            selectedTargetLanguage = initialAudioTargetLanguage
        }
        multilingual = stored.multilingual ?? false
        lyrics = stored.lyrics ?? ""
        styleInstructions = stored.styleInstructions ?? ""
        instrumental = stored.instrumental ?? false
        generateAudio = stored.generateAudio ?? true
        if selectedType == .upscale {
            upscaleSettings = stored.upscaleSettings ?? upscaleModel.defaultSettings
        }

        clearReferences()

        let assetsById = Dictionary(editor.mediaAssets.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let lookup: (String) -> MediaAsset? = { assetsById[$0] }
        let primary = (stored.imageURLAssetIds ?? []).compactMap(lookup)

        switch selectedType {
        case .video:
            if videoModel.requiresSourceVideo {
                sourceVideo = primary.first
                if videoModel.supportsReferences, primary.count > 1 {
                    imageReferences = [primary[1]]
                }
            } else {
                if videoModel.supportsFirstFrame {
                    firstFrame = primary.first
                    if videoModel.supportsLastFrame, primary.count > 1 {
                        lastFrame = primary[1]
                    }
                }
                refImages = (stored.referenceImageAssetIds ?? []).compactMap(lookup)
                refVideos = (stored.referenceVideoAssetIds ?? []).compactMap(lookup)
                refAudios = (stored.referenceAudioAssetIds ?? []).compactMap(lookup)
                if videoModel.framesAndReferencesExclusive {
                    framesRefsMode = (!refImages.isEmpty || !refVideos.isEmpty || !refAudios.isEmpty)
                        ? .reference : .firstLast
                } else {
                    framesRefsMode = .firstLast
                }
            }
        case .image:
            imageReferences = primary
        case .audio:
            if audioModel.supportsReferences {
                refImages = (stored.referenceImageAssetIds ?? []).compactMap(lookup)
                refAudios = (stored.referenceAudioAssetIds ?? []).compactMap(lookup)
            } else {
                audioSource = (stored.referenceAudioAssetIds ?? []).compactMap(lookup).first
                    ?? (stored.referenceVideoAssetIds ?? []).compactMap(lookup).first
            }
        case .upscale:
            upscaleSource = primary.first ?? asset
        }

        editFolderId = asset.folderId

        if selectedType == .upscale {
            upscaleSettings = upscaleModel.normalizedSettings(upscaleSettings, source: upscaleSource)
        } else {
            resetSettings()
        }
    }

    func resetAudioState() {
        let model = audioModel
        multilingual = false
        selectedVoice = model.defaultVoice ?? ""
        selectedTargetLanguage = initialAudioTargetLanguage
        if !model.supportsLyrics { lyrics = "" }
        if !model.supportsStyleInstructions { styleInstructions = "" }
        if !model.supportsInstrumental { instrumental = false }
        normalizeAudioDuration()
    }

    private func normalizeAudioDuration() {
        let model = audioModel
        if let range = model.durationRange,
           !(range.minimum...range.maximum).contains(selectedAudioDuration) {
            selectedAudioDuration = range.defaultValue
        } else if let durations = model.durations, !durations.contains(selectedAudioDuration) {
            selectedAudioDuration = durations.first ?? 30
        }
    }

    func resetSettings() {
        if selectedType == .upscale {
            resetUpscaleSettings()
            return
        }
        if !currentAspectRatios.contains(selectedAspectRatio) {
            selectedAspectRatio = currentAspectRatios.first ?? "16:9"
        }
        if let resolutions = currentResolutions, !resolutions.contains(selectedResolution) {
            selectedResolution = resolutions.first ?? "1080p"
        }
        if let qualities = currentQualities, !qualities.contains(selectedQuality) {
            selectedQuality = qualities.last ?? "high"
        }
        if selectedType == .video, !videoModel.durations.contains(selectedDuration) {
            selectedDuration = videoModel.durations.first ?? 5
        }
        if selectedType == .video { generateAudio = true }
        if selectedType == .image {
            selectedNumImages = min(max(1, selectedNumImages), imageModel.maxImages)
        }
        if selectedType == .audio { normalizeAudioDuration() }
    }

    func resetUpscaleSettings() {
        upscaleSettings = upscaleModel.normalizedSettings(upscaleModel.defaultSettings, source: upscaleSource)
    }
}
