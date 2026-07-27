# BYOK generation provider spike

This branch prototypes the generation UX before any provider calls, secret
storage, billing, or queue handling are implemented.

## UX decision

The generation panel treats these as separate concepts:

- **Execution provider** — who receives the request and bills it (`Palmier` or
  `fal.ai`).
- **Model vendor** — who made the selected model (`Google`, `ByteDance`,
  `OpenAI`, `ElevenLabs`, and others).

The provider is selected first. The existing Image, Video, Audio, and Upscale
flows then display a provider-specific model catalog and reuse Palmier's
capability-driven controls.

The `fal.ai` submit button is deliberately disabled and marked as a preview.
Selecting it cannot submit a request or spend credits.

## Preview scope

| Workflow | Models represented in the preview | Controls exercised |
| --- | --- | --- |
| Image | Nano Banana 2, GPT Image 2, FLUX.2 | resolution, aspect ratio, quality, references |
| Video | Seedance 2.0 Fast, Seedance 2.0, Kling 3.0 Standard, Veo 3.1 | duration, resolution, aspect ratio, first/last frame, image/video/audio references |
| Audio | ElevenLabs TTS, Music, Sound Effects, Audio Isolation, Dubbing | voice, duration, instrumental mode, source media, target language |
| Upscale | Topaz Image, Topaz Video, SeedVR2 | source type, resolution, frame rate, enhancement model |

This is a deliberately curated catalog for UX validation, not a complete
mirror of the FAL model directory. Endpoint names and parameter mappings must
be verified against the live FAL schemas when the backend adapter is built.

## Next implementation slice

After the UX is approved:

1. Store the API key in macOS Keychain and keep it out of project files and
   logs.
2. Add a `GenerationBackend` implementation for FAL with a small,
   endpoint-specific request mapper.
3. Upload local reference media and submit through the FAL queue API.
4. Poll job state, support cancellation, download the result, and import it
   through Palmier's existing media pipeline.
5. Fetch or maintain pricing metadata and show a pre-submit estimate.

Direct vendor adapters should only be added for features that FAL does not
expose, such as account-specific voice-library or voice-cloning workflows.
