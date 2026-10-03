# Midnight Studio

Midnight Studio is a Swift command-line workbench for Midnight, using **loom** for
rendering and **weft** for terminal sessions, keyboard events, and resize handling.
It requires Swift 6.4 and macOS 14 or later.

```sh
./run.sh
./run.sh models
./run.sh status --midnight-url http://127.0.0.1:8080
./run.sh inspect > topology.json
./run.sh trace --request capture-request.json > capture.json
./run.sh inspect --compare-url http://127.0.0.1:8081 --comparison
```

The default command opens a terminal model catalog. Arrows select a checkpoint;
Enter loads its saved profile or discovered defaults. `u` unloads, `e` returns to
the external connection, `p` saves the selected profile, `i` displays model
topology, and `s` displays runtime state. Inspection results scroll with arrows;
Esc returns to the catalog. `r` refreshes and `q` exits. Shutdown restores terminal
settings and stops only the Midnight process this session owns.

Script commands return JSON and do not create a terminal session or start a model
process. A trace request is an existing Midnight `/v1/inspector/trace` JSON object,
limited to 32 KiB. Use shell redirection to save captures and topology snapshots.
`--comparison` uses the origin configured by `--compare-url`. All connection,
model-root, binary, and state-directory settings continue to use the existing
Studio configuration. `--help` lists the terminal commands.

Training, calibration, and quantization belong to **Afterglow** (`../afterglow`).
Wick and Training remain the original projects. Studio's new terminal UI does not
reimplement those operations. Existing browser preparation and native worker
features remain available during migration; they have not been ported to terminal
forms. Press `i` to see stacked layers built from separate component blocks. Block
length uses one shared stored-byte scale, computed from reported tensor shapes and
dtypes (including packed quantized weights, scales, and biases). The legend names
attention, convolution, experts, feed-forward, and normalization/other storage.
Incomplete or inconsistent metadata displays “size unavailable”. Narrow terminals
omit exact numeric labels while preserving the block scale.

Press `a` to arm a recording of the **next matching chat request** sent to the same
Midnight server by OnoSendai or another chat application. Studio does not ask for a
prompt or start inference. It shows waiting and recording states, then saves the
completed capture automatically. Press `a` again or Esc to stop recording; the
external chat continues. A recording captures the last uncached prompt position
and up to 32 generated input positions at supported layer-input/after-attention
sites, within the server's byte and layer limits. Cached prompt positions and a
final token that has not been evaluated may have no measurements. Unsupported
models report Midnight's reason. Other requests are not recorded.

Press `m` for a separate Model Information screen. It shows the loaded model’s
architecture, layer layouts, hidden width, attention/KV heads, expert routing
geometry, context limits, quantization and storage dtypes. Memory rows distinguish
stored weights, active/cached/peak MLX allocator usage and the configured budget.
On Apple Silicon this is unified memory; total system GPU usage and dedicated
VRAM capacity are not reported. Decode and prefill tokens/sec are the latest
backend completion report for the current model, including headless Midnight;
they appear after generation rather than claiming a live benchmark. Runtime
measurements refresh every two seconds while visible. `r` refreshes immediately,
`i` returns to layers, and Esc returns to the previous screen/replay. Architecture
snapshots are reused only for the same resident model generation; absent data is
labelled Not reported. This screen submits no prompt or model mutation.

Space plays or pauses; left/right arrows step through recorded tokens, and `v`
cycles component activity and residual observation views. Option 1's crisp capacity
blocks use a shared stored-weight scale, padded layer numbers, and roomier rows.
New recordings light attention and dense/shared feed-forward bars from their own
actual projection output RMS, on fixed recording-wide scales per kind. Separate
expert ID tiles show selected routed experts and their normalized weights; tile
size does not encode storage. Router/norm/unmeasured capacity stays dim. Individual
weights/neurons, routed expert output vectors, and causal importance are not measured.
Older recordings explicitly retain whole-layer residual brightness. Playback and
saved-library replay make no model requests. JSON logs retain the new measurements.

Each completed recording saves model topology and captured measurements as
`<state-directory>/recordings/<UUID>.json`; the default directory is
`~/.midnight/studio/recordings`. A JSONL history at
`<state-directory>/recordings.jsonl` records timestamp, model, recording ID, status,
and the artifact path. Files use private permissions. Artifacts include captured
token labels and the bounded output window; they contain no authorization headers,
connection credentials, or complete chat prompt. Save or log failures are shown
in the status line. Press `l` to browse saved recordings, then arrows and Enter to
load one for offline replay. Esc returns to the catalog. JSON capture files remain
available after quitting Studio; Midnight's temporary session state does not need
to survive.

