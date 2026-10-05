# GuiAssert-Tavus

Tavus talking-head plugin for [GuiAssert]. Implements GuiAssert's
`TalkingHeadProvider` contract by speaking the commercial
[Tavus v2 REST API](https://docs.tavus.io/api-reference/video/create-video)
— no Python, no model weights, no GPU toolchain. Pure-Nim HTTP client.

Tavus is a commercial AI-avatar service distinguished by its
real-time conversational mode (the only one in the commercial pack
that offers low-latency two-way avatars). This plugin targets the
**pre-rendered** `v2/videos` endpoint — the analog of D-ID, HeyGen,
and Synthesia — so that GuiAssert's existing one-shot
narration-to-MP4 contract maps cleanly. The conversational-video API
is a different surface and is not exercised here.

Compared with the local-ML siblings (`GuiAssert-Wav2Lip`,
`GuiAssert-MuseTalk`, `GuiAssert-SadTalker`) and the sibling
commercial plugins (`GuiAssert-Did`, `GuiAssert-HeyGen`,
`GuiAssert-Synthesia`), Tavus trades a recurring subscription fee for
zero install cost and zero local compute.

[GuiAssert]: ../GuiAssert/

## Layout

```
GuiAssert-Tavus/
├── flake.nix                            nim + ffmpeg-full + openssl + cacert devShell (no Python)
├── gui_assert_tavus.nimble              nimble package
├── src/
│   └── gui_assert_tavus.nim             plugin implementation (TalkingHeadProvider)
└── tests/
    ├── fixtures/
    │   ├── README.md                    fixture provenance
    │   └── narration.wav                ~3.5 s test WAV (cache-key ingredient only)
    └── ttavus.nim                       pure + mock-server tests + `-d:tavusLive` gated live test
```

## Cost of setup

| Resource | Approx.                                                                                                                                                                                                          |
| -------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Disk     | None beyond Nim build artefacts                                                                                                                                                                                  |
| Network  | Per-render JSON + MP4 download, modest                                                                                                                                                                           |
| Time     | First call ~minutes (Tavus pre-rendered videos are slow)                                                                                                                                                         |
| Dollars  | **Starter $59/mo** (~100 min conversational + ~10 min pre-rendered), **Growth $300-600/mo**, **Enterprise custom**. Within a plan, renders are quota-metered (minutes/month) rather than pay-as-you-go per call. |
| API key  | Yes — `TAVUS_API_KEY` env var                                                                                                                                                                                    |

Pricing is set by Tavus; see [their pricing page](https://www.tavus.io/pricing)
for current numbers and the per-tier monthly render quota. The
Starter tier's pre-rendered quota is intentionally small (~10 min) —
the platform is primarily marketed around the real-time
conversational API. Plan accordingly when wiring this plugin into a
CI pipeline.

## Setup

```sh
nix develop
export TAVUS_API_KEY="..."   # from https://platform.tavus.io
```

No install script. No model weights. The `nix develop` shell
provisions Nim, ffmpeg (for fixture synthesis + ffprobe validation),
OpenSSL, and a CA bundle so TLS to `tavusapi.com` works without
user setup.

## Important deviation from the generic contract

GuiAssert's `TalkingHeadProvider.generate` contract is
`generate(narrationWav, outputMp4, opts)` — i.e. the audio is provided
as a _pre-rendered WAV_. Tavus's `POST /v2/videos` endpoint does NOT
accept uploaded audio: it takes a `script` string and the selected
replica synthesises the voiceover itself. This plugin therefore:

- IGNORES the `narrationWav` parameter for the actual API call.
- REQUIRES `opts.providerSettings["script_text"]` to be set to the
  string Tavus should speak. `generate` raises `TalkingHeadError`
  if missing or empty.

The `narrationWav` is still incorporated into the on-disk cache key,
so consumers can carry per-session uniqueness in the WAV (e.g. by
passing a unique audio file per render call). The cache key also
folds in `script_text`, `replica_id`, and `video_name`, so two
different scripts on the same WAV do not collide.

The same deviation applies to the sibling HeyGen and Synthesia
plugins — all three commercial providers synthesise their own voice
from text rather than honouring uploaded audio.

## Authentication

Tavus authenticates with a custom `x-api-key` HTTP header:

```
x-api-key: 0123abcd-your-tavus-key
```

HTTP header names are case-insensitive on the wire, but Tavus's docs
spec the lowercase form (`x-api-key`) and this plugin emits it
verbatim. The plugin pins the raw-key form; the pure tests guard
against accidental "fixes" that would prepend a `Bearer ` or
`Basic ` prefix.

## Wiring into a runner

```nim
import gui_assert/talking_head
import gui_assert_tavus

let reg = newRegistry()         # registry pre-populated with `stock_avatar`
registerTavus(reg)              # now `tavus` is also registered

var opts = TalkingHeadOpts(
  avatarImagePath: none(string),    # unused by Tavus (replica is server-side)
  device: "auto",
  cacheDir: some("/tmp/tavus-cache"),
  providerSettings: %*{
    "script_text": "Hello from GuiAssert Tavus.",
    "replica_id": "r79e1c033f",        # public stock replica
    "video_name": "Demo render",
    # api_key falls back to $TAVUS_API_KEY
  },
)
generateTalkingHead(reg, "tavus", narrationWav, outputMp4, opts)
```

### Configuration

All knobs live under `TalkingHeadOpts.providerSettings` (a `JsonNode`),
with environment-variable fallbacks where applicable:

| Setting       | YAML key      | Env fallback    | Default                  | Purpose                                                      |
| ------------- | ------------- | --------------- | ------------------------ | ------------------------------------------------------------ |
| `api_key`     | `api_key`     | `TAVUS_API_KEY` | _(none)_                 | Tavus API key.                                               |
| `api_base`    | `api_base`    | _(none)_        | `https://tavusapi.com`   | API endpoint. Override to point at a mock or staging server. |
| `script_text` | `script_text` | _(none)_        | _(none)_                 | **REQUIRED.** Script for Tavus to speak.                     |
| `replica_id`  | `replica_id`  | _(none)_        | `r79e1c033f`             | Tavus replica identifier (public stock or custom clone).     |
| `video_name`  | `video_name`  | _(none)_        | `GuiAssert Tavus render` | Display name for the rendered video.                         |

The provider name is `"tavus"`.

## API flow

The provider performs three sequential interactions per render (plus
poll round-trips):

1. `POST /v2/videos` — JSON body of the form documented in Tavus's
   quick-start:
   ```json
   {
     "replica_id": "r79e1c033f",
     "script": "Hello from Tavus.",
     "video_name": "Demo render"
   }
   ```
   The body is a flat object with snake_case keys — unlike
   Synthesia, there is no nested `input[]` array envelope. The
   response is a flat JSON object `{"video_id": "...", "status":
"queued", ...}` — no envelope wrapping (unlike HeyGen).
2. `GET /v2/videos/{video_id}` — polled every 10 s (15-minute
   timeout) until `status == "ready"`. Other terminal statuses are
   `error` and `deleted`, both treated as failures.
3. `GET <download_url>` — downloads the MP4 to disk. The CDN URL
   does not require the `x-api-key` header.

Authentication uses the Tavus-specific `x-api-key: <TAVUS_API_KEY>`
header on every API request. The CDN download is unauthenticated.

## Caching

The plugin reuses GuiAssert's generic on-disk cache
(`applyCache` + `cacheKeyFor`). Because Tavus's "avatar" is purely
server-side (a replica string, not a local file) and its "narration"
is purely server-side too (a `script_text` string, synthesised
remotely), the cache key folds the Tavus-specific knobs
(`script_text`, `replica_id`, `video_name`) into the device slot via
a SHA-1 prefix. Identical inputs short-circuit the API calls
entirely on the second invocation. This is doubly important here
because every cache hit avoids spending render quota.

The mock-server test validates the cache-hit path: a second
`generate` call against the same inputs issues zero HTTP requests.

## Tests

```sh
# Pure unit tests + mock-server integration test — no network.
nim c -r --threads:on --hints:off --path:src --path:../GuiAssert/src tests/ttavus.nim

# Live end-to-end against tavusapi.com — requires TAVUS_API_KEY.
nim c -d:tavusLive -r --threads:on --hints:off --path:src --path:../GuiAssert/src tests/ttavus.nim
```

The `--threads:on` flag is required because the mock-server test
spawns a thread that drives `asyncdispatch.poll()` while the main
thread issues blocking `std/httpclient` calls.

The mock-server suite spins up a `std/asynchttpserver` on a random
localhost port, records every request the provider issues (method,
path, headers, body), and asserts:

- Every API request carries the `x-api-key` header set to the test
  key (`DUMMY_KEY`) — raw, with no `Bearer ` prefix.
- `POST /v2/videos` carries exactly the JSON shape Tavus documents
  (flat snake_case `replica_id` + `script` + `video_name`, no
  nested `input[]` envelope).
- Polling cadence is respected (the provider does not short-circuit
  while status is `queued` or `generating`).
- The downloaded MP4 is byte-identical to the mock's golden file.
- A second call hits the on-disk cache and issues zero HTTP traffic.
- Changing `script_text` forces a fresh render (different cache key).

The live test fails the run if `TAVUS_API_KEY` is missing — per
project policy, there are no graceful skips. CI that does not want
to spend real Tavus quota simply compiles without `-d:tavusLive`.

## Conversational-video API

Tavus also exposes a real-time conversational-video API
(WebRTC-based, two-way) on its `/v2/conversations` surface. That is
a fundamentally different shape (no one-shot create-poll-download
cycle; the avatar speaks live) and does not fit GuiAssert's
narration-to-MP4 contract. This plugin therefore targets only the
**pre-rendered `v2/videos`** endpoint. A future GuiAssert contract
extension could expose the conversational mode separately.

## License

MIT — see `LICENSE`. Tavus itself is a commercial service governed
by its own [terms of service](https://www.tavus.io/legal/terms);
the plugin only speaks the public REST API.

## Native contributor hooks

The plugin remains a pure Nim HTTP client. Its developer shell also supplies
native Python, UV, Prek and the portable formatters from its existing pin.
The committed hook config runs the seven standard checks and actual public lint.

Select the verified matching managed-hook engine as `REPROBUILD_REPRO`.
From this repository root, bootstrap its genuine managed layout first:

```sh
direnv exec . nix develop --no-update-lock-file --no-write-lock-file --command "$REPROBUILD_REPRO" hooks ensure --vcs .
direnv exec . nix develop --no-update-lock-file --no-write-lock-file --command python3 tools/install-canonical-hooks.py --repro "$REPROBUILD_REPRO"
direnv exec . nix develop --no-update-lock-file --no-write-lock-file --command prek run --all-files
```

The installer verifies the complete matching engine and dispatcher bytes,
preserves known local hooks and pre-push bodies/modes, and refuses unknown or
external hook ownership. Its installed native Prek body persistently selects
canonical upstream hook implementations even when the caller selector is absent.
System Python selection uses the owning native interpreter without managed
Python downloads. Linux qualification does not establish native Windows tools.
Original test and required live API prerequisites remain unchanged.
