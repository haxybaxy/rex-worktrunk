-- rex-worktrunk: git worktree pickers for Rex, driven by worktrunk (wt).
-- The pickers are ported from the herdr-worktrunk plugin:
-- https://github.com/devashish2203/herdr-worktrunk
--
--   require("rex-worktrunk").setup{ base = "@" }
--   rex.bind("ctrl+space>g", "worktree")
--   rex.bind("ctrl+space>d", "worktree_remove")
--
-- Actions:
--   worktree         Floating fzf picker over the worktrees and branches of the
--                    repo the focused terminal is in. Enter on a match switches
--                    to it; a typed name that matches nothing creates a worktree
--                    for a new branch (alt-enter forces the typed name). Either
--                    way the worktree opens as a Rex session.
--   worktree_remove  Floating picker over removable worktrees, never the main
--                    checkout. worktrunk runs the removal with its own checks,
--                    then the worktree's Rex session is closed.
--   worktree_go      Open the session for a worktree directory:
--                      rex do worktree_go path=/path/to/repo.feature
--   worktree_close   Close the session of a removed worktree:
--                      rex do worktree_close path=/path/to/repo.feature main=/path/to/repo
--
-- Each worktree gets its own session, remembered by the worktree's path in
-- $XDG_STATE_HOME/rex-worktrunk/sessions, so a session is only reused or
-- closed for the worktree it was made for. The label is only for display:
-- the directory's name, or the label option's. The floats run
-- worktrunk.sh, which hands results back with `rex do`; the app accepts a
-- session switch from the CLI only with Remote Control on (Rex → Settings →
-- Rex Server). An action can't wait for the pick itself: the app stops taking
-- input while a key-bound action runs.

local M = {}

M.version = "0.1.0"

M.options = {
  -- What a new branch starts from: "@" the current branch, "^" the default
  -- branch, a branch name, or false for worktrunk's own default.
  base = "@",
  -- Offer remote-tracking branches (origin/foo) in the switch picker too.
  remotes = false,
  -- Turn a typed "Fix Login Bug" into fix-login-bug before creating it.
  slugify = false,
  -- Where the pickers float: x, y, width, height as fractions of the window.
  bounds = { 0.15, 0.1, 0.7, 0.8 },
  -- function(name, path) returning the layout for a new session, built with
  -- rex.layout. The default is one shell started in the worktree.
  layout = nil,
  -- function(path) returning the label of a new session for a worktree
  -- directory. Only used when the session is created; sessions are found by
  -- path, so renaming one later is fine. The default, and the fallback for a
  -- nil or empty result, is the directory's name.
  label = nil,
  -- The picker script. Defaults to worktrunk.sh beside this file.
  script = nil,
}

local SHELL    = "com.superlogical.terminal.shell"
local TERMINAL = "com.superlogical.terminal"

local state = { layer_id = nil }

local function fail(message)
  error("worktrunk: " .. message, 0)
end

-- The directory this file is in. Rex names a module's chunk by its absolute
-- path; a relative name is taken from beside the init.lua Rex opened.
local function module_dir()
  local src = (debug.getinfo(1, "S").source or ""):gsub("^@", "")
  local dir = src:match("^(/.*)/[^/]*$")
  if dir then return dir end
  local cfg = os.getenv("REX_CONFIG")
  local base = cfg and cfg:match("^(.*)/[^/]*$")
    or (os.getenv("XDG_CONFIG_HOME") or (os.getenv("HOME") .. "/.config")) .. "/rex"
  local rel = src:match("^(.*)/[^/]*$")
  return rel and (base .. "/" .. rel) or base
end

local function expand_home(path)
  if path:sub(1, 2) == "~/" then return os.getenv("HOME") .. path:sub(2) end
  return path
end

local function basename(path)
  return (path:gsub("/+$", ""):match("([^/]+)$"))
end

local function trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function label_for(path)
  if M.options.label then
    local ok, label = pcall(M.options.label, path)
    if not ok then
      rex.log("warn", "rex-worktrunk: label function failed: " .. tostring(label))
    elseif type(label) == "string" and trim(label) ~= "" then
      return label
    end
  end
  return basename(path)
end

-- A worktree directory as the key it is remembered by.
local function normalize(path)
  path = expand_home(trim(path or ""))
  if #path > 1 then path = path:gsub("/+$", "") end
  return path
end

local function is_dir(path)
  local r = rex.exec{ "test", "-d", path }
  return r ~= nil and r.ok
end

