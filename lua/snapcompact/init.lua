local compact = require("snapcompact.compact")

local M = {}

local CONTINUE_MESSAGE = "Continue if you have next steps, or stop and ask for clarification if you are unsure how to proceed. If the summary contains a todo list, restore it with todo_write and keep it updated. If you learned important project context during this session, consider saving it to memory before it's lost."

local DEFAULTS = {
  enableAuto = true,
  maxFrames = nil,
  hideImagesInChat = true,
  summaryDisplayText = "Conversation history archived to images.",
  contextAuto = {
    enabled = false,
    ratio = 0.85,
  },
}

local CFG = {}

local function flash(msg)
  if maki.ui and maki.ui.flash then
    maki.ui.flash(msg)
  end
  if maki.log and maki.log.info then
    maki.log.info("[snapcompact] " .. tostring(msg))
  end
end

--- Compact an active session into an image-archived transcript in a new tab.
-- @param sid Session id to compact (defaults to maki.session.current())
-- @param opts Optional table: { maxFrames, request_instructions, is_auto }
-- @return new_session_id or (nil, error_message)
function M.compact_session(sid, opts)
  opts = opts or {}
  sid = sid or maki.session.current()
  if not sid then
    return nil, "no active session to compact"
  end

  local doc, err = maki.session.export({ session = sid })
  if not doc then
    return nil, "failed to export session " .. tostring(sid) .. ": " .. tostring(err)
  end

  local messages = doc.messages or {}
  if #messages == 0 then
    return nil, "session has no messages to compact"
  end

  flash("Snapcompact: rendering conversation history into images...")

  local archive, aerr = compact.compact(messages, {
    model = doc.model and { id = doc.model, provider = doc.model } or nil,
    maxFrames = opts.maxFrames,
  })

  if not archive then
    return nil, "snapcompact failed: " .. tostring(aerr)
  end

  local blocks = compact.history_blocks(archive)
  if #blocks == 0 then
    return nil, "snapcompact produced no content blocks"
  end

  -- Prepend the summary prompt to the opening text block
  local first = blocks[1]
  if first and first.type == "text" then
    first.text = compact.SUMMARY_PROMPT .. "\n\n" .. first.text
  else
    table.insert(blocks, 1, { type = "text", text = compact.SUMMARY_PROMPT })
  end

  local summary_msg = {
    role = "user",
    content = blocks,
  }

  -- Hide the archived-image message from the chat transcript while keeping
  -- its content available to the model. `display_text = ""` is Maki's
  -- transcript-hide convention (used for nudges and compaction notes).
  local hide_images = opts.hideImagesInChat
  if hide_images == nil then
    hide_images = CFG.hideImagesInChat
  end
  if hide_images then
    local shown = opts.summaryDisplayText
    if shown == nil then
      shown = CFG.summaryDisplayText
    end
    summary_msg.display_text = shown or "Conversation history archived to images."
  end

  local n_frames = archive.frames and #archive.frames or 0
  local assistant_note = string.format("Conversation history compacted: %d characters archived onto %d image frame%s.",
    archive.totalChars or 0, n_frames, n_frames == 1 and "" or "s")
  if archive.truncatedChars and archive.truncatedChars > 0 then
    assistant_note = assistant_note .. string.format(" (%d characters dropped to fit budget)", archive.truncatedChars)
  end

  local new_messages = {
    summary_msg,
    {
      role = "assistant",
      content = {
        { type = "text", text = assistant_note .. " The archived history images are loaded. Continuing session." },
      },
    },
  }

  local new_doc = {
    format = doc.format,
    model = doc.model,
    mode = doc.mode,
    thinking = doc.thinking,
    fast = doc.fast,
    title = (doc.title or "Session") .. " (compacted)",
    facts = doc.facts,
    messages = new_messages,
    focus = true,
  }

  if opts.request_instructions and opts.request_instructions ~= "" then
    new_doc.prompt = opts.request_instructions
  elseif opts.is_auto then
    new_doc.prompt = CONTINUE_MESSAGE
  end

  local new_id, nerr = maki.session.new(new_doc)
  if not new_id then
    return nil, "failed to create new session: " .. tostring(nerr)
  end

  flash(string.format("Snapcompact done: %d frames. Switched to %s", n_frames, new_id))
  return new_id
end

