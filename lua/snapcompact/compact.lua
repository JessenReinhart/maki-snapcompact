local consts = require("snapcompact.constants")
local shapes = require("snapcompact.shapes")
local serialize = require("snapcompact.serialize")
local normalize = require("snapcompact.normalize")
local plan = require("snapcompact.plan")
local render = require("snapcompact.render")
local stopwords = require("snapcompact.stopwords")

local DIM_ON = consts.DIM_ON
local DIM_OFF = consts.DIM_OFF
local NEWLINE_GLYPH = consts.NEWLINE_GLYPH

local M = {}

local DATA_URL_PREFIX = "data:[%w.+-]+/[%w.+-]+;base64,"
local B64_CHARS_CLASS = "A-Za-z0-9+/="
local B64_CHARS = "[" .. B64_CHARS_CLASS .. "]"
local DAMAGED_PAYLOAD_MIN_CHARS = 40

-- Canonical base64 check: 4-char groups with valid terminal padding.
local function is_canonical_base64(payload)
  local stripped = payload:gsub("[^" .. B64_CHARS_CLASS .. "]", "")
  if stripped == "" then return false end
  if #stripped % 4 ~= 0 then return false end
  if not stripped:match("^" .. B64_CHARS .. "*$") then return false end
  -- Strict terminal padding: 0, 1, or 2 pad chars must appear only at the end.
  if not stripped:find("=") then
    return true
  end
  if stripped:sub(-1) == "=" then
    return stripped:sub(-3, -1) ~= "===" and (stripped:match("^[A-Za-z0-9+/]*==$") ~= nil
      or stripped:match("^[A-Za-z0-9+/]+=$") ~= nil)
  end
  return false
end

-- Count payload characters excluding an embedded elision marker (kept for
-- parity with the TS placeholder that reports exact base64 char count).
local function payload_chars(payload)
  local n = 0
  for _ in payload:gmatch(B64_CHARS) do n = n + 1 end
  return n
end

