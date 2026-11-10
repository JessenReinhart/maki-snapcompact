local M = {}

local PACKAGE_NAME = "maki-snapcompact"

local function find_script_path()
  local candidates = {}

  -- Managed package install: resolve bin/ inside the checkout Maki cloned.
  local ok, packages = pcall(function()
    return maki.pack.get({ PACKAGE_NAME })
  end)
  if ok and packages and packages[1] and packages[1].path then
    candidates[#candidates + 1] =
      maki.fs.joinpath(packages[1].path, "bin", "snapcompact-render.cjs")
  end

  -- Hand-installed/dev fallbacks: global config dir and Windows mirrors.
  local cfg = maki.env.config_dir()
  if cfg then
    candidates[#candidates + 1] = maki.fs.joinpath(cfg, "bin", "snapcompact-render.cjs")
  end
  local home = maki.uv.os_homedir()
  if home then
    candidates[#candidates + 1] = maki.fs.joinpath(home, ".config", "maki", "bin", "snapcompact-render.cjs")
    candidates[#candidates + 1] = maki.fs.joinpath(home, "AppData", "Roaming", "maki", "bin", "snapcompact-render.cjs")
  end

  for _, path in ipairs(candidates) do
    local meta = maki.fs.metadata(path)
    if meta then return path end
  end
  return candidates[1] or "snapcompact-render.cjs"
end

local function get_temp_dir()
  local dir = maki.env.state_dir()
  if dir and maki.fs.metadata(dir) then return dir end
  local home = maki.uv.os_homedir()
  if home then
    local p = maki.fs.joinpath(home, "AppData", "Local", "Temp")
    if maki.fs.metadata(p) then return p end
  end
  return "C:/tmp"
end

--- Render planned frames into base64 PNGs.
-- `planned_frames` is array of `{ text = "...", shape = { ... } }` or strings.
function M.render_frames(planned_frames, default_shape, timeout_ms)
  timeout_ms = timeout_ms or 60000
  local script_path = find_script_path()
  local temp_dir = get_temp_dir()

  local nonce = tostring(os.time()) .. "_" .. tostring(math.random(100000, 999999))
  local in_path = maki.fs.joinpath(temp_dir, "snapcompact_in_" .. nonce .. ".json")
  local out_path = maki.fs.joinpath(temp_dir, "snapcompact_out_" .. nonce .. ".json")

  local payload = {
    frames = planned_frames,
    shape = default_shape,
  }

  local json_str, jerr = maki.json.encode(payload)
  if not json_str then
    return nil, "failed to encode snapcompact render payload: " .. tostring(jerr)
  end

  local ok, werr = maki.fs.write(in_path, json_str)
  if not ok then
    return nil, "failed to write snapcompact input json: " .. tostring(werr)
  end

  local cmd = { "node", script_path, in_path, out_path }
  local job_id, start_err = maki.fn.jobstart(cmd, { scope = "plugin" })
  if not job_id then
    maki.fs.rm(in_path)
    return nil, "failed to start snapcompact render job: " .. tostring(start_err)
  end

  local res, wait_err = maki.fn.jobwait(job_id, timeout_ms)
  if not res then
    maki.fs.rm(in_path)
    maki.fs.rm(out_path)
    return nil, "snapcompact renderer timed out or failed: " .. tostring(wait_err)
  end

  if res.exit_code ~= 0 then
    maki.fs.rm(in_path)
    maki.fs.rm(out_path)
    local err_msg = res.stderr and table.concat(res.stderr, "\n") or "unknown error"
    return nil, "snapcompact renderer exited with code " .. tostring(res.exit_code) .. ": " .. err_msg
  end

  local out_raw, rerr = maki.fs.read(out_path)
  maki.fs.rm(in_path)
  maki.fs.rm(out_path)

  if not out_raw then
    return nil, "failed to read snapcompact output: " .. tostring(rerr)
  end

  local decoded, derr = maki.json.decode(out_raw)
  if not decoded or not decoded.ok then
    return nil, "failed to decode snapcompact output json: " .. tostring(derr or "not ok")
  end

  return decoded.rendered
end

return M
