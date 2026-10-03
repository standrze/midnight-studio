# Midnight Studio native workers

This separate SwiftPM package owns Studio's LoRA training and streamed-shard
quantization worker. The parent web package uses it as a child process and has
no MLX dependency. General checkpoint quantization lives in the sibling
`midnight-quantization` project; research training lives in the sibling `training`
project. All consume Midnight's runtime libraries.

From the Studio project root:

```bash
./Workers/build.sh
./Workers/test.sh
```

The wrappers currently support macOS 15+ with Swift 6.3 and the Metal compiler.
They use `../../midnight` relative to this package, or `MIDNIGHT_RUNTIME_PATH`
for another checkout. Midnight's shared build helper prepares this package's
dependencies with the reviewed runtime patches and puts `mlx.metallib` beside
`midnight-studio-worker` in `Workers/.build/release`. The test wrapper also
places the matching Metal library inside the XCTest bundle before running fixtures.

Set `STUDIO_WORKER_BUILD_CONFIGURATION=debug` for a debug build and
`STUDIO_WORKER_BUILD_JOBS` to change the default of two build jobs. Studio
discovers release workers first, then debug workers; `--trainer-binary PATH`
overrides discovery. For raw SwiftPM commands in a nonstandard layout, export
`MIDNIGHT_RUNTIME_PATH` and run the build wrapper once to prepare dependencies
and the Metal library before building or testing directly.

The tiny native tests compare streamed conversion with full conversion and
verify that fine-tuning and CPT both produce reloadable adapters. No checkpoint
download is required for these fixtures.

Licensing and shared-runtime attribution are covered in the parent
[third-party notices](../THIRD_PARTY_NOTICES.md).
