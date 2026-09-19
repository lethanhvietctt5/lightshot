# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

**The working agreement for this repo lives in [`AGENTS.md`](AGENTS.md) — read it first.** It is the single source of truth for all agents; this file only points to it so guidance never drifts between the two.

Non-negotiables worth having in front of you before you touch anything:

- **The repo is spec-first and not yet scaffolded** — only `specs/` exists. There is no Swift package or Xcode project yet, so **do not fabricate build/test commands or claim they pass.** See AGENTS.md → *Current state* and *Intended commands*.
- **The spec is the contract.** Read `specs/NNNN-*.md` and the matching Linear issue (team **Lightshot**) before writing feature code; keep file, issue, and PR in sync.
- **Architecture:** push behavior into the pure `AnnotationDocument` command model and the pure `render` function; keep OS work behind protocols with no AppKit/ScreenCaptureKit imports in the domain core. See AGENTS.md → *Architecture*.
- **Workflow:** spec → Linear (`ready-for-agent`) → branch per issue → PR to `main` → Copilot review loop (fix → reply → resolve → re-request). See AGENTS.md → *The main workflow*.
- **Guardrails:** local-only v1 (no cloud/network/accounts); only `blackout` is secure redaction (never blur/pixelate); macOS 14+/ScreenCaptureKit only.
