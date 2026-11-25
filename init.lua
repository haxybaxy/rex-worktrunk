-- rex-worktrunk: git worktree pickers for Rex, driven by worktrunk (wt).
-- The pickers are ported from the herdr-worktrunk plugin:
-- https://github.com/devashish2203/herdr-worktrunk
--
--   require("rex-worktrunk").setup{ base = "@" }
--   rex.bind("ctrl+space>g", "worktree")
--   rex.bind("ctrl+space>d", "worktree_remove")
--
-- Actions:
--   worktree         Picker over the worktrees and branches of the repo the
--                    focused terminal is in: fzf in a float, or Rex's command
--                    palette with picker = "native". A match switches to it; a
--                    typed name that matches nothing creates a worktree for a
--                    new branch (in fzf, alt-enter forces the typed name).
--                    Either way the worktree opens as a Rex session, or with
--                    group = "tab" as a tab in its repository's session.
--   worktree_remove  Picker over removable worktrees, never the main checkout.
--                    worktrunk runs the removal with its own checks, then the
--                    worktree's Rex session or tab is closed.
--   worktree_go      Open the session or tab for a worktree directory:
--                      rex do worktree_go path=/path/to/repo.feature
--                    The pickers also pass from, branch and main (see M.go).
--   worktree_close   Close the session or tab of a removed worktree:
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
-- With group = "tab":
--   Each repository has one session, and each of its worktrees a tab in it.
--   The repository's session is the one its main checkout is in, when the
--   plugin remembers that, else a new one labelled after the main checkout's
--   directory. Tabs are tracked the way sessions are: a tab the plugin opens
--   is shown again on the next pick and closed when the worktree is removed,
--   and the tab a picker is used from is adopted and never closed.
--   The option only decides how a worktree that has no place yet gets one. A
--   session or tab that is already remembered is used as it is.
--   The session option can choose another session for a new tab: "current",
--   the one the request came from, or a function returning a session's ID.
--
-- How the pickers hand back:
--   picker = "float", the default: the float runs worktrunk.sh, which picks
--   with fzf, runs worktrunk and hands the result back with `rex do`. The app
--   accepts a session switch from the CLI only with Remote Control on (Rex →
--   Settings → Rex Server).
--   picker = "native": the action asks in Rex's command palette with
--   rex.ui.pick, which pauses it until the person answers. A pick of an
--   existing worktree is finished in the action, so it needs no Remote
--   Control. Creating or removing a worktree goes on in the float without fzf,
--   where worktrunk's hooks and prompts can be seen (see The native picker).
--
-- Sections: options · paths and strings · Rex queries · commands in the repo ·
-- session registry · worktree sessions · worktree tabs · the app · the picker
-- float · the native picker · actions and setup.

local M = {}

M.version = "0.4.0"

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
  -- How the pickers ask: "float" runs fzf in a floating terminal; "native"
  -- lists in Rex's command palette, and uses the float when Rex can't ask
  -- there. See The native picker below.
  picker = "float",
  -- How worktrees are grouped: "session" gives each worktree a session of its
  -- own; "tab" gives each repository one session, and each of its worktrees a
  -- tab in it. See Worktree tabs below.
  group = "session",
  -- With group = "tab", the session a new tab opens in: "current" for the
  -- session the request came from, or function(worktree, ctx) returning a
  -- session's ID. nil, from either, opens it in its repository's session. A
  -- session chosen this way is not remembered as the repository's. See
  -- Worktree tabs below.
  session = nil,
  -- function(label, path, worktree) returning the layout for a new session or
  -- tab, built with rex.layout. The default is one shell started in the
  -- worktree.
  layout = nil,
  -- function(path, worktree) returning the label of a new session or tab. It
  -- is only called when one is created, and never used to find one. The
  -- default, and the fallback for a nil, empty, failing or refused result, is
  -- the directory's name; a tab is labelled with the branch when it is known.
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
  picker  = { "string" },
  group   = { "string" },
  session = { "string", "function" },
  layout  = { "function" },
  label   = { "function" },
  script  = { "string" },
}

