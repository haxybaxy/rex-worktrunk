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
--                    The pickers also pass from, branch and main (see M.go).
--   worktree_close   Close the session of a removed worktree:
--                      rex do worktree_close path=/path/to/repo.feature main=/path/to/repo
--
-- How sessions are tracked:
--   Each worktree has one session, remembered by the worktree's path in a
--   registry file (see Registry below). Sessions are never found by label: a
--   label is only what a new session is called, and renaming it changes nothing.
--     * A session the plugin creates for a worktree is opened again on the next
--       pick and closed when the worktree is removed. It remembers its origin,
--       the session it was opened from; closing the session you are in takes
--       the app back there.
--     * The session a picker is used from is adopted for the worktree its
--       terminal was in, unless that worktree or that session is already
--       remembered. Picking that worktree later goes back to it instead of
--       opening a second session. An adopted session is never closed.
--
-- How the pickers hand back:
--   The floats run worktrunk.sh, which hands results back with `rex do`; the
--   app accepts a session switch from the CLI only with Remote Control on
--   (Rex → Settings → Rex Server). An action can't wait for the pick itself:
--   the app stops taking input while a key-bound action runs.
--
-- Sections: options · paths and strings · Rex queries · session registry ·
-- worktree sessions · the app · the picker float · actions and setup.

local M = {}

M.version = "0.2.0"

--------------------------------------------------------------------------------
-- Options
--------------------------------------------------------------------------------

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
  -- function(label, path, worktree) returning the layout for a new session,
  -- built with rex.layout. The default is one shell started in the worktree.
  layout = nil,
  -- function(path, worktree) returning the label of a new session. It is only
  -- called when a session is created, and never used to find one. The default,
  -- and the fallback for a nil, empty, failing or refused result, is the
  -- directory's name.
  label = nil,
  -- The picker script. Defaults to worktrunk.sh beside this file.
  script = nil,
}

-- The worktree table given to label and layout:
--   path    the worktree's directory
--   branch  its branch, or nil when the request didn't say
--   main    the repo's main checkout, or nil when the request didn't say
-- The pickers always say; `rex do worktree_go path=…` alone doesn't.

-- Every option setup accepts, and the types its value may have.
local OPTION_TYPES = {
  base    = { "string", "boolean" },
  remotes = { "boolean" },
  slugify = { "boolean" },
  bounds  = { "table" },
  layout  = { "function" },
  label   = { "function" },
  script  = { "string" },
}

local SHELL_FLAVOR     = "com.superlogical.terminal.shell"
local TERMINAL_CREATOR = "com.superlogical.terminal"

--------------------------------------------------------------------------------
-- Paths and strings
--------------------------------------------------------------------------------

-- Fail the running action with a message for whoever ran it.
local function raise(message)
  error("worktrunk: " .. message, 0)
end

local function warn(message)
  rex.log("warn", "rex-worktrunk: " .. message)
end

local function trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function expand_home(path)
  if path:sub(1, 2) == "~/" then return (os.getenv("HOME") or "") .. path:sub(2) end
  return path
end

-- A worktree directory as the registry knows it: ~ expanded, surrounding
-- whitespace and trailing slashes removed.
local function normalize_path(path)
  path = expand_home(trim(path or ""))
  if #path > 1 then path = path:gsub("/+$", "") end
  return path
end

-- Whether a normalized path can be a registry key: absolute, and without the
-- characters that separate the registry's fields and lines.
local function is_trackable(path)
  return path:sub(1, 1) == "/" and not path:find("%c")
end

local function basename(path)
  return path:match("([^/]+)/*$") or path
end

-- The directory this file is in. Rex names a module's chunk by its absolute
-- path; a relative name is taken from beside the init.lua Rex opened.
local function plugin_dir()
  local source = (debug.getinfo(1, "S").source or ""):gsub("^@", "")
  local dir = source:match("^(/.*)/[^/]*$")
  if dir then return dir end
  local config = os.getenv("REX_CONFIG")
  local config_dir = config and config:match("^(.*)/[^/]*$")
    or (os.getenv("XDG_CONFIG_HOME") or (os.getenv("HOME") .. "/.config")) .. "/rex"
  local relative = source:match("^(.*)/[^/]*$")
  return relative and (config_dir .. "/" .. relative) or config_dir
end

--------------------------------------------------------------------------------
-- Rex queries
--------------------------------------------------------------------------------

local function is_directory(path)
  local result = rex.exec{ "test", "-d", path }
  return result ~= nil and result.ok
end

