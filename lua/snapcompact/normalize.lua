local consts = require("snapcompact.constants")

local DIM_ON = consts.DIM_ON
local DIM_OFF = consts.DIM_OFF
local NEWLINE_GLYPH = consts.NEWLINE_GLYPH

local M = {}

-- Punctuation and symbol folds (from CHAR_FOLD)
M.CHAR_FOLD = {
  ["\226\128\152"] = "'", -- \u2018
  ["\226\128\153"] = "'", -- \u2019
  ["\226\128\154"] = "'", -- \u201a
  ["\226\128\155"] = "'", -- \u201b
  ["\226\128\156"] = '"', -- \u201c
  ["\226\128\157"] = '"', -- \u201d
  ["\226\128\158"] = '"', -- \u201e
  ["\226\128\178"] = "'", -- \u2032
  ["\226\128\179"] = '"', -- \u2033
  ["\226\128\181"] = "'", -- \u2035
  ["\226\128\182"] = '"', -- \u2036
  ["\226\128\185"] = "<", -- \u2039
  ["\226\128\186"] = ">", -- \u203a
  ["\226\128\144"] = "-", -- \u2010
  ["\226\128\145"] = "-", -- \u2011
  ["\226\128\146"] = "-", -- \u2012
  ["\226\128\147"] = "-", -- \u2013
  ["\226\128\148"] = "-", -- \u2014
  ["\226\128\149"] = "-", -- \u2015
  ["\226\136\146"] = "-", -- \u2212
  ["\226\129\132"] = "/", -- \u2044
  ["\226\129\164"] = ".", -- \u2024
  ["\226\129\165"] = "..", -- \u2025
  ["\226\128\166"] = "...", -- \u2026
  ["\226\139\175"] = "...", -- \u22ef
  ["\226\128\162"] = "*", -- \u2022
  ["\226\128\163"] = "*", -- \u2023
  ["\226\129\131"] = "-", -- \u2043
  ["\226\136\153"] = "*", -- \u2219
  ["\226\151\143"] = "*", -- \u25cf
  ["\226\150\160"] = "*", -- \u25a0
  ["\226\150\170"] = "*", -- \u25aa
  ["\226\134\144"] = "<-", -- \u2190
  ["\226\134\145"] = "^", -- \u2191
  ["\226\134\146"] = "->", -- \u2192
  ["\226\134\147"] = "v", -- \u2193
  ["\226\134\148"] = "<->", -- \u2194
  ["\226\135\144"] = "<=", -- \u21d0
  ["\226\135\146"] = "=>", -- \u21d2
  ["\226\135\148"] = "<=>", -- \u21d4
  ["\226\156\147"] = "v", -- \u2713
  ["\226\156\148"] = "v", -- \u2714
  ["\226\156\151"] = "x", -- \u2717
  ["\226\156\152"] = "x", -- \u2718
}

M.EMOJI_FOLD = {
  ["\226\156\133"] = "[OK]", -- \u2705
  ["\226\152\145"] = "[OK]", -- \u2611
  ["\226\156\148"] = "[OK]", -- \u2714
  ["\226\157\140"] = "[FAIL]", -- \u274c
  ["\226\157\142"] = "[FAIL]", -- \u274e
  ["\226\156\150"] = "[FAIL]", -- \u2716
  ["\226\154\160"] = "[WARN]", -- \u26a0
  ["\240\159\154\168"] = "[ALERT]", -- \U0001f6a8
  ["\226\132\185"] = "[INFO]", -- \u2139
  ["\240\159\144\155"] = "[BUG]", -- \U0001f41b
  ["\240\159\146\165"] = "[CRASH]", -- \U0001f4a5
  ["\240\159\148\165"] = "[HOT]", -- \U0001f525
  ["\240\159\148\146"] = "[LOCK]", -- \U0001f512
  ["\240\159\148\147"] = "[UNLOCK]", -- \U0001f513
  ["\240\159\147\129"] = "[DIR]", -- \U0001f4c1
  ["\240\159\147\130"] = "[DIR]", -- \U0001f4c2
  ["\240\159\147\132"] = "[FILE]", -- \U0001f4c4
  ["\240\159\147\157"] = "[NOTE]", -- \U0001f4dd
  ["\240\159\167\170"] = "[TEST]", -- \U0001f9ea
  ["\226\143\179"] = "[WAIT]", -- \u23f3
  ["\226\140\155"] = "[WAIT]", -- \u231b
  ["\240\159\154\128"] = "[RUN]", -- \U0001f680
}

