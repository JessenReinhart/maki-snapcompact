# maki-snapcompact

Image-based conversation archiver for [Maki](https://maki.agent) — a Luau port of
[`@oh-my-pi/snapcompact`](https://github.com/can1357/oh-my-pi/tree/main/packages/snapcompact).

When a Maki session grows too large, snapcompact renders the conversation history
into dense monospaced PNG frames (character-cell rasterization) and continues the
session from a compact summary message. It intercepts Maki's native compaction
flow and replaces it with image archives, and can proactively trigger before the
context window overflows.

## Features

- **Faithful text-to-image compaction** — Unicode normalization, CJK double-width
  cell measurement, newline glyph substitution, and stopword dimming, matching the
  original `snapcompact` rasterizer.
- **Model-family font metrics** — `anthropic` uses `11on16-bw`, `google` / `openai` /
  unknown use `8on22-bw`, and a low-density companion variant `8on16-bw` is used
  when it improves characters-per-frame.
- **Data URL elision** — replaces inline base64 blobs with
  `[data URL omitted: <mime>, <N> base64 chars]` while preserving character counts.
- **Frame budget** — keeps the newest frames that fit the configured budget,
  reporting omitted frames and dropped characters.
- **Native hook integration** — intercepts `agent.compact.before`, falls back to
  native compaction on failure.
- **Proactive auto-compaction** — `TurnEnd` monitor triggers when context size
  exceeds a configurable fraction of the window.
- **Runtime config** — persisted to `snapcompact.json`.

## Requirements

- Maki `0.7.0`+ (Luau plugin runtime).
- Node.js (used to run the renderer bridge).
- Optional: `pi_natives` addon (`renderSnapcompactPng`) at
  `~/.omp/natives/<version>/pi_natives.win32-x64-baseline.node`, or set
  `PI_NATIVES_PATH`. When unavailable the bridge falls back to a builtin
  grayscale PNG generator.

## Install

Copy the plugin into Maki's global config directory (`~/.config/maki` on Linux /
macOS, `%USERPROFILE%\.config\maki` on Windows Maki; also mirrored to
`AppData\Roaming\maki` on Windows):

```text
.config/maki/
├── init.lua                  # require("snapcompact.init") + setup()
├── plugin.toml               # plugin permissions
├── snapcompact.json          # runtime-generated config (or snapcompact.json.example)
├── bin/
│   └── snapcompact-render.cjs
└── lua/
    └── snapcompact/
        ├── init.lua
        ├── compact.lua
        ├── constants.lua
        ├── normalize.lua
        ├── plan.lua
        ├── render.lua
        ├── selftest.lua
        ├── serialize.lua
        ├── shapes.lua
        └── stopwords.lua
```

Add to `init.lua`:

```lua
local ok, snapcompact = pcall(require, "snapcompact.init")
if ok and snapcompact then
  pcall(snapcompact.setup)
end
```

`setup()` accepts an optional table for explicit overrides
(`enableAuto`, `hideImagesInChat`, `summaryDisplayText`, `maxFrames`,
`contextAuto = { enabled, ratio }`). Caller config > persisted
`snapcompact.json` > built-in defaults.

## Commands

```
/snapcompact [prompt]     compact the current session now
/snapcompact auto <N%>    enable/…set context-auto threshold (5–99%, also 0.N form)
/snapcompact auto on|off  toggle context-auto
/snapcompact hide on|off  hide archived images from the chat transcript
/snapcompact frames <N>   cap rendered PNG frames
/snapcompact status       print current settings
/snapcompact test         run self-test
/snapcompact help         syntax
```

## How it works

1. `serialize.lua` flattens the message history into a transcript (strips
   `¶think:` sections, serializes tool calls, newline glyphs).
2. `normalize.lua` normalizes Unicode and measures CJK double-width cells;
   `stopwords.lua` wraps low-value words in dim markers (`\x14` / `\x15`).
3. `plan.lua` paginates the measured text into character-cell grids using the
   current model family's font metrics.
4. `render.lua` spawns `bin/snapcompact-render.cjs`, which calls `pi_natives`
   (or the fallback generator) and returns base64 PNG frames.
5. `compact.lua` elides data URLs, applies the frame budget, and assembles Maki
   content blocks.
6. `init.lua` opens a new session with the archived-history summary message,
   or returns `{ skip = true }` from `agent.compact.before` to replace native
   compaction.

## License

MIT