Set `MIDNIGHT_API_KEY` in Studio's launch environment to use an authenticated
Midnight listener. Studio sends it as a bearer header without writing it to capture
files, history, or command arguments. The independent `trace --request FILE`
command still supports explicit inspection requests for scripts.


The browser interface is explicitly selected with `./run.sh web`; it no longer
starts by default. Its existing assets and tests are retained. The legacy
`midnight-inspector` executable also uses the new command interface.

Verify with `./build.sh`, `swift test`, and `node --test Tests/*.test.cjs`.
The terminal owns its alternate screen and restores it on quit, handled signals,
and errors. SIGKILL cannot run process cleanup.

## Retained browser interface

The following reference describes `./run.sh web` and the existing worker features.
All browser launch examples below require the `web` subcommand.

## Model preparation

Open **Prepare models** at <http://127.0.0.1:8090/prepare> for Hugging Face
downloads, quantization, LoRA fine-tuning, and adapter-based continued pretraining.
All model computation runs in native Swift/MLX child processes on this Mac.

Build the optional native workers from the Studio directory:

```bash
./Workers/build.sh
MODEL_RUNNER_BUILD_PRODUCT=model-runner-quantize ../midnight-quantization/build.sh
./run.sh
```

Each worker needs its matching `mlx.metallib` beside its executable. The build
wrappers prepare native dependencies and build this resource using Midnight's
shared build helpers. See [native worker setup](Workers/README.md).
Studio discovers `midnight-studio-worker` in `Workers/.build` and
`model-runner-quantize` in the sibling quantization project's `.build`, preferring
release over debug. Installed workers in `~/.midnight/bin` are also supported.
Explicit `--trainer-binary PATH` and `--quantizer-binary PATH` options override
discovery. The Studio worker handles both LoRA training and individual streaming
quantization shards. All native workers are optional for inspection and controls.

### Hugging Face and disk-efficient quantization

Enter an `owner/model` repository ID and a branch, tag, or commit. Studio resolves
the revision to a commit, downloads safetensors and model/tokenizer sidecars,
and saves source provenance. It checks advertised file sizes and LFS SHA-256
hashes. Private/gated repositories use `HF_TOKEN` from Studio's launch environment;
grant repository access on Hugging Face first. The token is not accepted by the
browser or stored in job history. Python checkpoint code is never executed.

**Stream & quantize** downloads one source shard, converts it, saves the Q4
output shard, then deletes the temporary source before downloading the next.
Peak disk use is the growing quantized checkpoint plus one source shard and
small metadata. It is shard streaming, not byte-range/tensor streaming: a
single-file checkpoint still needs that entire source file temporarily. Memory
use is also bounded by shard conversion, not a fixed small-memory guarantee.
Streamed downloads do not populate a full Hugging Face weight cache.

This path supports unquantized dense `llama`, classic `mistral`, `qwen2`, and
`qwen3` models whose tensors match the native model. It uses G64 affine Q4,
with ScaleSearch on linear matrices or standard affine calibration. Embeddings
use standard affine Q4. Ineligible widths remain unquantized. It verifies full
tensor coverage and publishes the checkpoint only after all shards finish.
MoE models, Laguna, multimodal models, quantized sources, and architectures
requiring cross-shard transformations do not use this path.

**Download checkpoint** retains the original model. **Local quantization** uses
the existing architecture-aware Q4/Q8 converter, keeps the original checkpoint,
and requires an unquantized source. Unsupported architectures fail with a worker
log. Both download modes currently require root-level safetensors; GGUF and
pickle/PyTorch `.bin` weights are not imported.

Downloaded and quantized models are added to `~/.midnight/models/studio` by
default and appear in Model controls. Override with `--studio-library PATH`; this directory
is included even when custom `--model-root` options are supplied.

### Fine-tuning and CPT

Upload separate train and validation JSONL files containing one `{"text":"…"}`
object per line. Each split supports up to 2 MiB and 10,000 examples. Studio
rejects empty/malformed rows, duplicates, and train/validation overlap. The
worker validates actual token counts before training and rejects examples
outside 2–the configured maximum tokens; it never silently truncates them.

- **Fine-tune:** complete prompt-and-answer examples, already rendered with the
  model's appropriate formatting. The objective covers the full sequence,
  including prompt tokens; assistant-only masking is not implemented.
- **CPT:** plain domain-text examples with full-sequence next-token loss.
  This is LoRA domain adaptation, not full-weight continued pretraining.