-- The working directory of a terminal block: its foreground process's, else
-- the one it was started in. nil when it can't be told; never a guess, since
-- acting on the wrong repo is worse than refusing.
local function block_cwd(block_id)
  if not block_id then return nil end
  local p = rex.block.call(TERMINAL, "process", { block_id = block_id })
  if not p then return nil end
  local fg, child = p.foreground or {}, p.child or {}
  local cwd = fg.cwd or child.cwd
  if cwd and cwd ~= "" then return cwd end
  return nil
end

local function sessions()
  local list, err = rex.call("session.list")
  if list == nil then fail(tostring(err)) end
  return list.sessions or {}
end

-- Which session belongs to which worktree, one "path<TAB>session_id" per line.
-- Rex keeps no data of its own on a session, so the plugin keeps it in a file;
-- it outlives config reloads, and entries for sessions gone are dropped.
local function registry_file()
  local base = os.getenv("XDG_STATE_HOME")
  if not base or base == "" then base = (os.getenv("HOME") or "") .. "/.local/state" end
  return base .. "/rex-worktrunk/sessions"
end

local function load_registry()
  local map = {}
  local f = io.open(registry_file(), "r")
  if not f then return map end
  for line in f:lines() do
    local path, id = line:match("^(.-)\t(%S+)$")
    if path then map[path] = id end
  end
  f:close()
  return map
end

