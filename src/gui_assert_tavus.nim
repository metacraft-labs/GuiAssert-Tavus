## Tavus talking-head plugin for GuiAssert.
##
## Implements GuiAssert's `TalkingHeadProvider` contract on top of the
## commercial Tavus v2 REST API
## (https://docs.tavus.io/api-reference/video/create-video). Like the
## sibling D-ID, HeyGen, and Synthesia plugins this is a pure-Nim HTTP
## client — no Python, no model weights, no GPU toolchain. Like HeyGen
## and Synthesia, Tavus synthesises its own voice from a text input on
## `POST /v2/videos`; there is no audio-upload mode in the pre-rendered
## flow.
##
## ## Wire shape
##
##   * `tavusProvider()` builds a `TalkingHeadProvider` value with
##     `name = "tavus"`, an `isAvailable` check (is `TAVUS_API_KEY`
##     set?), and a `generate` proc that performs the create / poll /
##     download cycle.
##   * `registerTavus(reg)` is the one-liner plugin registration entry
##     point.
##
## ## Important deviation from the generic contract
##
## The `TalkingHeadProvider.generate` contract is
## `generate(narrationWav, outputMp4, opts)` — i.e. the *audio is
## provided as a pre-rendered WAV*. Tavus's `POST /v2/videos` endpoint
## does NOT accept uploaded audio; it takes a `script` string and the
## chosen replica synthesises the voiceover internally. This plugin
## therefore:
##
##   * IGNORES the `narrationWav` parameter for the actual API call,
##     and
##   * REQUIRES `opts.providerSettings["script_text"]` (a string) to be
##     present.
##
## The `narrationWav` parameter is still hashed into the cache key, so
## consumers can carry per-session uniqueness in the WAV (e.g. by
## passing a unique audio file per render call). This keeps the cache
## key compatible with the rest of the GuiAssert ecosystem while
## making the Tavus plugin a drop-in for the same call sites the
## local-ML plugins use.
##
## ## Configuration
##
## All knobs are read from `TalkingHeadOpts.providerSettings` (a
## JsonNode), falling back to environment variables / sensible
## defaults:
##
##   * `api_key` — Tavus API key. Falls back to `$TAVUS_API_KEY`.
##     `isAvailable()` returns false when neither is set.
##   * `api_base` — API base URL. Defaults to `https://tavusapi.com`.
##     Tests point this at a local `std/asynchttpserver` mock so the
##     full create / poll / download cycle is exercised without
##     network.
##   * `script_text` — the script Tavus should speak. REQUIRED;
##     `generate` raises `TalkingHeadError` if missing/empty.
##   * `replica_id` — Tavus replica (avatar/clone) identifier.
##     Defaults to `r79e1c033f` (a public stock replica documented in
##     the Tavus quick-start).
##   * `video_name` — display name for the rendered video. Defaults to
##     `GuiAssert Tavus render`.
##
## ## API flow
##
##   1. `POST /v2/videos` (JSON) — creates the video job. The JSON
##      body is a flat object carrying `replica_id`, `script`, and
##      `video_name`. The response is a flat JSON object with
##      `video_id` + `status` (no envelope).
##   2. `GET /v2/videos/{video_id}` — polled every `intervalMs` until
##      the status reaches `ready` (or `error` / `deleted`). Response
##      shape: `{"video_id": ..., "status": ..., "download_url":
##      "..."}`. The download URL is populated only when status is
##      `ready`. Honours a 15-minute timeout — Tavus renders take
##      several minutes for pre-rendered videos.
##   3. `GET <download_url>` — downloads the rendered MP4 to disk.
##      The download URL is served from Tavus's CDN and does NOT
##      require the auth header.
##
## ## Authentication quirk
##
## Tavus's authentication header is `x-api-key: <api_key>` — a custom
## header carrying the RAW key, with NO `Bearer ` prefix. This matches
## HeyGen's `X-Api-Key` style (HTTP header names are case-insensitive,
## but Tavus's docs spec the lowercase form so this plugin emits
## `x-api-key` verbatim).
##
## Errors at any step raise `TavusError` with the HTTP status code
## and (when present) the response body excerpt.

import std/[os, options, json, httpclient, sha1, strutils, times]

import gui_assert/talking_head

type
  TavusError* = object of TalkingHeadError
    ## Raised by the low-level HTTP entry points. Subclasses
    ## `TalkingHeadError` so the generic dispatch in
    ## `gui_assert/talking_head` can catch it uniformly.

