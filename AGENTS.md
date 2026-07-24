# Repository instructions

- All Xcode builds must use the project's normal code-signing configuration. Never disable or bypass code signing (for example, with `CODE_SIGNING_ALLOWED=NO`).
- Never run Xcode or `xcodebuild` inside the filesystem sandbox. Request escalated execution immediately for every Xcode command because Xcode requires access to simulator, cache, log, and signing services outside the workspace.
- Treat `project.yml` as the source of truth for generated Xcode project and Info.plist settings. Do not hand-edit generated `.xcodeproj` or Info.plist files; update `project.yml` and rerun `xcodegen generate` instead.
- Do not create per-task Xcode DerivedData directories in `.build`, `/tmp`, or elsewhere. Use and reuse Xcode's standard shared DerivedData location.
- For bug fixes, where an automated regression test is practical, first add a test that reproduces the issue and confirm that it fails. Then implement the fix and rerun that test to prove it passes. Run any broader relevant test suite afterward.