-- Replace inline base64 data URLs with a deterministic placeholder. A payload
-- cut mid-way by planArchive's structure-blind edge slices reads to the model
-- as broken image input, so we collapse the whole atom to its mime/count.
function M.elide_data_urls(text, context)
  context = context or "source"
  if not text or not text:lower():find(";base64,") then return text end
  local out = {}
  local pos = 1
  while true do
    local start_at, end_at = text:find(DATA_URL_PREFIX, pos)
    if not start_at then
      out[#out + 1] = text:sub(pos)
      break
    end
    local mime = text:sub(start_at + 5, end_at - 8) -- strip "data:" (5 chars) and ";base64," (8 chars)
    local payload_start = end_at + 1
    local _, after = text:find("^[%s" .. B64_CHARS_CLASS .. "]*", payload_start)
    after = after or (payload_start - 1)
    local payload = text:sub(payload_start, after)
    local is_atom = context == "archive"
      or payload:find("[data URL omitted]")
      or is_canonical_base64(payload)
      or #payload >= DAMAGED_PAYLOAD_MIN_CHARS
    if not is_atom then
      out[#out + 1] = text:sub(pos, after)
    else
      out[#out + 1] = text:sub(pos, start_at - 1)
      out[#out + 1] = string.format("[data URL omitted: %s, %d base64 chars]", mime, payload_chars(payload))
    end
    pos = after + 1
  end
  return table.concat(out)
end

local PILCROW = "\194\182" -- ¶

-- Drop `¶think:` sections from serialized archive text replayed after a
-- compaction that itself excludes thinking. Mirrors the TS split at section
-- boundaries preceding a `¶` opener, filtering sections that begin `¶think:`.
local function strip_thinking_sections(text)
  local out = {}
  for seg in tostring(text):gmatch("([^" .. NEWLINE_GLYPH .. "]*)") do
    if seg ~= "" then
      local kept = {}
      local s = 1
      for from, to in seg:gmatch("()\n\n" .. PILCROW) do
        local section = seg:sub(s, from - 1)
        if not section:match("^" .. PILCROW .. "think:") then
          kept[#kept + 1] = section
        end
        s = to
      end
      local last = seg:sub(s)
      if not last:match("^" .. PILCROW .. "think:") then
        kept[#kept + 1] = last
      end
      if #kept > 0 then
        out[#out + 1] = table.concat(kept, "\n\n")
      end
    end
  end
  return table.concat(out, NEWLINE_GLYPH)
end

local function to_plain_text(text)
  text = text:gsub(DIM_ON, ""):gsub(DIM_OFF, "")
  return text:gsub(NEWLINE_GLYPH, "\n")
end

-- Denser companion for the foveated archive middle: same family and frame
-- size, tighter 8px cell. Returns `high` unchanged when capacity does not
-- improve (doc layouts, TrueType shapes, or when foveation is off). Uses the
-- family computed alongside the resolved shape.
local function dense_companion(high, family)
  if high.columns == 2 or high.font == "silver" then return high end
  family = family or "unknown"
  local variant = shapes.FAMILY_VARIANT_LOW[family]
  if not variant then return high end
  local base = shapes.SHAPE_VARIANTS[variant]
  if not base then return high end
  local low = shapes.price_shape(shapes.copy(base), family)
  low.frameSize = high.frameSize
  return shapes.geometry(low).capacity > shapes.geometry(high).capacity and low or high
end

-- Resolve a shape plus its billing family in one shot, so dense_companion can
-- reuse the exact family the shape was priced under.
local function resolve_shape(text, model, variant)
  local target = model and model.id and { id = model.id, provider = model.provider or model.id } or nil
  local shape = shapes.resolve_shape(target, variant or "auto")
  if not shape then return nil end
  local family = shapes.family_from_provider(target and target.provider)
  shape.family = family
  return shape, family
end

local function frame_count_for_summary(layout, high)
  local geo = shapes.geometry(high)
  local cols = geo.cols
  local rows = geo.rows
  return { cols = cols, rows = rows }
end

local function format_frame_data_bytes(bytes)
  if bytes >= 1000 then
    return string.format("%.1f KB", bytes / 1000)
  end
  return tostring(bytes) .. " B"
end

-- Keep the newest frames that fit within `maxFrameDataBytes` base64 bytes;
-- omitted frames are always the OLDEST images.
function M.frame_budget(archive, maxFrameDataBytes)
  local frames = archive.frames or {}
  if maxFrameDataBytes == nil then
    return { images = frames, omittedFrames = 0, omittedBytes = 0 }
  end
  local used = 0
  local omittedFrames = 0
  local omittedBytes = 0
  local kept_newest_first = {}
  for i = #frames, 1, -1 do
    local frame = frames[i]
    if frame then
      local bytes = #frame.data
      if used + bytes > maxFrameDataBytes then
        omittedFrames = omittedFrames + 1
        omittedBytes = omittedBytes + bytes
      else
        used = used + bytes
        kept_newest_first[#kept_newest_first + 1] = frame
      end
    end
  end
  local images = {}
  for i = #kept_newest_first, 1, -1 do
    images[#images + 1] = kept_newest_first[i]
  end
  return { images = images, omittedFrames = omittedFrames, omittedBytes = omittedBytes }
end

function M.omitted_frame_notice(omittedFrames, omittedBytes)
  local plural = omittedFrames == 1 and "" or "s"
  return table.concat({
    "-------------- snapcompact image middle omitted",
    string.format("%d archived image frame%s (%s base64) exceeded the per-request snapcompact payload budget. The compacted summary and visible text edges remain available.", omittedFrames, plural, format_frame_data_bytes(omittedBytes)),
    "--------------",
  }, "\n")
end

-- Build the ordered Maki content blocks (oldest -> newest) for a compaction
-- summary message: oldest text edge, the imaged middle, then the newest text
-- edge.
function M.history_blocks(archive, opts)
  opts = opts or {}
  local blocks = {}
  local budget = M.frame_budget(archive, opts.maxFrameDataBytes)
  local has_images = #budget.images > 0
  local has_omitted = budget.omittedFrames > 0
  if archive.textHead and archive.textHead ~= "" then
    local suffix = has_images and "\n-------------- imaged middle below\n"
      or (has_omitted and ("\n" .. M.omitted_frame_notice(budget.omittedFrames, budget.omittedBytes) .. "\n")) or ""
    blocks[#blocks + 1] = { type = "text", text = M.to_plain_text(M.elide_data_urls(archive.textHead, "archive")) .. suffix }
  elseif has_omitted and not has_images then
    blocks[#blocks + 1] = { type = "text", text = M.omitted_frame_notice(budget.omittedFrames, budget.omittedBytes) }
  end
  if has_images and has_omitted then
    blocks[#blocks + 1] = { type = "text", text = M.omitted_frame_notice(budget.omittedFrames, budget.omittedBytes) }
  end
  for _, frame in ipairs(budget.images) do
    blocks[#blocks + 1] = {
      type = "image",
      source = { type = "base64", media_type = "image/png", data = frame.data },
    }
  end
  if archive.textTail and archive.textTail ~= "" then
    local prefix = has_images and "-------------- imaged middle above\n"
      or ((archive.truncatedChars and archive.truncatedChars > 0) or has_omitted)
        and "\n-------------- middle history omitted above\n" or ""
    local tail = prefix .. M.to_plain_text(M.elide_data_urls(archive.textTail, "archive"))
    local last = blocks[#blocks]
    if last and last.type == "text" then
      last.text = last.text .. tail
    else
      blocks[#blocks + 1] = { type = "text", text = tail }
    end
  end
  return blocks
end

-- Reopen a dim span that was left open by the text edge preceding a frame.
local function carry_dim(page_text, dim_open)
  if dim_open then
    return DIM_ON .. page_text
  end
  return page_text
end

local function last_marker(text, marker)
  local pos = 0
  local at = nil
  while true do
    local found = text:find(marker, pos + 1, true)
    if not found then break end
    at = found
    pos = found
  end
  return at
end

local SUMMARY_PROMPT = [[Resume prior conversation. Earlier turns are archived in the HISTORY images below, oldest to newest. Read them fully; continue the live conversation following them.

Reading HISTORY images:
- Plain text (before the first image and after the last) is verbatim transcript; trust it exactly.
- Each image is one page of that transcript, read left-to-right top-to-bottom. A solid black cell is a newline; runs of spaces collapse to one.
- If a section is unclear, re-derive exact details from the workspace rather than guessing.]]

-- Run snapcompact over the given messages (the shape `maki.session.messages`
-- returns) and render an image archive. Returns the archive table, or nil and
-- an error string.
function M.compact(messages, opts)
  opts = opts or {}
  local model = opts.model
  local include_thinking = opts.includeThinking ~= false
  local previous_summary = opts.previousSummary
  local previous_archive = opts.previousArchive

  local serialized = serialize.serialize_conversation(messages, {
    toolResultMaxChars = opts.toolResultMaxChars,
    toolArgMaxChars = opts.toolArgMaxChars,
    toolCallMaxChars = opts.toolCallMaxChars,
    truncateHeadRatio = opts.truncateHeadRatio,
    dimToolResults = opts.dimToolResults,
    includeThinking = include_thinking,
  })

  local previous_text_raw = previous_archive and previous_archive.text
    or (previous_archive and previous_archive.textHead and previous_archive.textHead ~= ""
        and previous_archive.textHead .. NEWLINE_GLYPH .. (previous_archive.textTail or ""))
    or ""

  if include_thinking == false and previous_text_raw ~= "" then
    previous_text_raw = strip_thinking_sections(previous_text_raw)
  end
  local has_previous_text = previous_text_raw ~= ""
  local included_previous_summary = (not has_previous_text) and (previous_summary ~= nil and previous_summary ~= "")

  local probe = serialized
  if has_previous_text then
    probe = previous_text_raw .. NEWLINE_GLYPH .. probe
  elseif included_previous_summary and previous_summary then
    probe = previous_summary .. NEWLINE_GLYPH .. probe
  end

  local high = resolve_shape(probe, model)
  local family = high and high.family or "unknown"

  local geo = shapes.geometry(high)
  local max_frames = math.max(1, math.min(opts.maxFrames or consts.MAX_FRAMES_DEFAULT, consts.MAX_FRAMES_DEFAULT))
  local low = dense_companion(high, family)

  local archive_text = normalize.normalize(serialized)

  if included_previous_summary and previous_summary then
    local head = "[Summary of earlier history] " .. normalize.normalize(previous_summary)
    archive_text = archive_text ~= "" and (head .. " [Recent conversation] " .. archive_text) or head
  end

  local truncated_chars = previous_archive and previous_archive.truncatedChars or 0

  if has_previous_text then
    archive_text = archive_text ~= "" and (previous_text_raw .. NEWLINE_GLYPH .. archive_text) or previous_text_raw
  end
  archive_text = M.elide_data_urls(archive_text, "archive")

  local layout = plan.plan_archive(archive_text, high, low, max_frames)
  truncated_chars = truncated_chars + (layout.truncatedChars or 0)

  -- Render the planned frames carrying any open dim span across boundaries.
  local dim_open
  if layout.textHead and layout.textHead ~= "" then
    local on_at = last_marker(layout.textHead, DIM_ON)
    local off_at = last_marker(layout.textHead, DIM_OFF)
    dim_open = (on_at or 0) > (off_at or 0)
  end

  local planned = {}
  for _, f in ipairs(layout.frames) do
    local page_text = carry_dim(f.text, dim_open)
    dim_open = (last_marker(page_text, DIM_ON) or 0) > (last_marker(page_text, DIM_OFF) or 0)
    if f.shape.stopwordDim then
      page_text = stopwords.dim_stopwords(page_text)
    end
    planned[#planned + 1] = { text = page_text, shape = f.shape }
  end

  local rendered, rerr
  if #planned > 0 then
    rendered, rerr = render.render_frames(planned, high)
    if not rendered then
      return nil, rerr
    end
  else
    rendered = {}
  end

  local text_head = layout.textHead or ""
  local text_tail = layout.textTail or ""
  if dim_open then
    text_tail = DIM_ON .. text_tail
  end

  local frames = {}
  for i, data in ipairs(rendered) do
    local src_shape = planned[i] and planned[i].shape
    frames[#frames + 1] = {
      data = data,
      mimeType = "image/png",
      cols = (src_shape and shapes.geometry(src_shape).cols) or geo.cols,
      rows = (src_shape and shapes.geometry(src_shape).rows) or geo.rows,
      chars = src_shape and #planned[i].text or 0,
      font = src_shape and src_shape.font,
      variant = src_shape and src_shape.variant,
      lineRepeat = src_shape and src_shape.lineRepeat,
      columns = src_shape and src_shape.columns,
      stopwordDim = src_shape and src_shape.stopwordDim,
    }
  end

  local text_chars = #text_head + #text_tail
  local total_chars = text_chars
  for _, f in ipairs(frames) do total_chars = total_chars + (f.chars or 0) end

  local persisted_text = layout.keptText or ""
  if persisted_text ~= "" and layout.textTail and layout.textTail ~= "" then
    persisted_text = persisted_text:sub(1, #persisted_text - #layout.textTail) .. text_tail
  end

  local archive = {
    frames = frames,
    totalChars = total_chars,
    truncatedChars = truncated_chars,
  }
  if persisted_text ~= "" then archive.text = persisted_text end
  if text_head ~= "" then archive.textHead = text_head end
  if text_tail ~= "" then archive.textTail = text_tail end

  return archive
end

M.to_plain_text = to_plain_text
M.SUMMARY_PROMPT = SUMMARY_PROMPT

return M