const
  ProviderName* = "tavus"
  DefaultTavusApiBase* = "https://tavusapi.com"
  DefaultMaxPollSecs* = 900.0
    ## Tavus renders take several minutes; we give 15 minutes of
    ## slack before giving up. This is the per-request wall-clock
    ## cap on the polling loop, not the HTTP request timeout.
  DefaultPollIntervalMs* = 10_000
  DefaultTavusReplica* = "r79e1c033f"
    ## Tavus public stock replica. Documented in the v2 quick-start.
  DefaultVideoName* = "GuiAssert Tavus render"
  ApiKeyEnvVar* = "TAVUS_API_KEY"
  ApiBaseSetting* = "api_base"
  ApiKeySetting* = "api_key"
  ScriptTextSetting* = "script_text"
  ReplicaIdSetting* = "replica_id"
  VideoNameSetting* = "video_name"

# ---------------------------------------------------------------------------
# Pure helpers — testable without any network access.
# ---------------------------------------------------------------------------

proc tavusAuthHeader*(apiKey: string): HttpHeaders =
  ## Build the auth header table Tavus expects. Tavus uses a custom
  ## `x-api-key` header (NOT HTTP Basic auth, NOT a Bearer token).
  ## The docs spec the lowercase header name; we emit it verbatim
  ## even though HTTP header names are case-insensitive on the wire.
  ## We pin `Content-Type: application/json` alongside because every
  ## authenticated Tavus request from this plugin sends a JSON body
  ## (or, for `GET /v2/videos/{id}`, no body — the Content-Type is
  ## harmless on a GET).
  newHttpHeaders({"x-api-key": apiKey, "Content-Type": "application/json"})

proc buildCreateVideoBody*(replicaId, scriptText, videoName: string): JsonNode =
  ## Construct the JSON body for `POST /v2/videos`. Mirrors the
  ## documented v2 quick-start shape exactly: a flat JSON object
  ## with `replica_id` (snake_case), `script`, and `video_name`.
  ## Unlike Synthesia's nested `input[]` array, Tavus accepts a
  ## simple top-level body.
  result = %*{
    "replica_id": replicaId,
    "script": scriptText,
    "video_name": videoName
  }

proc resolveApiKey*(opts: TalkingHeadOpts): string =
  ## Order of precedence: `opts.providerSettings.api_key`, then the
  ## `$TAVUS_API_KEY` env var, then "" (signalling unavailability).
  if not opts.providerSettings.isNil and opts.providerSettings.kind == JObject:
    let n = opts.providerSettings{ApiKeySetting}
    if not n.isNil and n.kind == JString and n.getStr.len > 0:
      return n.getStr
  result = getEnv(ApiKeyEnvVar)

proc resolveApiBase*(opts: TalkingHeadOpts): string =
  ## Order of precedence: `opts.providerSettings.api_base`, then the
  ## `DefaultTavusApiBase` constant. Trailing slashes are stripped
  ## so downstream string-concatenation stays predictable.
  var base = DefaultTavusApiBase
  if not opts.providerSettings.isNil and opts.providerSettings.kind == JObject:
    let n = opts.providerSettings{ApiBaseSetting}
    if not n.isNil and n.kind == JString and n.getStr.len > 0:
      base = n.getStr
  while base.endsWith('/'):
    base.setLen(base.len - 1)
  result = base

proc resolveStringSetting(opts: TalkingHeadOpts, key, default: string): string =
  if not opts.providerSettings.isNil and opts.providerSettings.kind == JObject:
    let n = opts.providerSettings{key}
    if not n.isNil and n.kind == JString and n.getStr.len > 0:
      return n.getStr
  result = default

proc resolveScriptText*(opts: TalkingHeadOpts): string =
  ## Read `opts.providerSettings.script_text`. Tavus has no env-var
  ## fallback for the script — it is structurally part of the
  ## per-call payload. Returns "" when missing; the caller is
  ## expected to raise a `TalkingHeadError` in that case.
  resolveStringSetting(opts, ScriptTextSetting, "")

proc resolveReplicaId*(opts: TalkingHeadOpts): string =
  resolveStringSetting(opts, ReplicaIdSetting, DefaultTavusReplica)

proc resolveVideoName*(opts: TalkingHeadOpts): string =
  resolveStringSetting(opts, VideoNameSetting, DefaultVideoName)

proc shortHashOf(s: string): string =
  ## 16-hex-char SHA-1 prefix — used to fold the Tavus-specific
  ## knobs (script_text, replica_id, video_name) into the
  ## cache-key device slot. See `tavusCacheSalt`.
  let d = secureHash(s)
  let full = $d
  result = full[0 ..< 16].toLowerAscii