-- The working directory of a terminal block: its foreground process's, else
-- the one it was started in. nil when it can't be told; never a guess, since
-- acting on the wrong repo is worse than refusing.
local function focused_terminal_cwd(block_id)
  if not block_id then return nil end
  local process = rex.block.call(TERMINAL_CREATOR, "process", { block_id = block_id })
  if not process then return nil end
  local foreground, child = process.foreground or {}, process.child or {}
  local cwd = foreground.cwd or child.cwd
  if cwd and cwd ~= "" then return cwd end
  return nil
end

-- The IDs of the sessions that exist right now, as a set.
local function live_session_ids()
  local list, err = rex.call("session.list")
  if list == nil then raise(tostring(err)) end
  local ids = {}
  for _, s in ipairs(list.sessions or {}) do ids[s.session_id] = true end
  return ids
end

--------------------------------------------------------------------------------
-- Session registry
--
-- Which session belongs to which worktree. Rex keeps no data of its own on a
-- session, and a key-bound action runs in the app while `rex do` runs on the
-- server, so the plugin keeps it in a file both can read:
--
--   $XDG_STATE_HOME/rex-worktrunk/sessions        (~/.local/state by default)
--
-- One line per worktree, tab-separated: the worktree's path, its session, the
-- session it was opened from (its origin, may be empty), and "adopted" when
-- the plugin didn't create the session:
--
--   /src/app.fix-login<TAB>session:0193…<TAB>session:0192…
--   /src/app<TAB>session:0192…<TAB><TAB>adopted
--
-- In memory the registry is
--   { [path] = { session = id, origin = id or nil, adopted = true or nil } }.
--------------------------------------------------------------------------------

local Registry = {}

function Registry.file()
  local base = os.getenv("XDG_STATE_HOME")
  if not base or base == "" then base = (os.getenv("HOME") or "") .. "/.local/state" end
  return base .. "/rex-worktrunk/sessions"
end

