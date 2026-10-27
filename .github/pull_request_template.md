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
- [ ] Code follows the coding style in `AGENTS.md` (no abbreviated names, one statement per line,
      parameter-list layout: one line if it fits in 100 characters, otherwise one per line;
      modifier order)
- [ ] OS-gated APIs stay behind `@available` / `#available`, so the macOS 15 / iOS 18 floor is
      unchanged. An API that exists only in the OS 27 SDK also goes inside `#if compiler(>=6.4)`
      with an `// XCODE26-SDK:` comment (so the package still builds with Xcode 26), and its
      `#available(macOS 27, iOS 27, *)` check gets an `// OS26-FLOOR:` comment (so it can be
      found and removed when OS 26 support is dropped)
- [ ] Demo app builds in Xcode (both `RailtracksSwiftDemo` and `RailtracksSwiftDemoOS27`) if
      public API or demo code changed
- [ ] `RailtracksSwiftRAG` still imports neither `RailtracksSwift` nor Conduit, if it changed
- [ ] `README.md` and `AGENTS.md` updated if user-facing behavior or architecture changed.
      The README describes the library as it is now; history, phases and migration notes go in
      the PR description or release notes instead
- [ ] Breaking changes describe what clients must change

## Notes

<!-- Optional: usage examples, screenshots or screen recordings of the demo, performance or
     security considerations, OS / Xcode versions tested on. -->