Both train LoRA adapters (QLoRA with a supported quantized base), with batch size
1, configurable steps, learning rate, rank, layers, and sequence limit. Actual
LoRA compatibility is checked before the first optimizer step. Loss and validation
metrics stream into the job log; no quality gain is assumed from job completion.
The output contains `adapter_config.json`, `adapters.safetensors`, and a training
manifest. **Load trained model** starts its original base with the adapter in
Model controls. The base checkpoint must remain available.

One preparation job runs at a time. **Cancel current job** terminates only the
owned worker and removes temporary streaming files. Inference/external training
can still consume memory; unload models separately when needed. Normal Studio
shutdown cancels its job. After a crash, history marks active jobs interrupted;
there is no automatic resume or optimizer-state restore. Partial local-conversion
and training artifacts stay in `~/.midnight/studio/studio/runs` for diagnosis.
Interrupted hidden streaming folders may need manual cleanup. The latest 50 jobs and up to
100 datasets are recorded locally. There is no automatic upload or publishing.

Tests from Studio: `swift test`, `node --test Tests/*.test.cjs`, and
`./Workers/test.sh`. Tiny native fixtures compare
streamed and full conversion tensors and reload both trained adapter modes.

| Studio route | Purpose |
| --- | --- |
| `GET /api/studio/state` | Jobs, datasets, worker availability, output library |
| `POST /api/studio/jobs` | Start download, stream-quantize, quantize, finetune, or cpt |
| `POST /api/studio/cancel` | Cancel the active job |
| `POST /api/studio/datasets` | Validate and store train/validation JSONL |
| `POST /api/studio/load-adapter` | Load a completed training job's base and adapter |

Mutations accept JSON and reject foreign browser origins. Dataset uploads have
a 5 MiB request limit; other Studio mutations have a 32 KiB limit. Browser input
cannot choose worker executables, CLI arguments, arbitrary local model paths,
or output paths.

## Inspection and model controls

A local Hummingbird web app for exploring the model loaded by Midnight, inspecting
its layer structure, comparing two running models, and managing a local model
process. The layer explorer remains at `/`; a separate **Model controls** page
lives at <http://127.0.0.1:8090/control>.

Start the sibling Midnight runtime with a local checkpoint:

```bash
../midnight/run.sh --model /absolute/path/to/mlx-model --host 127.0.0.1 --port 8080
```

In another terminal, from the Studio directory:

```bash
./run.sh
```

Open <http://127.0.0.1:8090>. The companion package requires Swift 6.1 or newer
and macOS 14 or newer; see the [Midnight README](../midnight/README.md) for the
runtime's requirements. The native worker package requires Swift 6.3 and macOS 15 or newer.

## Model controls

Open <http://127.0.0.1:8090/control> to browse local checkpoints, save model
profiles, and load or unload a model. Profiles include the served model name,
context window, output token ceiling, prefill chunk size, compute engine, and
KV compression where the architecture supports it. A saved profile is stored
locally; **Load model** applies the selected profile by starting a new Midnight
process. Changing a loaded model's settings requires reloading it.

The controls page discovers checkpoints beneath `~/.midnight/models`
and the sibling Midnight checkout's `tmp/models`. It starts the sibling runtime's
`.build/release/midnight` executable (falling back to its debug build, then
`~/.midnight/bin/midnight-runner`) on `127.0.0.1:8082`.
Build Midnight first using `../midnight/build.sh` if the executable is unavailable. Override
these fixed launch settings when starting Studio:

```bash
./run.sh \
  --midnight-binary /absolute/path/to/midnight \
  --model-root /absolute/path/to/models \
  --model-root /another/model/directory \
  --state-directory /absolute/path/to/inspector-state \
  --managed-port 8082
```

Explicit `--model-root` options replace the two default search roots. Profiles
and preparation state normally live in `~/.midnight/studio`, outside the source checkout.
Checkpoint configuration and weights are not edited. Loading is asynchronous;
the page shows startup status and recent process logs until Midnight is ready.
Unavailable or unsupported checkpoints remain visible with an explanation.

Studio starts in **external** mode, using the existing `--midnight-url`
server. Loading through controls switches the layer explorer's primary
connection to the managed process. **Use external server** switches back to
the launch-configured external server and stops the managed process. Unloading
releases model memory while the managed runner stays running on the same port. Loading another model reuses that runner. A separately started Midnight server
is never stopped or adopted. The optional comparison connection is unchanged.
If both external and managed models are running, both use system memory.
Exiting Studio also stops its managed Midnight process. Live model controls require a runner with `--idle` and the `/v1/runtime` API. A load or unload waits for the previous operation to finish; a failed model load keeps the runner available for recovery.

To compare models, start a second Midnight process on another port and connect it:

```bash
./run.sh \
  --midnight-url http://127.0.0.1:8080 \
  --compare-url http://127.0.0.1:8081 \
  --port 8090
```

