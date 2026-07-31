# BYOK generation provider

This branch adds `fal.ai · BYOK` as an execution provider beside Palmier Cloud.
The model vendor and the execution provider remain separate concepts: a Google,
OpenAI, ByteDance, Kuaishou, ElevenLabs, or Topaz model can be executed and
billed through fal.ai.

The provider selector lives in the trailing action area of the generation
toolbar, next to the cost estimate and submit button. Palmier Cloud stays
disabled in preview builds that do not contain Palmier's backend
configuration.

## Connected workflows

| Workflow | Connected models | Inputs and controls |
| --- | --- | --- |
| Image | Nano Banana 2, GPT Image 2, FLUX.2 | text generation, image editing with references, resolution/aspect/quality, multiple outputs where supported |
| Video | Seedance 2.0 Fast, Seedance 2.0, Kling 3.0 Standard, Veo 3.1, LTX 2.3 Reframe, VEED Lip Sync v2 | text-to-video, first/last frame where supported, Seedance image/video/audio references, LTX video reframing, VEED replacement-audio lip sync, duration, resolution, aspect ratio, generated audio |
| Audio | ElevenLabs v3 TTS, Music, Sound Effects, Audio Isolation, Dubbing | voice, duration, instrumental mode, audio/video source media, target language |
| Upscale | Topaz Image, Topaz Video, SeedVR2 | image/video source media, target resolution, frame rate, Topaz enhancement model |

The catalog is intentionally curated rather than mirroring every fal.ai
endpoint. Every model shown in this catalog has an endpoint-specific request
mapper; unsupported controls are not advertised.

## Request lifecycle

1. Palmier validates the selected model, input media, and endpoint-specific
   limits locally.
2. It computes a USD estimate from the currently documented fal.ai billing
   unit and asks for explicit confirmation.
3. Local reference/source media is converted, trimmed, or compressed where
   required and uploaded to fal.ai's CDN. Large files use multipart uploads.
4. The app submits to the fal.ai queue, stores the endpoint and request ID in
   the project, polls the job, and can reconstruct an interrupted queue job
   after relaunch.
5. Completed media is downloaded and imported through Palmier's existing
   project-media pipeline.

Uploaded inputs and generated outputs request a 24-hour fal.ai CDN lifetime.
Queue request metadata follows the fal.ai account/service retention policy so
an interrupted request can be resumed.

## Keys, privacy, and billing

- The API key is stored in macOS Keychain and is never written into the
  project, app bundle, logs, repository, or DMG.
- The preview app reads the key only when it uploads media or calls the fal.ai
  queue.
- Reference and source media is sent to fal.ai only after the user confirms
  the displayed estimate.
- The estimate is a safety preview, not a billing guarantee. fal.ai bills the
  user's account directly and may change prices or round billing units.
- The app does not make a paid test request during build or automated tests.

An ad-hoc preview build has no stable Developer ID signature. macOS may ask for
Keychain access again when the executable identity changes between builds.
That prompt is expected to disappear once builds use a stable signed app
identity.

## Internal preview build

`scripts/package-byok-preview.sh` creates an isolated, ad-hoc signed test DMG.
It uses a separate bundle identifier and display name, disables Sparkle
updates, defaults to fal.ai, and contains no API key.

The `BYOK Preview` GitHub workflow packages the DMG for pushes to
`ongrow/**`. Automated tests exercise validation, request construction, cost
calculation, storage URL handling, result parsing, and the connected catalog
without contacting a paid model endpoint.

Developers using Command Line Tools without the full Xcode Metal toolchain can
set `PALMIER_SKIP_METAL_PLUGIN=1` for non-rendering local checks. A complete
build still requires the full Xcode version supported by Palmier.

## Manual validation

The ad-hoc BYOK preview was manually validated on 2026-08-01 with a real
fal.ai account and imported test media:

- Image generation and image editing with reference media completed and
  returned importable results.
- Video generation with supported reference controls completed and returned
  an importable result.
- `Check Problem` exposed an actionable diagnosis for a failed fal.ai request
  instead of only displaying the HTTP status.
- A Codex chat started from Palmier, used Codex as the default provider, and
  interacted with the open project.
- LTX 2.3 Reframe converted a landscape clip successfully.
- VEED Lip Sync v2 synchronized a frontal talking-head clip to an independent
  human speech recording successfully.

These are user-confirmed smoke tests, not automated paid endpoint tests. Model
availability, pricing, and remote behavior can still change independently of
the app.

## Thin-fork maintenance

`ongrow/codex-provider` is the integration branch for the complete OnGROW
overlay. Upstream changes are merged into this branch; the OnGROW commits are
not replayed or copied manually for each Palmier release.

`Upstream Watch` runs daily at 06:17 UTC and can also be started manually. It
fetches `palmier-io/palmier-pro:main` and then follows one of two paths:

- A conflict-free merge creates a draft `ongrow/upstream-*` pull request. CI
  and the BYOK preview build must pass before it is merged.
- A conflicting merge creates or updates an issue assigned to `Schrobo` with
  the exact conflicting files. It never resolves or merges conflicts
  automatically.

Before accepting a sync pull request, manually verify one FAL generation, the
`Check Problem` lookup for a stored request ID, and one Codex chat against a
saved project. Also review the upstream changelog, model catalog, and AI edit
actions for every new or changed AI feature. Each applicable feature must be
mapped to a documented BYOK endpoint with local validation, cost estimation,
request tests, and a manual smoke test, or be explicitly documented as
unavailable. A conflict-free merge and green CI alone do not establish BYOK
feature parity. The workflow never merges a pull request by itself.

Scheduled and manual runs become available after this workflow exists on the
fork's default branch. Until then, compare and merge `upstream/main` from the
integration branch directly.