proc tavusCacheSalt*(device, scriptText, replicaId, videoName: string): string =
  ## Per-call cache discriminator. `cacheKeyFor`'s signature is fixed
  ## by the GuiAssert contract (avatar + narration + provider +
  ## device) — for Tavus the "avatar" is server-side (a replica
  ## identifier string), and the actual narration is the
  ## `script_text` string, so we fold the Tavus-specific knobs into
  ## the `device` slot. Two different script_text values for the
  ## same WAV therefore produce different cache entries; identical
  ## inputs short-circuit the API calls.
  ##
  ## Returned as `<device>|<sha1prefix>` so debug dumps stay legible.
  let mix = scriptText & "|" & replicaId & "|" & videoName
  result = device.toLowerAscii & "|" & shortHashOf(mix)

# ---------------------------------------------------------------------------
# HTTP client construction.
# ---------------------------------------------------------------------------

proc newTavusHttpClient*(apiKey: string, timeoutMs = 60_000): HttpClient =
  ## Build an `HttpClient` pre-configured with the Tavus `x-api-key`
  ## header. We pin `Connection: close` so each call opens a fresh
  ## TCP socket — this sidesteps the same `std/asynchttpserver`
  ## keep-alive race the sibling D-ID / HeyGen / Synthesia plugins
  ## document, and helps real-world upstream proxies that drop idle
  ## sockets during the polling sleep gap.
  let headers = newHttpHeaders({
    "x-api-key": apiKey,
    "Accept": "application/json",
    "Content-Type": "application/json",
    "User-Agent": "GuiAssert-Tavus/0.1 (+https://github.com/metacraft-labs/GuiAssert)",
    "Connection": "close",
  })
  result = newHttpClient(timeout = timeoutMs, headers = headers)

proc closeQuietly(client: HttpClient) =
  ## Best-effort close — swallows OSError from already-closed sockets
  ## so callers don't have to wrap every defer in a try.
  try: client.close()
  except CatchableError: discard

template withFreshClient(apiKey: string, body: untyped): untyped =
  ## Build a one-shot HttpClient, run `body` with it bound to
  ## `client`, and close it afterwards. The block-scoped name makes
  ## the per-call client easy to spot vs. any long-lived provider
  ## client. Used to dodge keep-alive issues in the mock server +
  ## upstream proxies.
  block:
    let client {.inject.} = newTavusHttpClient(apiKey)
    try:
      body
    finally:
      closeQuietly(client)

# ---------------------------------------------------------------------------
# Low-level HTTP entry points. Each one performs exactly one Tavus
# API call and raises `TavusError` on non-2xx responses. They are
# kept parameter-driven (apiBase passed in) so tests can point them
# at a localhost mock without touching globals.
# ---------------------------------------------------------------------------

proc raiseHttp(prefix: string, resp: Response) {.noreturn.} =
  ## Helper for surfacing non-2xx HTTP responses with body context.
  var body = ""
  try: body = resp.body
  except CatchableError: discard
  let excerpt =
    if body.len > 800: body[0 ..< 800] & " ...(truncated)"
    else: body
  raise newException(TavusError,
    prefix & ": HTTP " & resp.status & "\n" & excerpt)

proc createVideo*(apiKey, apiBase: string, body: JsonNode): string =
  ## `POST /v2/videos`. Returns the Tavus `video_id`. The body is
  ## whatever `buildCreateVideoBody` produced (the caller is free to
  ## hand-craft it for advanced flows).
  ##
  ## Each call opens a fresh `HttpClient` via the same template the
  ## polling loop uses — keep-alive races would otherwise show up as
  ## ProtocolError after the response socket is closed by the
  ## server.
  ##
  ## Tavus's JSON response is a flat object (no envelope), shaped
  ## like `{"video_id": "...", "status": "queued", ...}`.
  var videoId: string
  withFreshClient(apiKey):
    let url = apiBase & "/v2/videos"
    let resp = client.request(url, httpMethod = HttpPost, body = $body)
    if not resp.code.is2xx:
      raiseHttp("POST /v2/videos", resp)
    let parsed =
      try: parseJson(resp.body)
      except JsonParsingError as e:
        raise newException(TavusError,
          "POST /v2/videos: bad JSON: " & e.msg &
          "\nBody: " & resp.body)
    if parsed.kind != JObject:
      raise newException(TavusError,
        "POST /v2/videos: expected JSON object, got " & $parsed.kind &
        ": " & resp.body)
    let idNode = parsed{"video_id"}
    if idNode.isNil or idNode.kind != JString or idNode.getStr.len == 0:
      raise newException(TavusError,
        "POST /v2/videos: response missing video_id: " & resp.body)
    videoId = idNode.getStr
  result = videoId