local function get_config_paths()
  local paths = {}
  if maki.env and maki.env.config_dir then
    local ok, res = pcall(maki.env.config_dir)
    if ok and res and res ~= "" then
      paths[#paths + 1] = res .. "/snapcompact.json"
    end
  end
  local home = maki.uv and maki.uv.os_getenv("USERPROFILE") or (maki.uv and maki.uv.os_getenv("HOME"))
  if home then
    paths[#paths + 1] = home .. "/.config/maki/snapcompact.json"
    paths[#paths + 1] = home .. "/AppData/Roaming/maki/snapcompact.json"
  end
  return paths
end

local function save_persisted_config()
  if not (maki.json and maki.json.encode and maki.fs and maki.fs.write) then
    return false
  end
  local state = {
    enableAuto = CFG.enableAuto,
    maxFrames = CFG.maxFrames,
    hideImagesInChat = CFG.hideImagesInChat,
    summaryDisplayText = CFG.summaryDisplayText,
    contextAuto = {
      enabled = CFG.contextAuto.enabled,
      ratio = CFG.contextAuto.ratio,
    },
  }
  local ok, encoded = pcall(maki.json.encode, state)
  if not ok or not encoded then return false end
  local paths = get_config_paths()
  for _, p in ipairs(paths) do
    pcall(maki.fs.write, p, encoded)
  end
  return true
end

local function load_persisted_config()
  if not (maki.json and maki.json.decode and maki.fs and maki.fs.read) then
    return nil
  end
  local paths = get_config_paths()
  for _, p in ipairs(paths) do
    local ok, res = pcall(maki.fs.read, p)
    if ok and res and res ~= "" then
      local dok, decoded = pcall(maki.json.decode, res)
      if dok and type(decoded) == "table" then
        return decoded
      end
    end
  end
  return nil
end

function M.setup(config)
  config = config or {}
  local persisted = load_persisted_config() or {}

  -- Precedence: caller config > persisted json file > DEFAULTS
  CFG.enableAuto = config.enableAuto
  if CFG.enableAuto == nil then CFG.enableAuto = persisted.enableAuto end
  if CFG.enableAuto == nil then CFG.enableAuto = DEFAULTS.enableAuto end

  CFG.maxFrames = config.maxFrames or persisted.maxFrames or DEFAULTS.maxFrames

  CFG.hideImagesInChat = config.hideImagesInChat
  if CFG.hideImagesInChat == nil then CFG.hideImagesInChat = persisted.hideImagesInChat end
  if CFG.hideImagesInChat == nil then CFG.hideImagesInChat = DEFAULTS.hideImagesInChat end

  CFG.summaryDisplayText = config.summaryDisplayText
  if CFG.summaryDisplayText == nil then CFG.summaryDisplayText = persisted.summaryDisplayText end
  if CFG.summaryDisplayText == nil then CFG.summaryDisplayText = DEFAULTS.summaryDisplayText end

  local ca = config.contextAuto or persisted.contextAuto or DEFAULTS.contextAuto
  CFG.contextAuto = {
    enabled = ca.enabled == nil and DEFAULTS.contextAuto.enabled or ca.enabled,
    ratio = ca.ratio or DEFAULTS.contextAuto.ratio,
  }

  -- Register /snapcompact command with runtime configuration subcommands
  maki.api.register_command({
    name = "/snapcompact",
    description = "Compact session or configure snapcompact: /snapcompact [prompt] | auto [N%|on|off] | hide [on|off] | frames [N] | status",
    nargs = "*",
    handler = function(opts)
      local raw_args = opts.args and opts.args:match("^%s*(.-)%s*$") or ""

      -- 1. Selftest
      if raw_args == "test" or raw_args == "selftest" then
        flash("Running snapcompact selftest...")
        local ok, t = pcall(require, "snapcompact.selftest")
        if not ok or not t then
          flash("Failed to load selftest: " .. tostring(t))
          return
        end
        local run_ok, err = pcall(t.run)
        if run_ok then
          flash("Snapcompact selftest PASSED!")
        else
          flash("Snapcompact selftest FAILED: " .. tostring(err))
        end
        return
      end

      -- 2. Status / Config inspection
      if raw_args == "status" or raw_args == "config" then
        flash(string.format(
          "Snapcompact: auto=%s (%.0f%%) | nativeHook=%s | hideImages=%s | maxFrames=%s",
          CFG.contextAuto.enabled and "ON" or "OFF",
          CFG.contextAuto.ratio * 100,
          CFG.enableAuto and "ON" or "OFF",
          CFG.hideImagesInChat and "ON" or "OFF",
          tostring(CFG.maxFrames or "auto")
        ))
        return
      end

      -- 3. Help
      if raw_args == "help" then
        flash("/snapcompact [prompt] | auto [N%|on|off] | hide [on|off] | frames [N] | status | test")
        return
      end

      -- 4. Context Auto config: /snapcompact auto [N | N% | 0.N | on | off]
      local auto_arg = raw_args:match("^auto%s*(.-)%s*$")
      if auto_arg then
        if auto_arg == "" then
          CFG.contextAuto.enabled = not CFG.contextAuto.enabled
          save_persisted_config()
          flash(string.format("Snapcompact: context-auto is now %s (%.0f%%).",
            CFG.contextAuto.enabled and "ENABLED" or "DISABLED", CFG.contextAuto.ratio * 100))
          return
        end

        local lower = auto_arg:lower()
        if lower == "off" or lower == "disable" or lower == "false" or lower == "0" then
          CFG.contextAuto.enabled = false
          save_persisted_config()
          flash("Snapcompact: context-auto compaction DISABLED.")
          return
        elseif lower == "on" or lower == "enable" or lower == "true" then
          CFG.contextAuto.enabled = true
          save_persisted_config()
          flash(string.format("Snapcompact: context-auto compaction ENABLED at %.0f%%.", CFG.contextAuto.ratio * 100))
          return
        end

        local num_str = auto_arg:match("^(%d+%.?%d*)%%?$")
        local num = num_str and tonumber(num_str)
        if num then
          local ratio = num > 1 and (num / 100) or num
          if ratio < 0.05 or ratio > 0.99 then
            flash("Snapcompact: threshold must be between 5% and 99% (e.g. 50 or 0.85).")
            return
          end
          CFG.contextAuto.enabled = true
          CFG.contextAuto.ratio = ratio
          save_persisted_config()
          flash(string.format("Snapcompact: context-auto set to %.0f%% (compaction triggers when context exceeds %.0f%%).",
            ratio * 100, ratio * 100))
          return
        end
      end

      -- 5. Hide images toggle: /snapcompact hide [on | off]
      local hide_arg = raw_args:match("^hide%s*(.-)%s*$") or raw_args:match("^hide[_%-]images%s*(.-)%s*$")
      if hide_arg then
        local lower = hide_arg:lower()
        if lower == "on" or lower == "true" or lower == "1" then
          CFG.hideImagesInChat = true
        elseif lower == "off" or lower == "false" or lower == "0" then
          CFG.hideImagesInChat = false
        else
          CFG.hideImagesInChat = not CFG.hideImagesInChat
        end
        save_persisted_config()
        flash(string.format("Snapcompact: hide images in chat is now %s.", CFG.hideImagesInChat and "ON" or "OFF"))
        return
      end

      -- 6. Max frames config: /snapcompact frames <N>
      local frames_arg = raw_args:match("^frames%s+(%d+)$") or raw_args:match("^maxframes%s+(%d+)$")
      if frames_arg then
        local n = tonumber(frames_arg)
        if n and n > 0 then
          CFG.maxFrames = math.floor(n)
          save_persisted_config()
          flash(string.format("Snapcompact: maxFrames set to %d.", CFG.maxFrames))
          return
        end
      end

      -- 7. Default: trigger compaction now
      local sid = maki.session.current()
      if not sid then
        flash("No active session.")
        return
      end
      local instructions = raw_args ~= "" and raw_args or nil
      local new_id, err = M.compact_session(sid, {
        request_instructions = instructions,
        maxFrames = CFG.maxFrames,
      })
      if not new_id then
        flash("Snapcompact failed: " .. tostring(err))
      end
    end,
  })

  -- Intercept compaction via agent.compact.before slot
  maki.api.set_slot("agent.compact.before", function(prev, value, ctx)
    if not CFG.enableAuto then
      return prev(value, ctx)
    end
    if not value or value.reason == "overflow" then
      return prev(value, ctx)
    end

    local sid = ctx and ctx.session_id or maki.session.current()
    if not sid then
      return prev(value, ctx)
    end

    local ok, res = pcall(function()
      return M.compact_session(sid, {
        request_instructions = value.request_instructions,
        is_auto = (value.reason == "auto"),
        maxFrames = CFG.maxFrames,
      })
    end)

    if not ok or not res then
      if maki.log and maki.log.error then
        maki.log.error("[snapcompact] auto-compaction error: " .. tostring(res) .. ", falling back to native")
      end
      return prev(value, ctx)
    end

    return { skip = true }
  end)

  -- Proactive context auto-trigger on TurnEnd. Always registered; checks CFG.contextAuto dynamically.
  local compacting = false
  maki.api.create_autocmd("TurnEnd", {
    callback = function(ev)
      if not CFG.contextAuto.enabled then return end
      if compacting then return end
      local data = ev and ev.data
      if not data then return end
      local size = tonumber(data.context_size)
      local window = tonumber(data.context_window)
      if not size or not window or window <= 0 then return end
      if size < window * CFG.contextAuto.ratio then return end

      local sid = data.session_id or maki.session.current()
      if not sid then return end

      flash(string.format("Snapcompact: context size %d reached %.0f%% of window %d, auto-compacting...",
        size, (size / window) * 100, window))

      compacting = true
      local ok, res = pcall(function()
        return M.compact_session(sid, { is_auto = true, maxFrames = CFG.maxFrames })
      end)
      compacting = false

      if not ok or not res then
        if maki.log and maki.log.error then
          maki.log.error("[snapcompact] context-auto compaction error: " .. tostring(res))
        end
      end
    end,
  })

  if maki.log and maki.log.info then
    maki.log.info("[snapcompact] loaded (/snapcompact command + agent.compact.before slot + TurnEnd context monitor)")
  end
end

M.compact = compact.compact
M.history_blocks = compact.history_blocks
M.SUMMARY_PROMPT = compact.SUMMARY_PROMPT

return M
