## Summary

<!-- What this PR changes and why. Link related issues (e.g. `closes #123`). -->

## Type of change

- [ ] Bug fix
- [ ] Feature
- [ ] Breaking change (source-breaking public API, e.g. a new case on a public enum)
- [ ] Docs
- [ ] Refactor / chore / build / tests
- [ ] Demo app only

## Checklist

- [ ] Builds and tests pass locally (`swift build && swift test`)
- [ ] Tests added/updated for the change
- [ ] Code follows the coding style in `AGENTS.md` (no abbreviated names, 100-character lines,
      parameter layout, modifier order)
- [ ] OS-gated APIs stay behind `@available` / `#available` and the `XCODE26-SDK` / `OS26-FLOOR`
      guards, so the macOS 15 / iOS 18 floor is unchanged
- [ ] Demo app builds in Xcode (both `RailtracksSwiftDemo` and `RailtracksSwiftDemoOS27`) if
      public API or demo code changed
- [ ] `RailtracksSwiftRAG` still imports neither `RailtracksSwift` nor Conduit, if it changed
- [ ] `README.md` (current state only) and `AGENTS.md` updated if user-facing behavior or
      architecture changed
- [ ] Breaking changes describe what clients must change

## Notes

<!-- Optional: usage examples, screenshots or screen recordings of the demo, performance or
     security considerations, OS / Xcode versions tested on. -->
