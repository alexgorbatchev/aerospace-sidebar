---
created_on: 2026-10-29 15:58
last_modified: 2026-10-29 16:00
status: current
---

# Reconstruction of the refused SIP proposal

This reference reconstructs the proposal in Claude session `cd7614d2-9a06-498e-a337-e4f759abf820` for the aerospace-sidebar maintainer. It records the proposed mechanism and its limits; it is not an implemented or validated design.

## What the proposal was

Build a separate, explicitly opt-in native helper that loads code into the running macOS NotificationCenter process. The helper would intercept the window behavior inside that process, preventing its hidden notifications from briefly reappearing on screen. A further proposed capability was to invoke NotificationCenter's own notification-response path directly, so a sidebar card could perform the native action without opening and closing the history panel.

The ordinary sidebar installation would retain its stock-macOS Accessibility implementation. The helper would be an optional enhanced mode for a user willing to change system protections and accept OS-version-specific maintenance.

This was a user-space injection proposal, not a kernel driver. The analogy was the user's better-fonts tool: change behavior inside the process that owns it, rather than repeatedly correcting it from outside. Claude specifically distinguished attachment to a running platform process from putting `DYLD_INSERT_LIBRARIES` in an ordinary app launcher.

## Problem it was intended to solve

The session reports that the sidebar moves NotificationCenter's window off-screen through Accessibility, but NotificationCenter resets its frame when creating a window or switching from history back to banners. The external move is applied only after NotificationCenter processes it, leaving a short visible flash.

One reported trace is an off-screen x position of −5000, a reset to (0, 0) at 335 ms, and another move to −5000 at 386 ms: approximately 51 ms on screen. These are observations reported by the prior agent, not measurements repeated for this document.

The intended change was to prevent the visible frame from being presented in the first place. Faster polling or another Accessibility thread had reportedly failed to remove that delay.

## Reconstructed architecture

| Component | Intended responsibility | Evidence level |
| --- | --- | --- |
| Normal sidebar | Continue operating on stock macOS through Accessibility and notification history. | Explicit user requirement and existing-session context. |
| Optional loader/helper | Attach to the running NotificationCenter process and load a native payload. | Explicit proposal; loading mechanism not specified or demonstrated. |
| In-process window interception | Keep the notification window off-screen or prevent the reset that exposes it while sidebar interception is active. | Explicit proposal; no concrete hook or method identified. |
| Optional action bridge | Request the same native notification action without opening the history UI. | Explicit aspiration; private entry point, transport, and payload contract unspecified. |
| Lifecycle and user control | Reattach after a process restart and permit normal NotificationCenter use when the user opens it. | Inferred engineering requirements, not a recovered implementation. |

The action bridge would need to preserve the originating app's real notification callback, including default actions and eventually choices/replies. Merely activating an app does not satisfy the original requirement to select the correct browser tab or Slack conversation. The transcript does not prove that an injected helper can replay notifications already removed by their originating app.

## Alternative mentioned

Claude also proposed a yabai-style scripting addition loaded into Dock, using privileged window-management capabilities to make NotificationCenter's window transparent. That is an alternative route for suppressing the visual flash; it does not by itself establish a route for delivering notification actions.

The later prototype offer and refusal name the **NotificationCenter helper**, making direct NotificationCenter injection the strongest match for the refused proposal. Dock injection was a secondary option.

## SIP and other prerequisites: claims versus verification

The prior session reports a machine with SIP Debugging Restrictions already disabled, while filesystem and NVRAM protections remained enabled. Claude claimed the additional requirements were disabling NVRAM protection, enabling the `-arm64e_preview_abi` boot argument, root privileges, and a reboot. It warned that macOS updates could break the injected code.

Those statements are part of the recovered proposal, not a verified minimal configuration for a NotificationCenter injector. The session does not establish that these changes are sufficient, identify an injection implementation, or demonstrate that signing, library validation, entitlements, and arm64e constraints are resolved.

The corrected prerequisites for the **yabai Dock alternative**, according to the maintained [yabai SIP documentation](https://github.com/asmvik/yabai/wiki/Disabling-System-Integrity-Protection) checked on 2026-10-29, are:

| Requirement | Documented Apple Silicon configuration for macOS 13 and newer |
| --- | --- |
| SIP filesystem protections | Disabled. This requirement was missing from Claude's proposal. |
| SIP debugging restrictions | Disabled. |
| SIP NVRAM protection | Disabled. |
| Non-Apple-signed arm64e binaries | Enabled through the `-arm64e_preview_abi` boot argument. |
| Applying the configuration | Recovery-mode SIP changes, privileged boot-argument configuration, and reboots. |

These requirements describe yabai's documented Dock scripting-addition route. The **direct NotificationCenter injector remains unverified**: neither Claude's shorter list nor yabai's configuration establishes its minimum or sufficient prerequisites. An implementation would need to establish those against its actual loader and target process.

## Evidence and actual refusal

Canonical transcript:

`~/.claude/projects/<project-directory>/cd7614d2-9a06-498e-a337-e4f759abf820.jsonl`

The line references below refer to that JSONL file. They identify assistant messages, not verified platform documentation.

Transcript line 4616 — message `a01f521e-197f-4fcb-b448-ec559d8eb271`, 2026-10-29 20:43:40 UTC:

> A dylib injected into NotificationCenter that keeps its window off-screen or skips the move.

The same message presents the Dock scripting-addition alternative and explains that the proposed payload would attach to the running process.

Transcript line 4725 — message `751c5615-a74f-4a94-81be-8cbda1283e32`, 2026-10-29 21:20:45 UTC:

> **F5 Best experience (opt-in):** a small helper loaded into NotificationCenter. It could suppress the flash entirely, and could deliver a click without opening the panel at all.

The same message asks:

> **Q2** Should I prototype the NotificationCenter helper from F5 as a separate opt-in tool, kept out of the sidebar so the default install never needs SIP changes?

Transcript line 5032 — message `70f6a43c-c122-42cd-8f02-de895805484e`, 2026-10-29 21:55:37 UTC:

> **F7 Q2 (the NotificationCenter helper) is off.** My attempt at it was stopped by a safety classifier, so I won't build it.

This is an explicit withdrawal after an earlier offer. The visible explanation attributes it to a safety classifier; it does not identify the rejected operation, provide a classifier rationale, or establish that the proposed mechanism was technically impossible. No working injector, exact hook, or validated action bridge is established by these passages.

## Remaining unknowns

- Which concrete NotificationCenter window or presentation method to intercept on the target macOS build.
- Whether preventing that reset preserves notification lifecycle, accessibility, and intentional user access to NotificationCenter.
- Which private response API would deliver the native action, and which notification records must still exist for it to work.
- Which exact system-protection and signing configuration a chosen implementation needs.
- How the helper would authenticate sidebar requests, recover after NotificationCenter restarts, and restore normal behavior when disabled.

The defensible reconstruction is therefore an **optional in-process NotificationCenter extension for flash suppression, with direct native-action delivery as an additional unproven capability**. It is not a recovered implementation plan with settled APIs or prerequisites.
