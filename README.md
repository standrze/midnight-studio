# midnight-studio

A native Swift command-line workbench for Midnight model inspection and control.
The default interface uses loom and weft in your terminal. Studio connects to a
Midnight server and can own one local Midnight process for interactive model
loading. Training, calibration, and quantization belong in Afterglow.

macOS 14+ and Swift 6.4+ are required.

```sh
./build.sh
./run.sh --help
./run.sh --midnight-url http://127.0.0.1:8080
./run.sh models --model-root /path/to/models
swift test
python3 Tests/terminal-smoke.py .build/debug/midnight-studio
```

Commands: `models` lists local checkpoints, `status` shows runtime state,
`inspect` reads topology, and `trace --request FILE` captures activations.
Use `--compare-url` and `--comparison` to inspect a second configured server.
Set `MIDNIGHT_API_KEY` when the server requires authentication.

Interactive keys: arrows select and scroll; Enter loads; `u` unloads; `e` selects
an external server; `i` inspects; `a` records the next chat; Space replays;
`l` lists recordings; `s` shows status; `p` saves a profile; `r` refreshes;
Esc goes back; `q` quits and releases the process owned by the session.

This package ships only `midnight-studio`. It contains no browser interface,
HTTP server, training worker, model weights, or generated data.