function Registry.load()
  local entries = {}
  local f = io.open(Registry.file(), "r")
  if not f then return entries end
  for line in f:lines() do
    local fields = {}
    for field in (line .. "\t"):gmatch("([^\t]*)\t") do fields[#fields + 1] = field end
    local path, session, origin, kind = fields[1], fields[2], fields[3], fields[4]
    if path ~= "" and session and session ~= "" then
      entries[path] = {
        session = session,
        origin  = origin ~= "" and origin or nil,
        adopted = kind == "adopted" or nil,
      }
    end
  end
  f:close()
  return entries
end

-- Write the registry atomically: a temporary file renamed over the old one.
function Registry.save(entries)
  local file = Registry.file()
  -- Unique per writer, so two actions saving at once can't mix their lines.
  local tmp = file .. ".tmp." .. os.time() .. "." .. tostring({}):match("(%x+)$")
  local f = io.open(tmp, "w")
  if not f then
    rex.exec{ "mkdir", "-p", (file:match("^(.*)/")) }
    local err
    f, err = io.open(tmp, "w")
    if not f then raise("can't save the session registry: " .. tostring(err)) end
  end
  local paths = {}
  for path in pairs(entries) do paths[#paths + 1] = path end
  table.sort(paths)
  for _, path in ipairs(paths) do
    local entry = entries[path]
    local line = { path, entry.session }
    if entry.origin or entry.adopted then line[3] = entry.origin or "" end
    if entry.adopted then line[4] = "adopted" end
    f:write(table.concat(line, "\t"), "\n")
  end
  f:close()
  local ok, err = os.rename(tmp, file)
  if not ok then
    os.remove(tmp)
    raise("can't save the session registry: " .. tostring(err))
  end
end

-- The registry without the worktrees whose session no longer exists, and the
-- set of live session IDs it was checked against.
function Registry.load_live()
  local entries, live, pruned = Registry.load(), live_session_ids(), false
  for path, entry in pairs(entries) do
    if not live[entry.session] then
      entries[path] = nil
      pruned = true
    end
  end
  if pruned then Registry.save(entries) end
  return entries, live
end

-- Remember session_id, a session the plugin didn't create, as the session of
-- the worktree at path. A worktree keeps the session it has, and a session
-- belongs to one worktree only. Returns whether anything changed.
function Registry.adopt(entries, path, session_id)
  if entries[path] then return false end
  for _, entry in pairs(entries) do
    if entry.session == session_id then return false end
  end
  entries[path] = { session = session_id, adopted = true }
  return true
end

--------------------------------------------------------------------------------
-- Worktree sessions
--------------------------------------------------------------------------------

-- The label of a new session: the label option's, else the directory's name.
local function session_label(worktree)
  local default = basename(worktree.path)
  if not M.options.label then return default end
  local ok, label = pcall(M.options.label, worktree.path, worktree)
  if not ok then
    warn("label function failed: " .. tostring(label))
    return default
  end
  if label == nil then return default end
  if type(label) ~= "string" then
    warn("label function returned a " .. type(label) .. ", not a string")
    return default
  end
  label = trim(label:gsub("%c+", " "))
  return label ~= "" and label or default
end

local function default_layout(_label, path)
  return rex.layout.block{ flavor = SHELL_FLAVOR, options = { cwd = path } }
end

local function session_layout(label, worktree)
  if not M.options.layout then return default_layout(label, worktree.path) end
  local ok, layout = pcall(M.options.layout, label, worktree.path, worktree)
  if not ok then raise("layout function failed: " .. tostring(layout)) end
  return layout
end

-- Create the session for a worktree and return its ID. A label Rex refuses,
-- one that is too long for instance, is replaced by the directory's name.
local function create_session(worktree)
  local label = session_label(worktree)
  local windows = { { layout = session_layout(label, worktree) } }
  local created, err = rex.call("session.create", { label = label, initial_windows = windows })
  local default = basename(worktree.path)
  if created == nil and label ~= default then
    warn("could not create a session labelled \"" .. label .. "\" (" .. tostring(err)
      .. "); trying \"" .. default .. "\"")
    created, err = rex.call("session.create", { label = default, initial_windows = windows })
  end
  if created == nil then raise(tostring(err)) end
  return created.session_id
end

-- Where the app goes when the session it is viewing is closed: the origin,
-- the session the worktree was opened from, else the main checkout's session.
-- nil when neither exists: a session is never created just to leave one.
local function return_destination(entry, main, entries, live)
  local function usable(id) return id ~= nil and id ~= entry.session and live[id] == true end
  if usable(entry.origin) then return entry.origin end
  local main_entry = main and entries[main]
  if main_entry and usable(main_entry.session) then return main_entry.session end
  return nil
end

-- Destroy a session. One that is already gone counts as destroyed: the picker
-- and worktrunk's post-remove hook may both close the same worktree.
local function destroy_session(session_id)
  -- A call only reaches a session the connection is attached to, which is the
  -- one the action runs in; attach to the target first.
  local _, err = rex.call("session.attach", { session_id = session_id })
  if err == nil then
    _, err = rex.call("session.destroy", { session_id = session_id })
  end
  if err ~= nil and live_session_ids()[session_id] then raise(tostring(err)) end
end

--------------------------------------------------------------------------------
-- The app
--------------------------------------------------------------------------------

-- Ask the Rex app to show a session. Raises when no app will.
local function show_session_in_app(ctx, session_id)
  if ctx.origin == "key" or ctx.origin == "palette" then
    -- The app ran this action, so it accepts the request as is.
    rex.client.queue("session.select", { session_id = session_id })
    return
  end
  -- Run from the CLI or a script: ask the app(s) viewing this session, else
  -- any app. The app accepts this only with Remote Control on.
  local apps = rex.call("client.list", { kinds = { "app" }, session_id = ctx.session_id })
  if apps == nil or #(apps.clients or {}) == 0 then
    apps = rex.call("client.list", { kinds = { "app" } })
  end
  local last_err
  for _, client in ipairs(apps and apps.clients or {}) do
    local _, err = rex.call("client.perform", {
      client_id = client.client_id,
      action    = "session.select",
      args      = { session_id = session_id },
      origin    = ctx.origin,
    })
    if err == nil then return end
    last_err = err
  end
  error(last_err or "no Rex app is connected", 0)
end

--------------------------------------------------------------------------------
-- The picker float
--------------------------------------------------------------------------------

-- The floating layer of the picker this config opened last, so a new picker
-- replaces it instead of stacking on it.
local picker = { layer_id = nil }

local function close_picker()
  if picker.layer_id then
    rex.session.close_layer{ layer_id = picker.layer_id }
    picker.layer_id = nil
  end
end

-- The command that runs the picker script with args. The app runs a key-bound
-- action with its own config even in a session on another host, so a script
-- under HOME is started as $HOME/<the rest of its path> on the host the picker
-- runs on.
local function picker_command(args)
  local home, script = os.getenv("HOME") or "", M.options.script
  local command
  if home ~= "" and script:sub(1, #home + 1) == home .. "/" then
    command = { "/bin/sh", "-c", 'script=$HOME/$1; shift; exec "$script" "$@"',
                "worktrunk.sh", script:sub(#home + 2) }
  else
    command = { script }
  end
  for _, arg in ipairs(args) do command[#command + 1] = arg end
  return command
end

-- Open a floating terminal running command in the focused terminal's working
-- directory, which is how the repo is chosen.
local function open_picker(ctx, command, label)
  local cwd = focused_terminal_cwd(ctx.block_id)
  if cwd == nil then raise("can't tell the working directory of the focused terminal") end
  close_picker()
  local layer, err = rex.session.new_layer{
    bounds = M.options.bounds,
    focus  = true,
    layout = {
      block = {
        flavor  = SHELL_FLAVOR,
        label   = label,
        options = { command = command, cwd = cwd },
      },
    },
  }
  if err ~= nil then raise(tostring(err)) end
  picker.layer_id = layer.layer_id
  return layer
end

--------------------------------------------------------------------------------
-- Actions and setup
--------------------------------------------------------------------------------

-- Switch the app to the session for a worktree directory, creating it if
-- needed. request may hold, all optional:
--   from    the worktree the request was made in. The session the request
--           came from is adopted for it (see Registry.adopt).
--   branch  the worktree's branch, for the label and layout options.
--   main    the repo's main checkout, likewise.
-- A new session remembers the session the request came from as its origin; so
-- does an existing one whose origin no longer exists.
function M.go(ctx, path, request)
  request = request or {}
  path = normalize_path(path)
  if not is_trackable(path) then raise("not an absolute path: " .. path) end
  if not is_directory(path) then raise("not a directory: " .. path) end

  local entries, live = Registry.load_live()
  local here = live[ctx.session_id] and ctx.session_id or nil
  local changed, created = false, false

  local from = request.from and normalize_path(request.from)
  if here and from and is_trackable(from) then
    changed = Registry.adopt(entries, from, here)
  end

  local entry = entries[path]
  if entry == nil then
    local worktree = {
      path   = path,
      branch = request.branch,
      main   = request.main and normalize_path(request.main),
    }
    entry = { session = create_session(worktree), origin = here }
    entries[path] = entry
    changed, created = true, true
  elseif here and here ~= entry.session and not live[entry.origin] then
    entry.origin = here
    changed = true
  end
  if changed then Registry.save(entries) end

  local ok, err = pcall(show_session_in_app, ctx, entry.session)
  if not ok then
    raise("session for " .. path .. " is ready, but the app would not show it: " .. tostring(err))
  end
  return { session_id = entry.session, path = path, created = created }
end

-- Close the session this plugin created for a removed worktree. When the
-- request came from that session, the app is viewing it, so the app is first
-- moved to return_destination. main is the main checkout, a fallback for when
-- the origin is gone. An adopted session is forgotten, not closed.
function M.close(ctx, path, main)
  path = normalize_path(path)
  if main then main = normalize_path(main) end
  local entries, live = Registry.load_live()
  local entry = entries[path]
  if entry == nil then return { closed = false } end

  local moved_to
  if not entry.adopted then
    if ctx.session_id == entry.session then
      moved_to = return_destination(entry, main, entries, live)
      if moved_to then
        local ok, err = pcall(show_session_in_app, ctx, moved_to)
        if not ok then
          warn("could not move the app to " .. moved_to .. ": " .. tostring(err))
          moved_to = nil
        end
      end
    end
    -- Raises when the session survives; the worktree then stays remembered,
    -- so closing can be tried again.
    destroy_session(entry.session)
  end
  entries[path] = nil
  Registry.save(entries)
  return { closed = not entry.adopted, session_id = entry.session, moved_to = moved_to }
end

-- Open the switch / create picker.
function M.open(ctx)
  local args = { "pick" }
  if type(M.options.base) == "string" and M.options.base ~= "" then
    args[#args + 1] = "--base"
    args[#args + 1] = M.options.base
  end
  if M.options.remotes then args[#args + 1] = "--remotes" end
  if M.options.slugify then args[#args + 1] = "--slugify" end
  local layer = open_picker(ctx, picker_command(args), "worktree")
  return { layer_id = layer.layer_id }
end

-- Open the remove picker.
function M.open_remove(ctx)
  local layer = open_picker(ctx, picker_command{ "remove" }, "worktree remove")
  return { layer_id = layer.layer_id }
end

function M.setup(opts)
  for name, value in pairs(opts or {}) do
    local types = OPTION_TYPES[name]
    local fits = false
    for _, t in ipairs(types or {}) do fits = fits or type(value) == t end
    if not types then
      warn("ignoring unknown option " .. tostring(name))
    elseif not fits then
      warn("ignoring option " .. name .. ": expected a " .. table.concat(types, " or ")
        .. ", got a " .. type(value))
    else
      M.options[name] = value
    end
  end
  M.options.script = expand_home(M.options.script or (plugin_dir() .. "/worktrunk.sh"))

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
    args        = { path = "string", from = "string?", branch = "string?", main = "string?" },
    run = function(ctx, args) return M.go(ctx, args.path, args) end,
  }

  rex.action{
    name        = "worktree_close",
    title       = "Close Worktree Session",
    description = "Close the session opened for a removed worktree. If the app is viewing it, it first goes back to the session the worktree was opened from.",
    category    = "Worktree",
    args        = { path = "string", main = "string?" },
    run = function(ctx, args) return M.close(ctx, args.path, args.main) end,
  }

  return M
end

return M
