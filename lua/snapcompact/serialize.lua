local consts = require("snapcompact.constants")

local DIM_ON = consts.DIM_ON
local DIM_OFF = consts.DIM_OFF

local M = {}

-- Strip stray ink toggles so user content cannot forge dim spans.
function M.strip_dim_markers(text)
  if not text then return "" end
  return (text:gsub("[\14\15]", ""))
end

function M.truncate_for_summary(text, maxChars, headRatio)
  if not text then return "" end
  headRatio = headRatio or consts.TRUNCATE_HEAD_RATIO
  if #text <= maxChars then return text end
  local ratio = math.min(math.max(headRatio, 0), 1)
  local headChars = math.floor(maxChars * ratio + 0.5)
  local tailChars = maxChars - headChars
  local elided = #text - maxChars
  local tail = tailChars > 0 and text:sub(#text - tailChars + 1) or ""
  return text:sub(1, headChars) .. " [\226\128\166" .. tostring(elided) .. "ch elided\226\128\166] " .. tail
end

local function format_args(args_table, toolArgMaxChars, toolCallMaxChars, headRatio)
  if not args_table or type(args_table) ~= "table" then return "" end
  local pieces = {}
  for k, v in pairs(args_table) do
    if k ~= "_intent" and k ~= "intent" then
      local val_str
      if type(v) == "string" then
        val_str = string.format("%q", v)
      elseif type(v) == "table" then
        val_str = maki and maki.json and maki.json.encode(v) or "{...}"
      else
        val_str = tostring(v)
      end
      local tr_val = M.truncate_for_summary(val_str, toolArgMaxChars, headRatio)
      pieces[#pieces + 1] = tostring(k) .. "=" .. tr_val
    end
  end
  table.sort(pieces)
  local joined = table.concat(pieces, ", ")
  return M.truncate_for_summary(joined, toolCallMaxChars, headRatio)
end

function M.serialize_conversation(messages, options)
  options = options or {}
  local toolResultMaxChars = options.toolResultMaxChars or consts.TOOL_RESULT_MAX_CHARS
  local toolArgMaxChars = options.toolArgMaxChars or consts.TOOL_ARG_MAX_CHARS
  local toolCallMaxChars = options.toolCallMaxChars or consts.TOOL_CALL_MAX_CHARS
  local headRatio = options.truncateHeadRatio or consts.TRUNCATE_HEAD_RATIO
  local dimToolResults = options.dimToolResults ~= false
  local includeThinking = options.includeThinking ~= false

  -- Index tool results by tool_use_id
  local result_by_call_id = {}
  for _, msg in ipairs(messages) do
    if msg.role == "user" and type(msg.content) == "table" then
      for _, block in ipairs(msg.content) do
        if block.type == "tool_result" and block.tool_use_id then
          local content_text = ""
          if type(block.content) == "string" then
            content_text = block.content
          elseif type(block.content) == "table" then
            local tparts = {}
            for _, sub in ipairs(block.content) do
              if sub.type == "text" and sub.text then
                tparts[#tparts + 1] = sub.text
              end
            end
            content_text = table.concat(tparts, "\n")
          end
          if content_text ~= "" then
            result_by_call_id[block.tool_use_id] = content_text
          end
        end
      end
    end
  end

  local render_result_block = function(raw_text)
    local body = M.truncate_for_summary(M.strip_dim_markers(raw_text), toolResultMaxChars, headRatio)
    if dimToolResults then
      return "<out>\n" .. DIM_ON .. body .. DIM_OFF .. "\n</out>"
    else
      return "<out>\n" .. body .. "\n</out>"
    end
  end

  local parts = {}
  local last_prefix = nil

  local push_part = function(prefix, content)
    if not content or content == "" then return end
    local last_idx = #parts
    if last_idx > 0 and last_prefix == prefix then
      local sep = (parts[last_idx]:sub(-1) == "\n" or content:sub(1, 1) == "\n") and "" or "\n"
      parts[last_idx] = parts[last_idx] .. sep .. content
    else
      parts[#parts + 1] = prefix .. content
      last_prefix = prefix
    end
  end

  local merged_call_ids = {}

  for _, msg in ipairs(messages) do
    local role = msg.role
    local content = msg.content

    if role == "user" then
      local user_texts = {}
      if type(content) == "string" then
        user_texts[#user_texts + 1] = M.strip_dim_markers(content)
      elseif type(content) == "table" then
        for _, b in ipairs(content) do
          if b.type == "text" and b.text and b.text:match("%S") then
            user_texts[#user_texts + 1] = M.strip_dim_markers(b.text)
          end
        end
      end
      if #user_texts > 0 then
        push_part("\194\182user:", table.concat(user_texts, "\n")) -- ¶user:
      end

    elseif role == "assistant" and type(content) == "table" then
      local pending_thinking = {}
      local pending_text = {}

      local flush_assistant = function()
        if #pending_thinking > 0 then
          push_part("\194\182think:", table.concat(pending_thinking, "\n")) -- ¶think:
          pending_thinking = {}
        end
        if #pending_text > 0 then
          push_part("\194\182ai:", table.concat(pending_text, "\n")) -- ¶ai:
          pending_text = {}
        end
      end

      for _, block in ipairs(content) do
        if block.type == "text" then
          local t = M.strip_dim_markers(block.text or "")
          if t:match("%S") then
            pending_text[#pending_text + 1] = t
          end
        elseif block.type == "thinking" then
          if includeThinking then
            local th = M.strip_dim_markers(block.thinking or "")
            if th:match("%S") then
              pending_thinking[#pending_thinking + 1] = th
            end
          end
        elseif block.type == "tool_use" then
          flush_assistant()
          local name = block.name or "unknown"
          local input = block.input or {}
          local intent = input._intent or input.intent or block.description or ""
          if type(intent) == "string" and intent ~= "" then
            intent = "//" .. M.strip_dim_markers(intent:gsub("%s+", " "):match("^%s*(.-)%s*$"))
          else
            intent = ""
          end

          local args_str = format_args(input, toolArgMaxChars, toolCallMaxChars, headRatio)
          local call_line = name .. "(" .. args_str .. ")" .. intent
          local lines = { call_line }

          local res_text = block.id and result_by_call_id[block.id]
          if res_text then
            merged_call_ids[block.id] = true
            lines[#lines + 1] = render_result_block(res_text)
          end

          push_part("\194\182call:", table.concat(lines, "\n")) -- ¶call:
        end
      end
      flush_assistant()
    end
  end

  return table.concat(parts, "\n\n")
end

return M
