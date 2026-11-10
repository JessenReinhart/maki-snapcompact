local consts = require("snapcompact.constants")

local M = {}

-- Eval-validated shape geometries keyed by research name. `cellWidth`/`cellHeight`
-- are the target cell advance/pitch; `stretch` explicit here only when the
-- shape opts out of auto-stretch. Billing fields are filled in by priceShape.
M.SHAPE_VARIANTS = {
  ["8x8r-bw"] = { font = "8x8", cellWidth = 8, cellHeight = 8, variant = "bw", lineRepeat = 2, frameSize = 1568 },
  ["8x8r-sent"] = { font = "8x8", cellWidth = 8, cellHeight = 8, variant = "sent", lineRepeat = 2, frameSize = 1568 },
  ["8x8u-bw"] = { font = "8x8", cellWidth = 8, cellHeight = 8, variant = "bw", lineRepeat = 1, frameSize = 1568 },
  ["8x8u-sent"] = { font = "8x8", cellWidth = 8, cellHeight = 8, variant = "sent", lineRepeat = 1, frameSize = 1568 },
  ["6x6u-bw"] = { font = "8x8", cellWidth = 6, cellHeight = 6, variant = "bw", lineRepeat = 1, frameSize = 1568 },
  ["6x6u-sent"] = { font = "8x8", cellWidth = 6, cellHeight = 6, variant = "sent", lineRepeat = 1, frameSize = 1568 },
  ["5x8-bw"] = { font = "5x8", cellWidth = 5, cellHeight = 8, variant = "bw", lineRepeat = 1, frameSize = 2576 },
  ["5x8-sent"] = { font = "5x8", cellWidth = 5, cellHeight = 8, variant = "sent", lineRepeat = 1, frameSize = 2576 },
  ["6x12-dim"] = { font = "6x12", cellWidth = 6, cellHeight = 12, variant = "bw", stopwordDim = true, lineRepeat = 1, frameSize = 1568 },
  ["8x13-bw"] = { font = "8x13", cellWidth = 8, cellHeight = 13, variant = "bw", lineRepeat = 1, frameSize = 1568 },
  ["8on16-bw"] = { font = "8x13", cellWidth = 8, cellHeight = 16, stretch = false, variant = "bw", lineRepeat = 1, frameSize = 1568 },
  ["8on22-bw"] = { font = "8x13", cellWidth = 8, cellHeight = 22, stretch = false, variant = "bw", lineRepeat = 1, frameSize = 1568 },
  ["11on16-bw"] = { font = "8x13", cellWidth = 11, cellHeight = 16, stretch = false, variant = "bw", lineRepeat = 1, frameSize = 1568 },
  ["silver16-bw"] = { font = "silver", cellWidth = 16, cellHeight = 16, variant = "bw", lineRepeat = 1, frameSize = 1568 },
  ["doc-8on16-bw"] = { font = "8x13", cellWidth = 8, cellHeight = 16, stretch = false, variant = "bw", columns = 2, lineRepeat = 1, frameSize = 1568 },
  ["doc-8on16-sent"] = { font = "8x13", cellWidth = 8, cellHeight = 16, stretch = false, variant = "sent", columns = 2, lineRepeat = 1, frameSize = 1568 },
  ["doc-8on16-sent-dim"] = { font = "8x13", cellWidth = 8, cellHeight = 16, stretch = false, variant = "sent", stopwordDim = true, columns = 2, lineRepeat = 1, frameSize = 1568 },
}

local function billing_patches(family, frameSize)
  local patches
  if family == "openai" then
    patches = math.min(math.ceil(frameSize / 32) ^ 2, 10000)
    return { frameTokenEstimate = math.ceil(patches * 1.2), imageDetail = "original" }
  elseif family == "google" then
    return { frameTokenEstimate = 1120 }
  else
    -- anthropic + unknown share pixel-area pricing as the safe ceiling
    patches = math.min(math.ceil(frameSize / 28) ^ 2, 4784)
    return { frameTokenEstimate = math.ceil(patches * 1.05) }
  end
end

local function copy(t)
  local o = {}
  for k, v in pairs(t) do o[k] = v end
  return o
end
M.copy = copy

function M.price_shape(base, family)
  local out = copy(base)
  for k, v in pairs(billing_patches(family, base.frameSize)) do out[k] = v end
  return out
end

-- Eval-validated shapes keyed by provider billing family
M.SHAPES = {
  anthropic = M.price_shape(M.SHAPE_VARIANTS["11on16-bw"], "anthropic"),
  google = M.price_shape(M.SHAPE_VARIANTS["8on22-bw"], "google"),
  openai = M.price_shape(M.SHAPE_VARIANTS["8on22-bw"], "openai"),
  legacy = M.price_shape(M.SHAPE_VARIANTS["5x8-sent"], "anthropic"),
}

