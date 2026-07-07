# Chat Camera Roadmap

Goal: make in-chat camera capture feel as polished and reliable as gallery media and voice notes for owner and vet consults.

## Phase 1 - Capture entry point

- Add a camera option to the chat media sheet in owner and vet apps.
- Capture a single photo with the native camera via `image_picker`.
- Reuse the existing image compression, validation, staged preview, upload, retry, and playback/open-image pipeline.
- Keep gallery multi-image and video behavior unchanged.

Status: implemented for owner and vet chat.

## Phase 2 - UX polish

- Add a dedicated camera icon beside the gallery and mic tools once the composer layout can absorb a third tool without crowding small screens.
- Keep the current bottom-sheet fallback for compact layouts and accessibility.
- Show a captured-photo staging animation that matches gallery image previews.
- Confirm permission-denied states show a clean Spanish message with a path to Settings.

## Phase 3 - Camera-grade reliability

- Preserve local captured-photo paths across message refreshes until backend download URLs are ready.
- Keep captured images visible during upload, media processing, and signed URL refreshes.
- Add telemetry around camera cancel, permission denied, capture success, compression fallback, upload retry, and send success.

## Phase 4 - QA matrix

- Owner iOS simulator/device: camera option opens camera or simulator camera fallback, cancel is harmless, captured photo stages and sends.
- Vet iOS simulator/device: same flow, including consult-closed and sending-disabled states.
- Multi-participant chat: owner sends camera image, vet sends camera image, both remain visible after more messages and refreshes.
- Regression: gallery multi-image, video upload, voice note recording, tap-to-open images, and active chat return button still work.

## Phase 5 - Future upgrades

- Consider camera video capture only after upload limits, compression, preview, and duration handling are explicitly product-approved.
- Consider in-app crop/markup for clinical photos if vets request it during QA.
- Consider guided capture prompts for common equine use cases, such as wound close-up, gait stance, eye, hoof, and document/photo of prescription.