function M.is_ascii_or_latin1(cp)
  return (cp >= 0x20 and cp < 0x7f) or (cp >= 0xa0 and cp <= 0xff)
end

-- Strip ANSI escape sequences (simple SGR/CSI), enough for session tool output.
function M.strip_ansi(text)
  if not text or not text:find("\27", 1, true) then return text end
  return (text:gsub("\27%[[%d;]*[%a-zA-Z]", ""))
end

-- Whether a character is a whitespace or format char needing collapse.
local function is_collapsible_char(ch)
  if ch == " " or ch == "\t" or ch == "\r" or ch == "\n" or ch == "\11" or ch == "\12" then
    return true
  end
  local cp = utf8.codepoint(ch, 1)
  if not cp then return false end
  -- \p{Cf} common: BOM (0xfeff), ZWSP(0x200b), LRM(0x200e), RLM(0x200f)
  if cp == 0xfeff or cp == 0x200b or cp == 0x200e or cp == 0x200f then return true end
  -- \p{Z} other space separators
  if cp == 0x00a0 or (cp >= 0x2000 and cp <= 0x200a) or cp == 0x2028 or cp == 0x2029 or cp == 0x202f or cp == 0x205f or cp == 0x3000 then
    return true
  end
  return false
end

local function is_line_break_char(ch)
  return ch == "\n" or ch == "\r" or ch == "\226\128\168" or ch == "\226\128\169" -- \u2028 \u2029
end

local function is_cf_only_char(ch)
  local cp = utf8.codepoint(ch, 1)
  return cp == 0xfeff or cp == 0x200b or cp == 0x200e or cp == 0x200f
end

