local shapes = require("snapcompact.shapes")
local nm = require("snapcompact.normalize")
local consts = require("snapcompact.constants")

local M = {}

local function chars_of(text)
  local out = {}
  for _, cp in utf8.codes(text or "") do
    out[#out + 1] = utf8.char(cp)
  end
  return out
end

-- Cells one character occupies; normalized text is single-width except when
-- the caller opts into wideCells for preserved CJK shapes.
function M.char_cells(ch, wideCells)
  return shapes.char_cells(ch, wideCells)
end

function M.uses_wide_cells(shape)
  return shape.font ~= "silver"
end

function M.cell_length(text, wideCells)
  local n = 0
  for _, ch in ipairs(chars_of(text)) do
    n = n + M.char_cells(ch, wideCells)
  end
  return n
end

function M.slice_cells(text, width, wideCells)
  local out = {}
  local cells = 0
  local placed = false
  for _, ch in ipairs(chars_of(text)) do
    local w = M.char_cells(ch, wideCells)
    if placed and cells + w > width then break end
    out[#out + 1] = ch
    cells = cells + w
    if w > 0 then placed = true end
  end
  return table.concat(out)
end

--- Paginate `text` into pages that fill at most `capacity` grid cells.
-- Returns contiguous substring pages; each renders independently at cell 0.
function M.paginate_cells(text, capacity, cols, wideCells)
  local chars = chars_of(text)
  local pages = {}
  local current = {}
  local cell = 0
  local has = false

  local function push_page(from, to)
    local t = {}
    for i = from, to do t[#t + 1] = chars[i] end
    pages[#pages + 1] = table.concat(t)
  end

  local start = 1
  for i = 1, #chars do
    local w = M.char_cells(chars[i], wideCells)
    if w == 0 then
      current[#current + 1] = chars[i]
    else
      local at = cell
      if w == 2 and cols >= 2 and at % cols == cols - 1 then at = at + 1 end
      if has and at + w > capacity then
        -- page ends before this char
        local t = {}
        for j = start, i - 1 do t[#t + 1] = chars[j] end
        pages[#pages + 1] = table.concat(t)
        start = i
        at = 0
      end
      cell = at + w
      has = true
    end
  end

  if has then
    local t = {}
    for j = start, #chars do t[#t + 1] = chars[j] end
    pages[#pages + 1] = table.concat(t)
  end

  return pages, #chars
end

-- Greedy word-wrap; no mid-word breaks except width+ words.
function M.wrap(text, width, wideCells)
  local lines = {}
  local cur = ""
  local curCells = 0

  for token in (text or ""):gmatch("%S+") do
    local word = token
    local wordCells = M.cell_length(word, wideCells)
    while wordCells > width do
      if cur ~= "" then
        lines[#lines + 1] = cur
        cur = ""
        curCells = 0
      end
      local head = M.slice_cells(word, width, wideCells)
      lines[#lines + 1] = head
      word = word:sub(#head + 1)
      wordCells = M.cell_length(word, wideCells)
    end
    if cur == "" then
      cur = word
      curCells = wordCells
    elseif curCells + 1 + wordCells <= width then
      cur = cur .. " " .. word
      curCells = curCells + 1 + wordCells
    else
      lines[#lines + 1] = cur
      cur = word
      curCells = wordCells
    end
  end

  if cur ~= "" then lines[#lines + 1] = cur end
  return lines
end

function M.doc_pages(normalized, geo, wideCells)
  local lines = M.wrap(normalized, geo.cols, wideCells)
  local per_page = 2 * geo.rows
  local pages = {}
  for offset = 1, #lines, per_page do
    local slice = {}
    for i = offset, math.min(offset + per_page - 1, #lines) do
      slice[#slice + 1] = lines[i]
    end
    pages[#pages + 1] = table.concat(slice, "\n")
  end
  return pages
end

-- Plan a foveated archive layout from normalized text (oldest..newest).
function M.plan_archive(text, high, low, maxFrames)
  local geo_high = shapes.geometry(high)
  local edge_cap = consts.TEXT_EDGE_PAGES * geo_high.capacity

  if #text <= 2 * edge_cap then
    return { frames = {}, textHead = text, textTail = "", keptText = text, truncatedChars = 0 }
  end

  if maxFrames < 1 then
    return {
      frames = {},
      textHead = text:sub(1, edge_cap),
      textTail = text:sub(#text - edge_cap + 1),
      keptText = text:sub(1, edge_cap) .. text:sub(#text - edge_cap + 1),
      truncatedChars = #text - 2 * edge_cap,
    }
  end

  local textHead = text:sub(1, edge_cap)
  local textTail = text:sub(#text - edge_cap + 1)
  local imageText = text:sub(edge_cap + 1, #text - edge_cap)

  if imageText == "" or #imageText == 0 then
    return { frames = {}, textHead = text, textTail = "", keptText = text, truncatedChars = 0 }
  end

  local planFrames = function(pages, shape)
    local out = {}
    for _, page in ipairs(pages) do
      out[#out + 1] = { text = page, shape = shape }
    end
    return out
  end

  if high.columns == 2 then
    local pages = M.doc_pages(imageText, geo_high, M.uses_wide_cells(high))
    local kept = pages
    local truncatedChars = 0
    if #pages > maxFrames then
      local dropped = {}
      for i = 2, #pages - (maxFrames - 1) do dropped[#dropped + 1] = pages[i] end
      local dsum = 0
      for _, p in ipairs(dropped) do dsum = dsum + #p end
      truncatedChars = dsum
      kept = { pages[1] }
      for i = #pages - (maxFrames - 2), #pages do kept[#kept + 1] = pages[i] end
    end

    local flat_parts = {}
    for i, p in ipairs(kept) do flat_parts[i] = p:gsub("\n", " ") end
    local flat = table.concat(flat_parts, " ")

    return {
      frames = planFrames(kept, high),
      textHead = textHead,
      textTail = textTail,
      keptText = textHead .. flat .. textTail,
      truncatedChars = truncatedChars,
    }
  end

  local geo_high_shape = shapes.geometry(high)
  local hiPages = M.paginate_cells(imageText, geo_high_shape.capacity, geo_high_shape.cols, M.uses_wide_cells(high))

  if #hiPages <= maxFrames then
    return {
      frames = planFrames(hiPages, high),
      textHead = textHead,
      textTail = textTail,
      keptText = textHead .. imageText .. textTail,
      truncatedChars = 0,
    }
  end

  local imageEdgeFrames = math.min(consts.HQ_EDGE_FRAMES, math.floor((maxFrames - 1) / 2))
  local headPages = {}
  local tailPages = {}
  for i = 1, imageEdgeFrames do headPages[#headPages + 1] = hiPages[i] end
  if imageEdgeFrames > 0 then
    for i = #hiPages - imageEdgeFrames + 1, #hiPages do tailPages[#tailPages + 1] = hiPages[i] end
  end

  local imageHead = table.concat(headPages)
  local imageTail = table.concat(tailPages)
  local middleSource = imageText:sub(#imageHead + 1, #imageText - #imageTail)

  local geo_low = shapes.geometry(low)
  local middlePages = M.paginate_cells(middleSource, geo_low.capacity, geo_low.cols, M.uses_wide_cells(low))
  local middleBudget = maxFrames - 2 * imageEdgeFrames
  local truncatedChars = 0
  local middleText = middleSource

  if #middlePages > middleBudget then
    local dropped = {}
    for i = 1, #middlePages - middleBudget do dropped[#dropped + 1] = middlePages[i] end
    local dsum = 0
    for _, p in ipairs(dropped) do dsum = dsum + #p end
    truncatedChars = dsum
    middleText = middleSource:sub(dsum + 1)
    local kept_middle = {}
    for i = #middlePages - middleBudget + 1, #middlePages do kept_middle[#kept_middle + 1] = middlePages[i] end
    middlePages = kept_middle
  end

  local frames = {}
  for _, f in ipairs(planFrames(headPages, high)) do frames[#frames + 1] = f end
  for _, f in ipairs(planFrames(middlePages, low)) do frames[#frames + 1] = f end
  for _, f in ipairs(planFrames(tailPages, high)) do frames[#frames + 1] = f end

  return {
    frames = frames,
    textHead = textHead,
    textTail = textTail,
    keptText = textHead .. imageHead .. middleText .. imageTail .. textTail,
    truncatedChars = truncatedChars,
  }
end

return M