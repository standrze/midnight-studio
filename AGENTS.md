# Studio

Keep this package focused on the native terminal model workbench. Serving belongs
in Midnight; training, conversion, calibration, and quantization belong in
Afterglow. Do not reintroduce web assets, HTTP server targets, native training
workers, model weights, or generated data.

Use four-space indentation, 120-column Swift formatting, and lowercase loom/weft.
Run `Scripts/format-swift.sh` and `Scripts/check-swift-format.sh` for Swift edits.
Verify with `swift test` and the real PTY smoke test in `Tests/terminal-smoke.py`.