M.FAMILY_VARIANT = { anthropic = "11on16-bw", google = "8on22-bw", openai = "8on22-bw", unknown = "8on22-bw" }
M.FAMILY_VARIANT_LOW = { anthropic = "8on16-bw", google = "8on16-bw", openai = "8on16-bw", unknown = "8on16-bw" }

M.FAMILY_SHAPE = {
  anthropic = M.SHAPES.anthropic,
  google = M.SHAPES.google,
  openai = M.SHAPES.openai,
  unknown = M.price_shape(M.SHAPE_VARIANTS["8on22-bw"], "unknown"),
}

-- Rough billing-family classification from maki provider id.
function M.family_from_provider(provider)
  local p = tostring(provider or ""):lower()
  if p:find("anthropic") or p:find("claude") or p:find("bedrock") then return "anthropic" end
  if p:find("openai") or p:find("azure") or p:find("codex") then return "openai" end
  if p:find("google") or p:find("gemini") or p:find("vertex") then return "google" end
  return "unknown"
end

-- Model-line ideal variants, ported from MODEL_VARIANTS/idealShapeVariant.
local HIGH_RES_ANTHROPIC = { variant = "11on16-bw", frameSize = 1932 }

local MODEL_RULES = {
  { "claude.*(fable|mythos)", HIGH_RES_ANTHROPIC },
  { "claude", { variant = "11on16-bw" } },
  { "gemini", { variant = "8on22-bw", frameSize = 2048 } },
  { "gpt|codex", { variant = "8on22-bw" } },
  { "kimi", { variant = "8on22-bw" } },
  { "glm", { variant = "8on16-bw" } },
}

function M.ideal_shape_variant(modelId)
  if not modelId then return nil end
  local id = modelId:lower()
  for _, rule in ipairs(MODEL_RULES) do
    if id:find(rule[1]) then return rule[2] end
  end
  return nil
end

function M.resolve_shape(model, variant)
  local family = M.family_from_provider(model and model.provider)
  if variant and variant ~= "auto" then
    local base = M.SHAPE_VARIANTS[variant]
    if not base then return nil end
    return M.price_shape(base, family)
  end
  local ideal = model and model.id and M.ideal_shape_variant(model.id)
  local name = ideal and ideal.variant or M.FAMILY_VARIANT[family]
  if name == M.FAMILY_VARIANT[family] and not (ideal and ideal.frameSize) then
    return copy(M.FAMILY_SHAPE[family])
  end
  local base = M.SHAPE_VARIANTS[name]
  if ideal and ideal.frameSize then
    base = copy(base)
    base.frameSize = ideal.frameSize
  end
  return M.price_shape(base, family)
end

function M.geometry(shape, size)
  size = size or shape.frameSize
  local gridCols = math.floor(size / shape.cellWidth)
  local rows = math.floor(size / shape.cellHeight / (shape.lineRepeat or 1))
  if shape.columns == 2 then
    local cols = math.floor((gridCols - 3) / 2)
    return { cols = cols, rows = rows, capacity = 2 * cols * rows }
  end
  return { cols = gridCols, rows = rows, capacity = gridCols * rows }
end

M.isWideCodePoint = function(cp)
  return (cp >= 0x1100 and cp <= 0x115F)
    or (cp >= 0x2E80 and cp <= 0x2EFF)
    or (cp >= 0x2F00 and cp <= 0x2FDF)
    or (cp >= 0x3000 and cp <= 0x303E)
    or (cp >= 0x3041 and cp <= 0x33FF)
    or (cp >= 0x3400 and cp <= 0x4DBF)
    or (cp >= 0x4E00 and cp <= 0x9FFF)
    or (cp >= 0xA000 and cp <= 0xA4CF)
    or (cp >= 0xAC00 and cp <= 0xD7A3)
    or (cp >= 0xF900 and cp <= 0xFAFF)
    or (cp >= 0xFE30 and cp <= 0xFE4F)
    or (cp >= 0xFF00 and cp <= 0xFF60)
    or (cp >= 0xFFE0 and cp <= 0xFFE6)
    or (cp >= 0x20000 and cp <= 0x2FFFD)
    or (cp >= 0x30000 and cp <= 0x3FFFD)
end

M.char_cells = function(ch, wideCells)
  if ch == consts.DIM_ON or ch == consts.DIM_OFF then return 0 end
  local cp = utf8.codepoint(ch, 1)
  if wideCells and cp and M.isWideCodePoint(cp) then return 2 end
  return 1
end

return M