-- The values that the options with a fixed set of them take.
local CHOICES = {
  picker  = { "float", "native" },
  group   = { "session", "tab" },
  session = { "current" },
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

local function contains(values, value)
  for _, v in ipairs(values) do
    if v == value then return true end
  end
  return false
end

-- A list from one of Rex's answers, which may leave an empty one out.
local function list_of(value)
  return type(value) == "table" and value or {}
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

-- A session's tabs, which Rex calls windows:
--   { windows   = { [window_id] = true },
--     count     = how many there are,
--     active    = the one the session shows, or nil,
--     window_of = { [block_id] = the tab the block is in } }
-- nil when the session is gone. A call only reaches a session the connection
-- is attached to, and attaching answers with the session's view, so this also
-- lets the calls that follow reach the session.
local function session_view(session_id)
  local attached, err = rex.call("session.attach", { session_id = session_id })
  if attached == nil then
    if live_session_ids()[session_id] then raise(tostring(err)) end
    return nil
  end
  local view = type(attached.view) == "table" and attached.view or {}
  local tabs = { windows = {}, count = 0, window_of = {} }
  if type(view.active_window_id) == "string" then tabs.active = view.active_window_id end
  for _, window in ipairs(list_of(view.windows)) do
    tabs.windows[window.window_id] = true
    tabs.count = tabs.count + 1
    for _, layer in ipairs(list_of(window.layers)) do
      for _, block in ipairs(list_of(layer.blocks)) do
        tabs.window_of[block.block_id] = window.window_id
      end
    end
  end
  return tabs
end

--------------------------------------------------------------------------------
-- Commands in the repo
--
-- The native picker runs git and wt itself. Rex's server has a short PATH,
-- usually without Homebrew's, so each command runs through the login shell,
-- which sets PATH up the way the person's terminals have it.
--------------------------------------------------------------------------------

-- argv as run by the login shell. The arguments are passed to the shell, not
-- written into its script, so nothing in them is read as shell syntax.
local function login_command(argv)
  local shell = os.getenv("SHELL")
  if not shell or shell == "" then shell = "/bin/sh" end
  local command
  if basename(shell) == "fish" then
    command = { shell, "-l", "-c", "exec $argv" }   -- fish: every argument is in $argv
  else
    command = { shell, "-lc", 'exec "$@"', "rex-worktrunk" }   -- the first is $0
  end
  for _, arg in ipairs(argv) do command[#command + 1] = arg end
  return command
end

-- Run argv in dir and return rex.exec's result. Raises when it couldn't start.
local function run(dir, argv, timeout)
  local result, err = rex.exec(login_command(argv), { cwd = dir, timeout = timeout or 10 })
  if result == nil then raise("can't run " .. argv[1] .. ": " .. tostring(err)) end
  return result
end

-- The first line of a command's error output, to put in a message.
local function first_line(s)
  local line = trim(s or ""):match("^[^\n]*")
  return line ~= "" and line or "no output"
end

-- The top of the checkout dir is in, the worktree a pick is made from; nil
-- in a bare repository. Raises when dir is in no repository at all.
local function checkout_top(dir)
  local top = run(dir, { "git", "rev-parse", "--show-toplevel" })
  if top.ok and trim(top.stdout) ~= "" then return trim(top.stdout) end
  if not run(dir, { "git", "rev-parse", "--git-dir" }).ok then
    raise("not a git repository: " .. dir)
  end
  return nil
end

-- What `wt list` reports, one table per row:
--   { kind = "worktree" or "branch", branch = name or nil, path = dir or nil,
--     is_main = true or false }
-- whichever of worktrunk's JSON schemas it printed: a bare array of rows with
-- path and is_main, or { items = rows } with worktree.path and worktree.main.
local function wt_rows(dir)
  local result = run(dir, { "wt", "list", "--format=json" }, 20)
  if not result.ok then raise("wt list failed: " .. first_line(result.stderr)) end
  local data, err = rex.json.decode(result.stdout)
  if type(data) ~= "table" then raise("can't read wt list's output: " .. tostring(err)) end
  local list = data.items or data
  if type(list) ~= "table" then raise("unsupported wt list output") end
  local rows = {}
  for _, item in ipairs(list) do
    local tree = type(item.worktree) == "table" and item.worktree or nil
    rows[#rows + 1] = {
      kind    = item.kind or (tree and "worktree" or "branch"),
      branch  = item.branch,
      path    = item.path or (tree and tree.path),
      is_main = (item.is_main or (tree and tree.main)) == true,
    }
  end
  return rows
end

-- The repo's branches as { name, remote }: local ones, and remote-tracking
-- ones too with the remotes option. origin/HEAD is left out.
local function git_branches(dir)
  local argv = { "git", "for-each-ref", "--format=%(refname) %(refname:short)", "refs/heads" }
  if M.options.remotes then argv[#argv + 1] = "refs/remotes" end
  local result = run(dir, argv)
  if not result.ok then raise("git for-each-ref failed: " .. first_line(result.stderr)) end
  local branches = {}
  for line in result.stdout:gmatch("[^\n]+") do
    local ref, short = line:match("^(%S+) (.+)$")
    if ref and not ref:match("/HEAD$") then
      branches[#branches + 1] = { name = short, remote = ref:find("^refs/remotes/") ~= nil }
    end
  end
  return branches
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
-- A worktree that is a tab of its session (see Worktree tabs) has two more
-- fields: its tab, and the tab it was opened from (may be empty). The session
-- of its repository has a line of its own, with the main checkout's path, the
-- session, an empty field, and "repo" or, when the plugin didn't create the
-- session, "repo-adopted":
--
--   /src/app.fix-login<TAB>session:0192…<TAB>session:0192…<TAB><TAB>window:0194…<TAB>window:0191…
--   /src/app<TAB>session:0192…<TAB><TAB>repo-adopted
--
-- In memory the registry is
--   { entries = { [path] = { session = id, origin = id or nil,
--                            adopted = true or nil, window = id or nil,
--                            origin_window = id or nil } },
--     repos   = { [main checkout] = { session = id, adopted = true or nil } },
--     live    = the set of live session IDs it was checked against,
--     changed = true when it differs from the file }.
--------------------------------------------------------------------------------

local Registry = {}

function Registry.file()
  local base = os.getenv("XDG_STATE_HOME")
  if not base or base == "" then base = (os.getenv("HOME") or "") .. "/.local/state" end
  return base .. "/rex-worktrunk/sessions"
end

function Registry.load()
  local registry = { entries = {}, repos = {} }
  local f = io.open(Registry.file(), "r")
  if not f then return registry end
  for line in f:lines() do
    local fields = {}
    for field in (line .. "\t"):gmatch("([^\t]*)\t") do
      fields[#fields + 1] = field ~= "" and field or false
    end
    local path, session, kind = fields[1], fields[2], fields[4]
    if path and session then
      if kind == "repo" or kind == "repo-adopted" then
        registry.repos[path] = { session = session, adopted = kind == "repo-adopted" or nil }
      else
        registry.entries[path] = {
          session       = session,
          origin        = fields[3] or nil,
          adopted       = kind == "adopted" or nil,
          window        = fields[5] or nil,
          origin_window = fields[6] or nil,
        }
      end
    end
  end
  f:close()
  return registry
end

-- Write the registry atomically: a temporary file renamed over the old one.
function Registry.save(registry)
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
  -- Sorted by path. Empty fields at the end of a line are left out, so a
  -- worktree with a session of its own is written as it always was.
  local lines = {}
  local function add(fields)
    while fields[#fields] == "" do fields[#fields] = nil end
    lines[#lines + 1] = table.concat(fields, "\t")
  end
  for path, entry in pairs(registry.entries) do
    add{ path, entry.session, entry.origin or "", entry.adopted and "adopted" or "",
         entry.window or "", entry.origin_window or "" }
  end
  for main, repo in pairs(registry.repos) do
    add{ main, repo.session, "", repo.adopted and "repo-adopted" or "repo" }
  end
  table.sort(lines)
  for _, line in ipairs(lines) do f:write(line, "\n") end
  f:close()
  local ok, err = os.rename(tmp, file)
  if not ok then
    os.remove(tmp)
    raise("can't save the session registry: " .. tostring(err))
  end
  registry.changed = nil
end

-- The registry without the worktrees and repositories whose session no
-- longer exists.
function Registry.load_live()
  local registry = Registry.load()
  registry.live = live_session_ids()
  for _, known in ipairs{ registry.entries, registry.repos } do
    for path, entry in pairs(known) do
      if not registry.live[entry.session] then
        known[path] = nil
        registry.changed = true
      end
    end
  end
  if registry.changed then Registry.save(registry) end
  return registry
end

-- A session's tabs (see session_view), looked at once per registry. Looking
-- forgets the worktrees whose tab is no longer among them: a tab that was
-- closed takes its worktree's place with it, as a destroyed session does.
function Registry.tabs(registry, session_id)
  registry.views = registry.views or {}
  local view = registry.views[session_id]
  if view == nil then
    view = session_view(session_id) or false
    registry.views[session_id] = view
    for path, entry in pairs(registry.entries) do
      if entry.session == session_id and entry.window and not (view and view.windows[entry.window]) then
        registry.entries[path] = nil
        registry.changed = true
      end
    end
  end
  return view or nil
end

-- Remember place, a session or one tab of it that the plugin didn't create,
-- as the place of the worktree at path:
--   { session = id, window = the tab, or nil for the whole session }
-- A worktree keeps the place it has, and a place belongs to one worktree only:
-- a session that is a worktree's is not adopted again, not even by the tab.
function Registry.adopt(registry, path, place)
  local entries = registry.entries
  if entries[path] then return end
  for _, entry in pairs(entries) do
    if entry.session == place.session
      and (entry.window == nil or place.window == nil or entry.window == place.window) then
      return
    end
  end
  entries[path] = { session = place.session, window = place.window, adopted = true }
  registry.changed = true
end

--------------------------------------------------------------------------------
-- Worktree sessions
--------------------------------------------------------------------------------

-- What the label option says a worktree's session or tab is called; nil when
-- it isn't set or its answer can't be used.
local function option_label(worktree)
  if not M.options.label then return nil end
  local ok, label = pcall(M.options.label, worktree.path, worktree)
  if not ok then
    warn("label function failed: " .. tostring(label))
    return nil
  end
  if label == nil then return nil end
  if type(label) ~= "string" then
    warn("label function returned a " .. type(label) .. ", not a string")
    return nil
  end
  label = trim(label:gsub("%c+", " "))
  return label ~= "" and label or nil
end

-- The labels to try for a worktree's new session or tab, best first: the
-- label option's, then the directory's name. A tab is in a session that is
-- already named after the repository, so the branch, when the request said
-- it, comes before the directory's name.
local function labels_for(worktree, as_tab)
  local labels = {}
  local function add(label)
    if label and label ~= "" and not contains(labels, label) then labels[#labels + 1] = label end
  end
  add(option_label(worktree))
  if as_tab then add(worktree.branch) end
  add(basename(worktree.path))
  return labels
end

-- Call create with each label in turn until Rex takes one, and return its
-- answer. A label Rex refuses, one that is too long for instance, is replaced
-- by the next. what names the thing being created, for the warning.
local function create_labelled(what, labels, create)
  local created, err
  for i, label in ipairs(labels) do
    created, err = create(label)
    if created ~= nil then return created end
    if labels[i + 1] then
      warn("could not create a " .. what .. " labelled \"" .. label .. "\" (" .. tostring(err)
        .. "); trying \"" .. labels[i + 1] .. "\"")
    end
  end
  raise(tostring(err))
end

local function default_layout(_label, path)
  return rex.layout.block{ flavor = SHELL_FLAVOR, options = { cwd = path } }
end

local function worktree_layout(label, worktree)
  if not M.options.layout then return default_layout(label, worktree.path) end
  local ok, layout = pcall(M.options.layout, label, worktree.path, worktree)
  if not ok then raise("layout function failed: " .. tostring(layout)) end
  return layout
end

-- Create the session for a worktree and return its ID.
local function create_session(worktree)
  local labels = labels_for(worktree, false)
  local windows = { { layout = worktree_layout(labels[1], worktree) } }
  local created = create_labelled("session", labels, function(label)
    return rex.call("session.create", { label = label, initial_windows = windows })
  end)
  return created.session_id
end

-- Whether a registry entry is the place { session, window }: that tab, or for
-- an entry without a tab, that session.
local function is_place(entry, place)
  return entry.session == place.session and (entry.window == nil or entry.window == place.window)
end

-- Where the app goes when the session or tab it is viewing is closed: the
-- origin, the place the worktree was opened from, else the main checkout's.
-- nil when neither exists: a session is never created just to leave one.
local function return_destination(registry, entry, main)
  local function usable(place)
    if place.session == nil or not registry.live[place.session] or is_place(entry, place) then
      return false
    end
    if place.window == nil then return true end
    local view = Registry.tabs(registry, place.session)
    return view ~= nil and view.windows[place.window] == true
  end
  local origin = { session = entry.origin, window = entry.origin_window }
  if usable(origin) then return origin end
  local main_entry = main and registry.entries[main]
  if main_entry then
    local place = { session = main_entry.session, window = main_entry.window }
    if usable(place) then return place end
  end
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
-- Worktree tabs
--
-- With group = "tab", a worktree's place is a tab in its repository's session
-- rather than a session of its own. Rex can't move a tab to another session,
-- so the plugin opens the tab where it belongs.
--
-- A repository is known by its main checkout's path. Its session is, in order:
--   * the session remembered for it, which stays its session for as long as
--     that session exists;
--   * the session the main checkout's own place is in. A pick made from the
--     main checkout adopts the tab it came from, so the worktrees then open
--     beside it, in the session the person already works in;
--   * a new session, labelled after the main checkout's directory, with the
--     worktree's tab as its first.
-- A request that doesn't say the main checkout is grouped under the worktree
-- itself. The session option goes before all of these, for one tab at a time:
-- the session it chooses is not the repository's, so it is never closed with
-- its last tab.
--------------------------------------------------------------------------------

-- The live session the session option chooses for a worktree's tab, or nil.
-- Never call it inside pcall: the function may ask with rex.ui.pick.
local function chosen_session(registry, worktree, ctx)
  local choose = M.options.session
  if choose == nil then return nil end
  local session_id
  if choose == "current" then
    session_id = ctx.session_id
  else
    session_id = choose(worktree, ctx)
  end
  if session_id == nil then return nil end
  if type(session_id) == "string" and registry.live[session_id] then return session_id end
  if choose ~= "current" then
    warn("session function returned " .. tostring(session_id)
      .. ", which is not a live session; using the repository's")
  end
  return nil
end

-- Open a tab in a session the connection is attached to. Returns its ID.
local function new_tab(session_id, labels, layout)
  local opened = create_labelled("tab", labels, function(label)
    return rex.call("session.new_window", { session_id = session_id, window_label = label, layout = layout })
  end)
  return opened.window_id
end

-- Open a tab for a worktree in the session the session option chooses, else
-- in its repository's session, creating that if the repository has none.
-- Returns the worktree's registry entry.
local function open_tab(registry, worktree, ctx)
  local chosen = chosen_session(registry, worktree, ctx)
  local main = worktree.main
  if not (main and is_trackable(main)) then main = worktree.path end
  local labels = labels_for(worktree, true)
  local layout = worktree_layout(labels[1], worktree)

  -- Looking at a session attaches to it, which new_tab needs.
  if chosen and Registry.tabs(registry, chosen) then
    return { session = chosen, window = new_tab(chosen, labels, layout) }
  end

  local repo, main_entry = registry.repos[main], registry.entries[main]
  local session_id = repo and repo.session or (main_entry and main_entry.session)
  if session_id and Registry.tabs(registry, session_id) then
    local window_id = new_tab(session_id, labels, layout)
    if not repo then registry.repos[main] = { session = session_id, adopted = true } end
    return { session = session_id, window = window_id }
  end

  local created = create_labelled("tab", labels, function(label)
    return rex.call("session.create", {
      label           = basename(main),
      initial_windows = { { window_label = label, layout = layout } },
    })
  end)
  session_id = created.session_id
  registry.repos[main] = { session = session_id }
  local first = list_of(created.initial_windows)[1]
  local window_id = first and first.window_id or (Registry.tabs(registry, session_id) or {}).active
  if not window_id then raise("Rex didn't say which tab it opened in " .. session_id) end
  return { session = session_id, window = window_id }
end

-- Close a tab. One that is already gone counts as closed, as with
-- destroy_session. The connection must be attached to the session.
local function close_tab(session_id, window_id)
  local _, err = rex.call("session.close_window", { session_id = session_id, window_id = window_id })
  if err ~= nil then
    local view = session_view(session_id)
    if view and view.windows[window_id] then raise(tostring(err)) end
  end
end

-- Whether the plugin created this session for a repository, and for nothing
-- else: such a session has no reason to stay once its last tab is closed.
local function created_for_repo(registry, session_id)
  local found = false
  for _, repo in pairs(registry.repos) do
    if repo.session == session_id then
      if repo.adopted then return false end
      found = true
    end
  end
  return found
end

-- Whether another worktree has its place in this session.
local function is_shared(registry, path, session_id)
  for other, entry in pairs(registry.entries) do
    if other ~= path and entry.session == session_id then return true end
  end
  return false
end

--------------------------------------------------------------------------------
-- The app
--------------------------------------------------------------------------------

-- Ask the Rex app to show a session, and with window_id that tab of it.
-- Raises when no app will.
local function show_session_in_app(ctx, session_id, window_id)
  local target = { session_id = session_id, window_id = window_id }
  if ctx.origin == "key" or ctx.origin == "palette" then
    -- The app ran this action, so it accepts the request as is.
    rex.client.queue("session.select", target)
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
      args      = target,
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

-- The focused terminal's working directory, which is how the repo is chosen.
local function picker_cwd(ctx)
  local cwd = focused_terminal_cwd(ctx.block_id)
  if cwd == nil then raise("can't tell the working directory of the focused terminal") end
  return cwd
end

-- Open a floating terminal running command in cwd, by default the focused
-- terminal's working directory.
local function open_picker(ctx, command, label, cwd)
  cwd = cwd or picker_cwd(ctx)
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

-- The script's --base and --slugify arguments, and --remotes when asked for.
local function script_flags(with_remotes)
  local args = {}
  if type(M.options.base) == "string" and M.options.base ~= "" then
    args[#args + 1] = "--base"
    args[#args + 1] = M.options.base
  end
  if with_remotes and M.options.remotes then args[#args + 1] = "--remotes" end
  if M.options.slugify then args[#args + 1] = "--slugify" end
  return args
end

-- Open a float running the script with args. Returns the layer's ID.
local function open_float(ctx, args, label, cwd)
  local layer = open_picker(ctx, picker_command(args), label, cwd)
  return { layer_id = layer.layer_id }
end

-- The fzf pickers.
local function float_pick(ctx)
  local args = { "pick" }
  for _, flag in ipairs(script_flags(true)) do args[#args + 1] = flag end
  return open_float(ctx, args, "worktree")
end

local function float_remove(ctx)
  return open_float(ctx, { "remove" }, "worktree remove")
end

--------------------------------------------------------------------------------
-- The native picker
--
-- With picker = "native", the pickers list in Rex's command palette with
-- rex.ui.pick. Only switching to an existing worktree is finished in the
-- action: `wt switch` runs here, then its session opens. The rest goes on in
-- the float, with the name already chosen and no fzf:
--   * creating a worktree, because worktrunk's hooks may take longer than an
--     action may run (30 seconds) and may ask for approval;
--   * removing one, because worktrunk may refuse it or ask first;
--   * a pick of an existing worktree whose `wt switch` fails here, so its
--     error can be read.
-- The fzf float is used instead when Rex can't ask in the palette: no Rex app
-- that can show prompts, or a session on another host, where git and wt
-- would run on the wrong machine.
--------------------------------------------------------------------------------

-- Rex lists at most this many items.
local MAX_ITEMS = 2000

-- Whether this pick happens in the palette.
local function use_native(ctx)
  if M.options.picker ~= "native" or ctx.server ~= nil then return false end
  if rex.ui == nil or rex.ui.pick == nil then
    warn("this Rex can't ask in the command palette; using the float")
    return false
  end
  return true
end

-- Ask in the palette. Returns the answer; nil when the person didn't answer;
-- or nil, true when Rex couldn't ask, and the float should. Never call it
-- inside pcall: Rex can only pause an action outside one.
local function ask(prompt)
  local answer, why, detail = rex.ui.pick(prompt)
  if answer ~= nil then return answer end
  if why == "cancelled" or why == "timeout" then return nil end
  if why == "unsupported" or why == "no_client" then
    warn("Rex couldn't ask in the command palette (" .. tostring(why) .. "); using the float")
    return nil, true
  end
  if why == "busy" then raise("Rex is already asking something") end
  raise("Rex couldn't ask: " .. tostring(detail or why))
end

-- A path with the home directory as ~, for showing.
local function tilde(path)
  local home = os.getenv("HOME") or ""
  if home ~= "" and (path == home or path:sub(1, #home + 1) == home .. "/") then
    return "~" .. path:sub(#home + 1)
  end
  return path
end

local function main_checkout(rows)
  for _, row in ipairs(rows) do
    if row.kind == "worktree" and row.is_main then return row.path end
  end
  return nil
end

-- The switch picker's items: worktrees, then branches without one. Also
-- returns the worktree rows by branch.
local function switch_items(rows, branches)
  local items, seen, worktrees = {}, {}, {}
  local function add(item)
    if #items < MAX_ITEMS and not seen[item.id] then
      seen[item.id] = true
      items[#items + 1] = item
    end
  end
  for _, row in ipairs(rows) do
    if row.kind == "worktree" and row.branch and row.path then
      worktrees[row.branch] = row
      add{ id = row.branch, subtitle = tilde(row.path), icon = "folder",
           detail = row.is_main and "main" or "worktree" }
    end
  end
  for _, branch in ipairs(branches) do
    add{ id = branch.name, icon = "branch", detail = branch.remote and "remote" or "branch" }
  end
  for _, row in ipairs(rows) do
    if row.kind ~= "worktree" and row.branch then
      add{ id = row.branch, icon = "branch", detail = "branch" }
    end
  end
  return items, worktrees
end

-- The switch / create picker in the palette.
local function native_pick(ctx)
  local cwd = picker_cwd(ctx)
  local from = checkout_top(cwd)
  local rows = wt_rows(cwd)
  local items, worktrees = switch_items(rows, git_branches(cwd))

  local answer, fallback = ask{
    title       = "Worktree",
    placeholder = "Pick a worktree or branch, or type a new branch name",
    allow_other = true,
    items       = items,
  }
  if fallback then return float_pick(ctx) end
  if answer == nil then return { cancelled = true } end
  -- allow_other: what was typed, rather than an item.
  local name = type(answer) == "table" and trim(answer.text or "") or answer
  if name == "" then return { cancelled = true } end

  local worktree = worktrees[name]
  if worktree then
    local result = run(cwd, { "wt", "switch", name, "--no-cd", "--format=json" }, 20)
    if result.ok then
      return M.go(ctx, worktree.path, { from = from, branch = name, main = main_checkout(rows) })
    end
    warn("wt switch " .. name .. " failed (" .. first_line(result.stderr) .. "); running it in the float")
  end
  local args = { "switch", name }
  for _, flag in ipairs(script_flags(false)) do args[#args + 1] = flag end
  return open_float(ctx, args, "worktree", cwd)
end

-- The remove picker in the palette.
local function native_remove(ctx)
  local cwd = picker_cwd(ctx)
  checkout_top(cwd)   -- raises outside a repository
  local items = {}
  for _, row in ipairs(wt_rows(cwd)) do
    if row.kind == "worktree" and row.branch and not row.is_main and #items < MAX_ITEMS then
      items[#items + 1] = { id = row.branch, subtitle = row.path and tilde(row.path), icon = "folder" }
    end
  end

  local answer, fallback = ask{
    title       = "Remove worktree",
    placeholder = #items > 0 and "worktrunk refuses unmerged branches and dirty worktrees"
                  or "Nothing to remove: there is only the main checkout",
    items       = items,
  }
  if fallback then return float_remove(ctx) end
  if answer == nil then return { cancelled = true } end
  return open_float(ctx, { "remove", answer }, "worktree remove", cwd)
end

--------------------------------------------------------------------------------
-- Actions and setup
--------------------------------------------------------------------------------

-- Where a request came from: its session, when that still exists, and with
-- group = "tab" its tab too, which is the one holding the block the request
-- was made in, else the one the session shows.
local function request_place(ctx, registry)
  if not registry.live[ctx.session_id] then return nil end
  local place = { session = ctx.session_id }
  if M.options.group == "tab" then
    local view = Registry.tabs(registry, ctx.session_id)
    if view == nil then return nil end
    place.window = ctx.block_id and view.window_of[ctx.block_id] or view.active
  end
  return place
end

-- Switch the app to the session or tab for a worktree directory, creating it
-- if needed. request may hold, all optional:
--   from    the worktree the request was made in. The place the request came
--           from is adopted for it (see Registry.adopt).
--   branch  the worktree's branch, for the label and layout options.
--   main    the repo's main checkout, likewise. With group = "tab" it also
--           says which repository's session the tab belongs in.
-- A new place remembers the place the request came from as its origin; so does
-- an existing one whose origin no longer exists.
function M.go(ctx, path, request)
  request = request or {}
  path = normalize_path(path)
  if not is_trackable(path) then raise("not an absolute path: " .. path) end
  if not is_directory(path) then raise("not a directory: " .. path) end

  local registry = Registry.load_live()
  local entries = registry.entries
  local here = request_place(ctx, registry)
  local created = false

  local from = request.from and normalize_path(request.from)
  if here and from and is_trackable(from) then Registry.adopt(registry, from, here) end

  local entry = entries[path]
  if entry and entry.window then
    Registry.tabs(registry, entry.session)   -- forgets the worktree if its tab was closed
    entry = entries[path]
  end
  if entry == nil then
    local worktree = {
      path   = path,
      branch = request.branch,
      main   = request.main and normalize_path(request.main),
    }
    if M.options.group == "tab" then
      entry = open_tab(registry, worktree, ctx)
    else
      entry = { session = create_session(worktree) }
    end
    if here then entry.origin, entry.origin_window = here.session, here.window end
    entries[path] = entry
    registry.changed, created = true, true
  elseif here and not is_place(entry, here) and not registry.live[entry.origin] then
    entry.origin, entry.origin_window = here.session, here.window
    registry.changed = true
  end
  if registry.changed then Registry.save(registry) end

  local ok, err = pcall(show_session_in_app, ctx, entry.session, entry.window)
  if not ok then
    raise("session for " .. path .. " is ready, but the app would not show it: " .. tostring(err))
  end
  return { session_id = entry.session, window_id = entry.window, path = path, created = created }
end

-- Close the session or tab this plugin created for a removed worktree. When
-- the app is viewing it, the app is first moved to return_destination: it is
-- viewing a session the request came from, and a tab when that tab is also the
-- one its session shows. main is the main checkout, a fallback for when the
-- origin is gone. An adopted session or tab is forgotten, not closed.
function M.close(ctx, path, main)
  path = normalize_path(path)
  if main then main = normalize_path(main) end
  local registry = Registry.load_live()
  local entries = registry.entries
  local entry = entries[path]
  local view
  if entry and entry.window then
    view = Registry.tabs(registry, entry.session)   -- forgets the worktree if its tab was closed
    entry = entries[path]
  end
  if entry == nil then
    if registry.changed then Registry.save(registry) end
    return { closed = false }
  end

  local closed, moved_to = false, nil
  -- A session that other worktrees have tabs in is not this worktree's alone
  -- to close, which can happen after the group option was changed.
  if not entry.adopted and (entry.window or not is_shared(registry, path, entry.session)) then
    if ctx.session_id == entry.session and (entry.window == nil or view.active == entry.window) then
      moved_to = return_destination(registry, entry, main)
      if moved_to then
        local ok, err = pcall(show_session_in_app, ctx, moved_to.session, moved_to.window)
        if not ok then
          warn("could not move the app to " .. moved_to.session .. ": " .. tostring(err))
          moved_to = nil
        end
      end
    end
    -- Both raise when what they close survives; the worktree then stays
    -- remembered, so closing can be tried again.
    if entry.window then
      close_tab(entry.session, entry.window)
      local left = session_view(entry.session)
      if left and left.count == 0 and created_for_repo(registry, entry.session) then
        destroy_session(entry.session)
        for repo_main, repo in pairs(registry.repos) do
          if repo.session == entry.session then registry.repos[repo_main] = nil end
        end
      end
    else
      destroy_session(entry.session)
    end
    closed = true
  end
  entries[path] = nil
  Registry.save(registry)
  return {
    closed          = closed,
    session_id      = entry.session,
    window_id       = entry.window,
    moved_to        = moved_to and moved_to.session,
    moved_to_window = moved_to and moved_to.window,
  }
end

-- Open the switch / create picker. Returns the float's layer_id when one
-- opened; with the native picker, M.go's result, or cancelled = true.
function M.open(ctx)
  if use_native(ctx) then return native_pick(ctx) end
  return float_pick(ctx)
end

-- Open the remove picker. Returns the float's layer_id when one opened, or
-- cancelled = true.
function M.open_remove(ctx)
  if use_native(ctx) then return native_remove(ctx) end
  return float_remove(ctx)
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
    elseif CHOICES[name] and type(value) == "string" and not contains(CHOICES[name], value) then
      warn("ignoring option " .. name .. ': expected "' .. table.concat(CHOICES[name], '" or "')
        .. '", got "' .. value .. '"')
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
    description = "Switch to the session or tab for a worktree directory, creating it if needed.",
    category    = "Worktree",
    args        = { path = "string", from = "string?", branch = "string?", main = "string?" },
    run = function(ctx, args) return M.go(ctx, args.path, args) end,
  }

  rex.action{
    name        = "worktree_close",
    title       = "Close Worktree Session",
    description = "Close the session or tab opened for a removed worktree. If the app is viewing it, it first goes back to where the worktree was opened from.",
    category    = "Worktree",
    args        = { path = "string", main = "string?" },
    run = function(ctx, args) return M.close(ctx, args.path, args.main) end,
  }

  return M
end

return M