local function save_registry(map)
  local file = registry_file()
  rex.exec{ "mkdir", "-p", (file:match("^(.*)/")) }
  local paths = {}
  for path in pairs(map) do paths[#paths + 1] = path end
  table.sort(paths)
  local tmp = file .. ".tmp"
  local f, err = io.open(tmp, "w")
  if not f then fail("can't save sessions: " .. tostring(err)) end
  for _, path in ipairs(paths) do f:write(path, "\t", map[path], "\n") end
  f:close()
  local ok, rerr = os.rename(tmp, file)
  if not ok then fail("can't save sessions: " .. tostring(rerr)) end
end

-- The registry without sessions that no longer exist.
local function live_registry()
  local map, alive, changed = load_registry(), {}, false
  for _, s in ipairs(sessions()) do alive[s.session_id] = true end
  for path, id in pairs(map) do
    if not alive[id] then map[path] = nil; changed = true end
  end
  if changed then save_registry(map) end
  return map
end

local function default_layout(name, path)
  return rex.layout.block{ flavor = SHELL, options = { cwd = path } }
end

-- The session for a directory, created if missing. Returns session_id, created.
local function session_for(path)
  local map = live_registry()
  if map[path] then return map[path], false end
  local name = label_for(path)
  local created, err = rex.call("session.create", {
    label = name,
    initial_windows = { { layout = (M.options.layout or default_layout)(name, path) } },
  })
  if created == nil then fail(tostring(err)) end
  map[path] = created.session_id
  save_registry(map)
  return created.session_id, true
end

-- Ask the Rex app to show a session.
local function show_in_app(ctx, session_id)
  if ctx.origin == "key" or ctx.origin == "palette" then
    -- The app ran this action, so it accepts the request as is.
    rex.client.queue("session.select", { session_id = session_id })
    return
  end
  -- Run from the CLI or a script: ask the app(s) viewing this session. The app
  -- accepts this only with Remote Control on.
  local apps = rex.call("client.list", { kinds = { "app" }, session_id = ctx.session_id })
  if apps == nil or #(apps.clients or {}) == 0 then
    apps = rex.call("client.list", { kinds = { "app" } })
  end
  local last_err
  for _, c in ipairs(apps and apps.clients or {}) do
    local _, err = rex.call("client.perform", {
      client_id = c.client_id,
      action    = "session.select",
      args      = { session_id = session_id },
      origin    = ctx.origin,
    })
    if err == nil then return end
    last_err = err
  end
  error(last_err or "no Rex app is connected", 0)
end

local function destroy_session(session_id)
  -- A call only reaches a session the connection is attached to, which is the
  -- one the action runs in; attach to the target first.
  local _, aerr = rex.call("session.attach", { session_id = session_id })
  if aerr ~= nil then fail(tostring(aerr)) end
  local _, err = rex.call("session.destroy", { session_id = session_id })
  if err ~= nil then fail(tostring(err)) end
end

local function close_picker()
  if state.layer_id then
    rex.session.close_layer{ layer_id = state.layer_id }
    state.layer_id = nil
  end
end

-- The script with args. The app runs a key-bound action with its own config
-- even in a session on another host, so a script under HOME is found from
-- $HOME on the host the picker runs on.
local function script_command(...)
  local home, script = os.getenv("HOME") or "", M.options.script
  if home ~= "" and script:sub(1, #home + 1) == home .. "/" then
    return { "/bin/sh", "-c", 'script=$HOME/$1; shift; exec "$script" "$@"', "worktrunk.sh", script:sub(#home + 2), ... }
  end
  return { script, ... }
end

-- Open a floating terminal in the focused terminal's repo running command; a
-- picker already open is replaced.
local function open_picker(ctx, command, label)
  local cwd = block_cwd(ctx.block_id)
  if cwd == nil then fail("can't tell the working directory of the focused terminal") end
  close_picker()
  local layer, err = rex.session.new_layer{
    bounds = M.options.bounds,
    focus  = true,
    layout = {
      block = {
        flavor  = SHELL,
        label   = label,
        options = { command = command, cwd = cwd },
      },
    },
  }
  if err ~= nil then fail(tostring(err)) end
  state.layer_id = layer.layer_id
  return layer
end

-- Switch the app to the session for a worktree directory, creating it if needed.
function M.go(ctx, path)
  path = normalize(path)
  if not is_dir(path) then fail("not a directory: " .. path) end
  local session_id, created = session_for(path)
  local ok, err = pcall(show_in_app, ctx, session_id)
  if not ok then
    fail("session for " .. path .. " is ready, but the app would not show it: " .. tostring(err))
  end
  return { session_id = session_id, path = path, created = created }
end

-- Close the session of a removed worktree: only one the plugin opened for that
-- path, never one that merely shares its label. When the app is viewing it, it
-- is moved to the session for main (the main checkout) first.
function M.close(ctx, path, main)
  path = normalize(path)
  local map = live_registry()
  local session_id = map[path]
  if session_id == nil then return { closed = false } end
  map[path] = nil
  save_registry(map)
  if session_id == ctx.session_id and main then
    main = normalize(main)
    if main ~= path and is_dir(main) then M.go(ctx, main) end
  end
  destroy_session(session_id)
  return { closed = true, session_id = session_id }
end

-- Open the switch / create picker.
function M.open(ctx)
  local command = script_command("pick")
  if M.options.base then
    command[#command + 1] = "--base"
    command[#command + 1] = M.options.base
  end
  if M.options.remotes then command[#command + 1] = "--remotes" end
  if M.options.slugify then command[#command + 1] = "--slugify" end
  local layer = open_picker(ctx, command, "worktree")
  return { layer_id = layer.layer_id }
end

-- Open the remove picker.
function M.open_remove(ctx)
  local layer = open_picker(ctx, script_command("remove"), "worktree remove")
  return { layer_id = layer.layer_id }
end

function M.setup(opts)
  local known = { layout = true, script = true, label = true }
  for k in pairs(M.options) do known[k] = true end
  for k, v in pairs(opts or {}) do
    if known[k] then
      M.options[k] = v
    else
      rex.log("warn", "rex-worktrunk: ignoring unknown option " .. tostring(k))
    end
  end
  M.options.script = expand_home(M.options.script or (module_dir() .. "/worktrunk.sh"))

  rex.action{
    name        = "worktree",
    title       = "Worktree: switch / create…",
    description = "Pick a worktree or branch of the repo in the focused terminal, or type a new branch name to create one.",
    category    = "Worktree",
    keywords    = "git worktree branch worktrunk wt",
    run = function(ctx) return M.open(ctx) end,
  }

  rex.action{
    name        = "worktree_remove",
    title       = "Worktree: remove…",
    description = "Pick a worktree of the repo in the focused terminal to remove. The main checkout is never offered.",
    category    = "Worktree",
    keywords    = "git worktree delete remove worktrunk wt",
    run = function(ctx) return M.open_remove(ctx) end,
  }

  rex.action{
    name        = "worktree_go",
    title       = "Open Worktree Session",
    description = "Switch to the session for a worktree directory, creating it if needed.",
    category    = "Worktree",
    args        = { path = "string" },
    run = function(ctx, args) return M.go(ctx, args.path) end,
  }

  rex.action{
    name        = "worktree_close",
    title       = "Close Worktree Session",
    description = "Close the session of a removed worktree. If the app is viewing it, it is moved to the main checkout first.",
    category    = "Worktree",
    args        = { path = "string", main = "string?" },
    run = function(ctx, args) return M.close(ctx, args.path, args.main) end,
  }

  return M
end

return M