proc getVideoStatusOnce*(apiKey, apiBase, videoId: string): JsonNode =
  ## Single `GET /v2/videos/{video_id}` round-trip. Returns the
  ## parsed JSON object so callers can read both `status` and
  ## `download_url` (the latter populated only when status reaches
  ## `ready`).
  ##
  ## Exposed for tests that want to inspect a single poll without
  ## the sleep loop.
  var parsed: JsonNode
  withFreshClient(apiKey):
    let url = apiBase & "/v2/videos/" & videoId
    let resp = client.request(url, httpMethod = HttpGet)
    if not resp.code.is2xx:
      raiseHttp("GET /v2/videos/{video_id}", resp)
    try:
      parsed = parseJson(resp.body)
    except JsonParsingError as e:
      raise newException(TavusError,
        "GET /v2/videos/{video_id}: bad JSON: " & e.msg &
        "\nBody: " & resp.body)
    if parsed.kind != JObject:
      raise newException(TavusError,
        "GET /v2/videos/{video_id}: expected JSON object, got " &
        $parsed.kind & ": " & resp.body)
  result = parsed

proc pollVideoStatus*(apiKey, apiBase, videoId: string,
                     maxSecs = DefaultMaxPollSecs,
                     intervalMs = DefaultPollIntervalMs): string =
  ## `GET /v2/videos/{video_id}` until `status: ready` or
  ## `status: error`/`deleted`, subject to a `maxSecs` wall-clock
  ## cap. Returns the `download_url` from which the rendered MP4 can
  ## be downloaded.
  let deadline = epochTime() + maxSecs
  while true:
    let parsed = getVideoStatusOnce(apiKey, apiBase, videoId)
    let status =
      if parsed{"status"}.isNil: ""
      else: parsed{"status"}.getStr
    case status
    of "ready":
      let urlNode = parsed{"download_url"}
      if urlNode.isNil or urlNode.kind != JString or urlNode.getStr.len == 0:
        raise newException(TavusError,
          "Tavus video " & videoId &
          ": status=ready but no download_url: " & $parsed)
      return urlNode.getStr
    of "error", "deleted":
      raise newException(TavusError,
        "Tavus video " & videoId & " " & status & ": " & $parsed)
    else:
      discard
    if epochTime() >= deadline:
      raise newException(TavusError,
        "Tavus video " & videoId & " did not reach status=ready within " &
        $maxSecs & "s (last status=" & status & ")")
    sleep(intervalMs)

proc downloadVideo*(videoUrl, outputPath: string) =
  ## Download the rendered MP4. The Tavus `download_url` is served
  ## from a CDN and does NOT require the `x-api-key` header; we
  ## open a vanilla `HttpClient` (no auth) for the download to keep
  ## the request as plain as possible AND to guard against
  ## accidental credential leakage to a third-party CDN host.
  let outParent = outputPath.parentDir()
  if outParent.len > 0 and not dirExists(outParent):
    createDir(outParent)
  let client = newHttpClient(timeout = 120_000,
                             headers = newHttpHeaders({
                               "User-Agent":
                                 "GuiAssert-Tavus/0.1 (+https://github.com/metacraft-labs/GuiAssert)",
                               "Connection": "close",
                             }))
  try:
    let resp = client.request(videoUrl, httpMethod = HttpGet)
    if not resp.code.is2xx:
      raiseHttp("GET " & videoUrl, resp)
    writeFile(outputPath, resp.body)
    if not fileExists(outputPath) or getFileSize(outputPath) == 0:
      raise newException(TavusError,
        "Tavus result download produced no bytes at " & outputPath)
  finally:
    closeQuietly(client)

# ---------------------------------------------------------------------------
# Provider integration. Glues the HTTP layer to GuiAssert's contract.
# ---------------------------------------------------------------------------

proc tavusIsAvailable*(): bool {.gcsafe.} =
  ## True iff a Tavus API key is set in the environment. We can't
  ## check the per-call `opts.providerSettings.api_key` here because
  ## `isAvailable` is parameterless by contract; the provider's
  ## `generate` proc re-resolves the key (including the YAML
  ## override path) and raises a clear error if the resolved key is
  ## empty.
  getEnv(ApiKeyEnvVar).len > 0

