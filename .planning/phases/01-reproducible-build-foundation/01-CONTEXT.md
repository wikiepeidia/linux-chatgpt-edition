# Phase 1: Reproducible Build Foundation - Context

**Gathered:** 2026-08-25
**Status:** Ready for planning

<domain>
## Phase Boundary

Establish one pinned, secret-safe Windows-to-Linux image-building environment that can produce and identify a bootstrap Alpine ISO. This phase proves the builder, artifact transfer, signing-key boundary, QEMU discovery, and fallback path; it does not yet build the final diskless runtime or graphical product.

</domain>

<decisions>
## Implementation Decisions

### Claude's Discretion
- All implementation choices are at Claude's discretion because this is a pure infrastructure phase and the user explicitly delegated the overnight build.
- Use Alpine Linux 3.24.1, a pinned `3.24-stable` aports commit, and a Linux/amd64 builder rather than a moving branch or a different distribution.
- Prefer Docker Desktop Linux containers after an explicit daemon/platform preflight; use an Alpine QEMU build VM as the documented fallback without changing profiles or runtime architecture.
- Keep Linux-sensitive build work on a Linux-owned volume so Windows CRLF, executable-bit, ownership, and symlink behavior cannot silently corrupt inputs.
- Persist the APK signing key and caches outside Git and runtime artifacts; record public identity and resolved inputs without exposing private material.
- Treat one PowerShell entry point as the host contract and fail early with actionable diagnostics for Docker, platform, QEMU, firmware, disk space, and artifact paths.

</decisions>

<code_context>
## Existing Code Insights

### Reusable Assets
- Project-level stack, architecture, pitfalls, and synthesis research already define the pinned builder and fallback seams.
- QEMU 11.1.0 and EDK2 firmware are available at `D:\\VM\\qemu`.

### Established Patterns
- The repository is greenfield; source-controlled build configuration must be explicit, secret-free, and verifiable.
- Every phase preserves a uniquely hashed last-known-good artifact or fast local proof.

### Integration Points
- The PowerShell host wrapper will call Docker or the fallback VM, then hand artifacts to QEMU smoke commands and later release-evidence tooling.
- Phase 2 consumes the pinned builder, signing boundary, artifact manifest, and bootstrap-ISO proof created here.

</code_context>

<specifics>
## Specific Ideas

- The user supplied QEMU at `D:\\VM\\qemu` and wants the work to continue unattended overnight.
- A near-100 MB final ISO is a stretch target, but Phase 1 optimizes for a trustworthy build seam rather than size.
- The running ISO must never contain OpenAI APIs, accounts, Codex, credentials, or cloud dependencies.

</specifics>

<deferred>
## Deferred Ideas

- Diskless offline package installation, graphical startup, comedy UI, firmware/media matrix, and size optimization remain in their dedicated later phases.

</deferred>
