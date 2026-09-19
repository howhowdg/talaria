# Changelog

## Unreleased

- Simplify the repository documentation around installation, contribution and current preview capabilities.
- Consolidate maintained technical guides and remove historical design exports and working notes from the current source tree.

## 0.1.2 — 2026-09-18

- Home, Workspaces, Automations and Activity organise conversations and scheduled results on Mac and iOS.
- Mac transcripts use compact, side-by-side bubbles with assistant avatars, separate tool and request cards, and gateway-provided timestamps.
- Import Telegram topics through the optional Hermes integration; retain verified names while preserving custom workspace names.
- Updated native icons, settings surfaces, request handling and gateway compatibility.
- Add a repeatable Mac distribution packager that requires Developer ID signing, notarization and Gatekeeper verification before producing a public download. The universal Mac preview includes a stapled notarization ticket and a published SHA-256 checksum.

## 0.1.1 — 2026-09-17

Mac workspace preview.

- Three-column Mac workspace with sidebar or tab navigation, compact typography, blue identity and the vector Talaria mark.
- Recorded Files, Sources and Terminal inspector with conversation-scoped task status and native Markdown.
- Native growing message editor with focus, undo, attachment controls and model selection.
- Corrected session selection, local-date grouping, glass edges and control spacing.
- Universal Mac download for Apple silicon and Intel. This preview is ad hoc signed and not notarized.

## 0.1.0 — 2026-09-17

Initial public source preview of Talaria for Mac and iPhone/iPad.

- Shared native SwiftUI client with Liquid Glass controls, adaptive colors and layered app icon.
- Native conversations, streaming text/reasoning/tool output, model selection, existing profiles, attachments and persistent drafts.
- Token-authenticated Hermes gateway transport, Keychain storage and Mac local-runtime supervision.
- Pinned gateway contract, generated Swift protocol catalog, unit tests and isolated real-backend integration fixtures.
- MIT license, Hermes attribution, contributor setup and security reporting.

This initial preview covered the native conversation workflow. See [preview status](docs/status.md) for current capabilities and limitations.