proc tavusGenerateImpl(narrationWav, outputMp4: string,
                      opts: TalkingHeadOpts,
                      maxPollSecs: float,
                      pollIntervalMs: int) {.gcsafe.} =
  ## Real `generate` body, parameterised on the polling cadence so
  ## the mock-server test can run the full create / poll / download
  ## cycle in milliseconds. The public `generateTavus` proc forwards
  ## to here with the production defaults.
  ##
  ## NOTE: `narrationWav` is intentionally *not uploaded*. Tavus's
  ## `POST /v2/videos` synthesises its own voice from `script`. We
  ## still validate the WAV exists because it is hashed into the
  ## cache key — see the module-level docstring for the rationale.
  if not fileExists(narrationWav):
    raise newException(TalkingHeadError,
      "tavus provider: narration WAV not found: " & narrationWav)

  let apiKey = resolveApiKey(opts)
  if apiKey.len == 0:
    raise newException(TalkingHeadError,
      "tavus provider: API key not set. Either export " &
      "TAVUS_API_KEY=<key> or pass it via " &
      "TalkingHeadOpts.providerSettings.api_key.")
  let apiBase = resolveApiBase(opts)
  let scriptText = resolveScriptText(opts)
  if scriptText.len == 0:
    raise newException(TalkingHeadError,
      "tavus provider: providerSettings.script_text is required " &
      "(Tavus synthesises its own voice from text; the narration " &
      "WAV is not uploaded). Set " &
      "TalkingHeadOpts.providerSettings[\"script_text\"].")
  let replicaId = resolveReplicaId(opts)
  let videoName = resolveVideoName(opts)

  let device = effectiveDevice(opts)
  let cacheDir = effectiveCacheDir(opts)
  if not dirExists(cacheDir):
    createDir(cacheDir)
  # `cacheKeyFor` insists both file paths exist. For Tavus the
  # "avatar image" is conceptual (the replica string is server-side),
  # so we alias narrationWav into both slots and fold the
  # Tavus-specific knobs (script_text, replica_id, video_name) into
  # the device slot via `tavusCacheSalt`. This keeps two different
  # script_text strings on the same WAV from colliding in the cache.
  let salt = tavusCacheSalt(device, scriptText, replicaId, videoName)
  let key = cacheKeyFor(narrationWav, narrationWav, ProviderName, salt)

  let generator = proc() =
    let body = buildCreateVideoBody(replicaId, scriptText, videoName)
    let videoId = createVideo(apiKey, apiBase, body)
    let videoUrl = pollVideoStatus(apiKey, apiBase, videoId,
                                   maxSecs = maxPollSecs,
                                   intervalMs = pollIntervalMs)
    downloadVideo(videoUrl, outputMp4)

  {.cast(gcsafe).}:
    discard applyCache(cacheDir, key, outputMp4, generator)

proc generateTavus*(narrationWav, outputMp4: string,
                   opts: TalkingHeadOpts) {.gcsafe.} =
  ## Production-defaults entry point. Tests that need fast polling
  ## can use `tavusProviderWithPolling` (below) to build a provider
  ## with a millisecond-interval poll, avoiding the 10-second
  ## production default.
  tavusGenerateImpl(narrationWav, outputMp4, opts,
                   DefaultMaxPollSecs, DefaultPollIntervalMs)

proc tavusProvider*(): TalkingHeadProvider =
  ## Build the Tavus provider value with production polling
  ## defaults.
  result = TalkingHeadProvider(
    name: ProviderName,
    isAvailable: tavusIsAvailable,
    generate: generateTavus,
  )

proc tavusProviderWithPolling*(maxPollSecs: float,
                              pollIntervalMs: int): TalkingHeadProvider =
  ## Variant for tests: lets the mock-server suite drive the full
  ## cycle without sleeping for seconds between polls. Production
  ## callers use `tavusProvider()`.
  let captured = (maxPollSecs, pollIntervalMs)
  let gen = proc(narrationWav, outputMp4: string,
                 opts: TalkingHeadOpts) {.gcsafe.} =
    {.cast(gcsafe).}:
      tavusGenerateImpl(narrationWav, outputMp4, opts,
                       captured[0], captured[1])
  result = TalkingHeadProvider(
    name: ProviderName,
    isAvailable: tavusIsAvailable,
    generate: gen,
  )

proc registerTavus*(r: TalkingHeadRegistry) =
  ## One-liner plugin entry point. Callers do:
  ##
  ## ```nim
  ## import gui_assert/talking_head
  ## import gui_assert_tavus
  ##
  ## let reg = newRegistry()
  ## registerTavus(reg)
  ## generateTalkingHead(reg, "tavus", wav, mp4, opts)
  ## ```
  r.registerProvider(tavusProvider())
