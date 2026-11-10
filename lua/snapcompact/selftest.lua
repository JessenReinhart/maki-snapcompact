local compact = require("snapcompact.compact")
local consts = require("snapcompact.constants")
local shapes = require("snapcompact.shapes")
local serialize = require("snapcompact.serialize")
local normalize = require("snapcompact.normalize")
local plan = require("snapcompact.plan")
local stopwords = require("snapcompact.stopwords")

local M = {}

local function report(msg)
  print("[snapcompact-selftest] " .. tostring(msg))
  if maki and maki.log and maki.log.info then
    maki.log.info("[snapcompact-selftest] " .. tostring(msg))
  end
end

local function assert_eq(actual, expected, msg)
  if actual ~= expected then
    error(string.format("%s: expected %s, got %s", msg or "assertion failed", tostring(expected), tostring(actual)))
  end
end

local function assert_true(val, msg)
  if not val then
    error(msg or "expected truthy value")
  end
end

function M.test_normalize()
  -- Unicode quote fold
  local folded = normalize.normalize("‘smart’ and “quotes”")
  assert_true(folded:find("'smart'") ~= nil, "single quotes fold")
  assert_true(folded:find('"quotes"') ~= nil, "double quotes fold")

  -- Space collapse
  local spaced = normalize.normalize("hello    world")
  assert_eq(spaced, "hello world", "whitespace collapse")

  -- Newline glyph
  local multiline = normalize.normalize("line1\nline2")
  assert_eq(multiline, "line1" .. consts.NEWLINE_GLYPH .. "line2", "newline glyph")
  report("PASS: test_normalize")
end

function M.test_serialize()
  local msgs = {
    { role = "user", content = { { type = "text", text = "hello" } } },
    {
      role = "assistant",
      content = {
        { type = "thinking", thinking = "internal reasoning" },
        { type = "text", text = "greetings" },
      },
    },
  }
  local serialized = serialize.serialize_conversation(msgs, { includeThinking = false })
  assert_true(serialized:find("hello") ~= nil, "contains user message")
  assert_true(serialized:find("greetings") ~= nil, "contains assistant message")
  assert_true(serialized:find("internal reasoning") == nil, "thinking stripped")

  local with_thinking = serialize.serialize_conversation(msgs, { includeThinking = true })
  assert_true(with_thinking:find("internal reasoning") ~= nil, "thinking retained when enabled")
  report("PASS: test_serialize")
end

function M.test_shapes()
  local ant = shapes.resolve_shape({ provider = "anthropic", id = "claude-3-7-sonnet" }, "auto")
  assert_eq(ant.cellWidth, 11, "anthropic cellWidth")
  assert_eq(ant.cellHeight, 16, "anthropic cellHeight")
  assert_eq(ant.variant, "bw", "anthropic variant")
  local ant_geo = shapes.geometry(ant)
  assert_true(ant_geo.cols > 100, "anthropic cols > 100")
  assert_true(ant_geo.rows > 50, "anthropic rows > 50")
  assert_true(ant_geo.capacity > 10000, "anthropic capacity > 10000")

  local oai = shapes.resolve_shape({ provider = "openai", id = "gpt-4o" }, "auto")
  assert_eq(oai.cellWidth, 8, "openai cellWidth")
  assert_eq(oai.cellHeight, 22, "openai cellHeight")
  assert_eq(oai.variant, "bw", "openai variant")

  local low = shapes.FAMILY_VARIANT_LOW["anthropic"]
  assert_eq(low, "8on16-bw", "anthropic low companion variant")
  report("PASS: test_shapes")
end

function M.test_stopwords()
  local dimmed = stopwords.dim_stopwords("the quick brown fox")
  assert_true(dimmed:find(consts.DIM_ON) ~= nil, "dim marker on present")
  assert_true(dimmed:find(consts.DIM_OFF) ~= nil, "dim marker off present")
  report("PASS: test_stopwords")
end

function M.test_elide_data_urls()
  local raw = "see data:image/png;base64,AAAABBBBCCCCDDDD== end"
  local elided = compact.elide_data_urls(raw, "source")
  assert_true(elided:find("%[data URL omitted: image/png, %d+ base64 chars%]") ~= nil, "data url elision")
  report("PASS: test_elide_data_urls")
end

function M.test_plan_and_render_full()
  local lines = {}
  for i = 1, 1000 do
    lines[#lines + 1] = string.format("line %04d the quick brown fox jumps over the lazy dog and continues onward with testing", i)
  end
  local text = table.concat(lines, "\n")

  local messages = {
    { role = "user", content = { { type = "text", text = text:sub(1, 45000) } } },
    { role = "assistant", content = { { type = "text", text = text:sub(45001, 90000) } } },
  }

  local archive, err = compact.compact(messages, {
    model = { id = "claude-sonnet-4-5", provider = "anthropic" },
    maxFrames = 8,
  })

  assert_true(archive ~= nil, "compact succeeded: " .. tostring(err))
  local n_frames = archive.frames and #archive.frames or 0
  assert_true(n_frames > 0, "frames rendered > 0")
  report(string.format("archive frames=%d totalChars=%d textHead=%d textTail=%d",
    n_frames, archive.totalChars or 0, #archive.textHead, #archive.textTail))

  local first = archive.frames[1].data
  assert_eq(first:sub(1, 6), "iVBORw", "frame 1 is valid base64 PNG")

  -- Test history blocks generation
  local blocks = compact.history_blocks(archive, { maxFrameDataBytes = 100000 })
  assert_true(#blocks > 0, "history blocks generated")
  local img_count = 0
  local txt_count = 0
  for _, b in ipairs(blocks) do
    if b.type == "image" then img_count = img_count + 1 elseif b.type == "text" then txt_count = txt_count + 1 end
  end
  assert_true(img_count > 0, "contains image blocks")
  assert_true(txt_count > 0, "contains text blocks")
  report(string.format("PASS: test_plan_and_render_full (rendered %d frames, %d blocks)", n_frames, #blocks))
end

function M.run()
  report("Starting snapcompact test suite...")
  M.test_normalize()
  M.test_serialize()
  M.test_shapes()
  M.test_stopwords()
  M.test_elide_data_urls()
  M.test_plan_and_render_full()
  report("All snapcompact tests PASSED successfully!")
  return true
end

return M
