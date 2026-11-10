local consts = require("snapcompact.constants")
local DIM_ON = consts.DIM_ON
local DIM_OFF = consts.DIM_OFF

local M = {}

local words_raw = "the a an and or of to in on at as is are was were be been by for with that this it its from had has have not but " ..
  "he she his her they their them which also who whom when where while will would could should there then than " ..
  "into over under about after before between during each such these those some most more other only same so"

local STOPWORDS = {}
for word in words_raw:gmatch("%S+") do
  STOPWORDS[word] = true
end
M.STOPWORDS = STOPWORDS

function M.dim_stopwords(text)
  if not text or text == "" then return "" end

  local out = {}
  local dim = false
  local pos = 1
  local len = #text

  while pos <= len do
    local b = text:sub(pos, pos)
    if b == DIM_ON then
      dim = true
      out[#out + 1] = b
      pos = pos + 1
    elseif b == DIM_OFF then
      dim = false
      out[#out + 1] = b
      pos = pos + 1
    elseif dim then
      out[#out + 1] = b
      pos = pos + 1
    else
      -- Check if we are at an alphabetic run [a-zA-Z]
      local s, e = text:find("^[a-zA-Z]+", pos)
      if s then
        local word = text:sub(s, e)
        if STOPWORDS[word:lower()] then
          out[#out + 1] = DIM_ON .. word .. DIM_OFF
        else
          out[#out + 1] = word
        end
        pos = e + 1
      else
        out[#out + 1] = b
        pos = pos + 1
      end
    end
  end

  return table.concat(out)
end

return M
