# Test fixtures

## `narration.wav` — short test narration

A ~3.5 second WAV (16 kHz mono PCM) of the phrase
"Hello from GuiAssert D-ID. This is a test render.", generated via
macOS `say` and resampled with `ffmpeg`:

```
say -o tmp.aiff "Hello from GuiAssert D-ID. This is a test render."
ffmpeg -i tmp.aiff -ar 16000 -ac 1 narration.wav
```

The narration is reused from the sibling D-ID / HeyGen / Synthesia
plugin fixture directories for cross-plugin consistency. Tavus does
**not** consume audio uploads on its `POST /v2/videos` endpoint — the
narration text is supplied by `opts.providerSettings["script_text"]`
and Tavus synthesises the voice itself via the selected replica. This
WAV is therefore used only as a cache-key ingredient by the plugin
(via `cacheKeyFor`), not as content uploaded to Tavus. See the README
for the full rationale.

The live test honours `$GUI_ASSERT_TAVUS_TEST_WAV` as an override.