Both model processes need enough memory for their loaded checkpoints. The app
reports the structure and activation support supplied by each running model.
You can also choose **Save structure**, load another model in Midnight, refresh,
and choose **Compare a saved model**. Saved snapshots contain topology and tensor
metadata, so the original checkpoint does not need to remain in memory.
An older Midnight process must be rebuilt and restarted to expose the Inspector
API. Connection failures appear in the app with recovery instructions.

## HTTP routes

| Companion route | Midnight route |
| --- | --- |
| `GET /api/connections` | Lists the server origins configured at launch |
| `GET /api/model?connection=primary` | `GET /v1/inspector/model` |
| `POST /api/trace?connection=primary` | `POST /v1/inspector/trace` |
| `GET /api/control/models` | Lists discovered local checkpoints and their defaults |
| `GET /api/control/state` | Active connection, process status, saved profiles, and recent logs |
| `POST /api/control/profile` | Saves a model profile without changing the running process |
| `POST /api/control/load` | Starts the managed runner if needed, then loads or replaces its model using a profile |
| `POST /api/control/unload` | Releases the model while keeping the managed runner available; accepts `{}` |
| `POST /api/control/external` | Returns to the configured external server; accepts `{}` |

Use `connection=comparison` for the optional second process. Trace requests are
JSON objects such as `{"question":"Why is the sky blue?","maxTokens":32}`.
Midnight reports supported capture points and validates the model-specific
limits. The companion forwards upstream JSON errors, including a busy model.

Model profile requests are JSON objects with `modelID`, `servedModelName`,
`contextLength`, `maximumTokens`, `prefillStepSize`, `kvCompression`, and `engine`.
Use the model ID and defaults returned by the catalog. The browser cannot supply
an executable, arbitrary model path, server destination, or extra CLI arguments.
Control mutations require `application/json` and reject foreign browser origins;
the server validates profile values and reports operation conflicts.

Activation capture currently supports GPT-OSS, Mistral3/Ministral3, and native
Laguna. It uses fresh caches and temporary observation hooks at each layer's
input and after-attention residual, before normalization. Select a token and a
layer to inspect its RMS, maximum absolute value, and 16 contiguous channel-group
RMS summaries. These groups are not individual neurons or attention weights.
The rendered prompt is limited to 256 tokens; output is limited to 64 tokens
and the server's configured ceiling. This diagnostic greedy run is slower than
ordinary chat and displays raw generated text, including formatting tokens;
a short run can end before the final answer. Observation hooks are restored
before the model serves another request.

Layer blocks and tensor shapes come from the loaded module graph. Head/expert
counts and attention types come from checkpoint configuration. Storage sizes
are tensor bytes, not total process memory; packed quantized element counts
must not be interpreted as logical parameter counts. Matching layer indices
across different models do not imply matching learned functions.

The web server binds to `127.0.0.1` and serves only its bundled HTML, JavaScript,
and CSS. Server origins are configured with CLI options; requests cannot supply
arbitrary upstream addresses. Question requests are limited to 32 KiB and
inspection responses to 8 MiB. No external web assets are required.

## Development checks

```bash
./build.sh
swift test
node --test Tests/*.test.cjs
```

Tests cover the configured connection mapping, trace forwarding, upstream error
handling, request and response limits, bundled resource serving, profile
validation and persistence, managed process lifecycle, and primary connection
switching. They do not need a loaded model.

## Standalone launch

Studio runs as a separate application. Start it from its own project directory and
connect it to a running Midnight server:

```bash
./run.sh \
  --midnight-url http://127.0.0.1:8080 \
  --port 8090
```

Open http://127.0.0.1:8090. Use Studio's `--port` option to choose another web
port. You can also start Studio before loading a model and use **Model controls**
to launch its managed Midnight process.

The architecture overview identifies attention and convolution blocks from module
paths and declared layer types. Select a block to inspect it; use Compare with a
second connection or saved structure for side-by-side summaries. Checkpoint context
limits and runner settings are separate. Missing metadata remains Unknown. Native
LFM2 feed-forward layers are labeled SwiGLU from the runtime implementation.

## License

Studio source uses [Apache License 2.0](LICENSE). See
[third-party notices](THIRD_PARTY_NOTICES.md) for web and native-worker dependencies.

Inspection requests explicitly select the current primary layer (or its first
available layer), the final rendered prompt token, and bounded output positions.
The server's advertised sites, model ID, and runtime generation guard each capture.
Other layers and uncaptured token positions remain unmeasured in the activity view.
Summary capture is used for the existing inspector display; raw vectors belong to
explicit raw-inspection clients.
