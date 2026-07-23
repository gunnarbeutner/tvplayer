# Repository instructions

- All Xcode builds must use the project's normal code-signing configuration. Never disable or bypass code signing (for example, with `CODE_SIGNING_ALLOWED=NO`).
- Never run Xcode or `xcodebuild` inside the filesystem sandbox. Request escalated execution immediately for every Xcode command because Xcode requires access to simulator, cache, log, and signing services outside the workspace.