-- Iterate unicode code points of a string, returning a list of UTF-8 chars.
function M.chars(text)
  local out = {}
  for _, cp in utf8.codes(text) do
    out[#out + 1] = utf8.char(cp)
  end
  return out
end

-- Collapse whitespace/format runs the same way normalizedInputChars does:
-- runs containing a line break collapse to NEWLINE_GLYPH; runs that are only
-- format chars vanish; otherwise a single space.
function M.normalized_input_chars(text)
  local stripped = M.strip_ansi(text)
  local chars = M.chars(stripped)
  local out = {}
  local i = 1
  local n = #chars

  while i <= n do
    local ch = chars[i]
    if is_collapsible_char(ch) then
      local has_break = is_line_break_char(ch)
      local has_real_ws = false
      local j = i
      while j <= n and is_collapsible_char(chars[j]) do
        if is_line_break_char(chars[j]) then has_break = true end
        if not is_cf_only_char(chars[j]) then has_real_ws = true end
        j = j + 1
      end
      if has_break then
        out[#out + 1] = NEWLINE_GLYPH
      elseif has_real_ws then
        out[#out + 1] = " "
      end
      i = j
    else
      out[#out + 1] = ch
      i = i + 1
    end
  end

  return out
end

-- Trim leading/trailing spaces and newline glyphs.
function M.trim_edges(chars)
  local first = 1
  local last = #chars
  while first <= last and (chars[first] == " " or chars[first] == NEWLINE_GLYPH) do
    first = first + 1
  end
  while last >= first and (chars[last] == " " or chars[last] == NEWLINE_GLYPH) do
    last = last - 1
  end
  local out = {}
  for i = first, last do out[#out + 1] = chars[i] end
  return out
end

-- Fallback skeleton for a single char: strip diacritics via tiny fold table
-- then apply CHAR_FOLD. Covers common accented Latin without full NFKD.
local ACCENT_BASE = {
  ["\195\160"] = "a", ["\195\161"] = "a", ["\195\162"] = "a", ["\195\163"] = "a", ["\195\164"] = "a", ["\195\165"] = "a",
  ["\195\166"] = "ae", ["\195\167"] = "c", ["\195\168"] = "e", ["\195\169"] = "e", ["\195\170"] = "e", ["\195\171"] = "e",
  ["\195\172"] = "i", ["\195\173"] = "i", ["\195\174"] = "i", ["\195\175"] = "i",
  ["\195\177"] = "n", ["\195\178"] = "o", ["\195\179"] = "o", ["\195\180"] = "o", ["\195\182"] = "o", ["\195\184"] = "o",
  ["\195\185"] = "u", ["\195\186"] = "u", ["\195\187"] = "u", ["\195\188"] = "u", ["\195\189"] = "y", ["\195\190"] = "th", ["\195\191"] = "y",
  ["\195\128"] = "A", ["\195\129"] = "A", ["\195\130"] = "A", ["\195\131"] = "A", ["\195\132"] = "A", ["\195\133"] = "A",
  ["\195\134"] = "AE", ["\195\135"] = "C", ["\195\136"] = "E", ["\195\137"] = "E", ["\195\138"] = "E", ["\195\139"] = "E",
  ["\195\140"] = "I", ["\195\141"] = "I", ["\195\142"] = "I", ["\195\143"] = "I",
  ["\195\145"] = "N", ["\195\146"] = "O", ["\195\147"] = "O", ["\195\148"] = "O", ["\195\150"] = "O", ["\195\152"] = "O",
  ["\195\153"] = "U", ["\195\154"] = "U", ["\195\155"] = "U", ["\195\156"] = "U", ["\195\157"] = "Y", ["\195\158"] = "TH", ["\195\159"] = "Y",
}

function M.fold_to_ascii(ch)
  if M.CHAR_FOLD[ch] then return M.CHAR_FOLD[ch] end
  local base = ACCENT_BASE[ch]
  if base then return base end
  return nil
end

-- Normalize serialized text into the frame cell vocabulary. Returns a string
-- (markers and glyphs included). Unmapped non-Latin chars become '?' as the safe
-- fallback (the TS normalize does the same when the font+decomposition fails,
-- but emits a marker pair around pictographs; we keep '?' for both).
function M.normalize(text)
  local chars = M.trim_edges(M.normalized_input_chars(text))
  local out = {}
  local totalGraphics = 0
  local fallbackCount = 0

  for _, ch in ipairs(chars) do
    local cp = utf8.codepoint(ch, 1)
    if not cp then
      -- should not happen
    elseif M.is_ascii_or_latin1(cp) then
      out[#out + 1] = ch
      totalGraphics = totalGraphics + 1
    elseif ch == DIM_ON or ch == DIM_OFF or ch == NEWLINE_GLYPH then
      out[#out + 1] = ch
    else
      local emoji = M.EMOJI_FOLD[ch]
      if emoji then
        out[#out + 1] = emoji
        totalGraphics = totalGraphics + 1
      else
        local fold = M.CHAR_FOLD[ch]
        if fold then
          out[#out + 1] = fold
          totalGraphics = totalGraphics + 1
        elseif cp >= 0x2500 and cp <= 0x257f then
          out[#out + 1] = (cp == 0x2502 or cp == 0x2503) and "|" or ((cp == 0x2500 or cp == 0x2501) and "-" or "+")
          totalGraphics = totalGraphics + 1
        else
          local folded = M.fold_to_ascii(ch)
          if folded then
            out[#out + 1] = folded
            totalGraphics = totalGraphics + 1
          else
            out[#out + 1] = "?"
            totalGraphics = totalGraphics + 1
            fallbackCount = fallbackCount + 1
          end
        end
      end
    end
  end

  return table.concat(out), totalGraphics, fallbackCount
end

return M