-- Checks the native picker (picker = "native") against the fake rex in
-- fake_rex.lua: what it lists in the palette, what it does with each answer,
-- and when it uses the float instead. Needs only Lua 5.1 (or LuaJIT):
--
--   luajit test/native_test.lua

local here = (debug.getinfo(1, "S").source or ""):gsub("^@", ""):match("^(.*)/[^/]*$") or "."
package.path = here .. "/?.lua;" .. package.path

local t = require("helper")
local fake = require("fake_rex").install()

local HOME = "/home/me"
local MAIN, FEAT = HOME .. "/src/app", HOME .. "/src/app.feat"
local SCRIPT = "/opt/wt/worktrunk.sh"

local function ok(stdout) return { ok = true, code = 0, stdout = stdout or "", stderr = "" } end
local function fail(stderr) return { ok = false, code = 1, stdout = "", stderr = stderr or "" } end

-- The repo the focused terminal is in, as git and wt report it. A test
-- changes a field to change what they say.
local repo

local function wt_list_rows()
  return {
    { kind = "worktree", branch = "main", path = MAIN, is_main = true },
    { kind = "worktree", branch = "feat", path = FEAT, is_main = false },
  }
end

local function answer_command(argv)
  local line = table.concat(argv, " ")
  if line == "git rev-parse --show-toplevel" then
    return repo.top and ok(repo.top .. "\n") or fail("fatal: not a git repository")
  elseif line == "git rev-parse --git-dir" then
    return repo.git_dir and ok(".git\n") or fail("fatal: not a git repository")
  elseif argv[1] == "git" and argv[2] == "for-each-ref" then
    local lines = {}
    for _, ref in ipairs(repo.refs) do
      local wanted = false
      for i = 4, #argv do wanted = wanted or ref:find("^" .. argv[i] .. "/") ~= nil end
      if wanted then lines[#lines + 1] = ref .. " " .. ref:gsub("^refs/heads/", ""):gsub("^refs/remotes/", "") end
    end
    return ok(table.concat(lines, "\n") .. "\n")
  elseif line == "wt list --format=json" then
    if repo.wt_list_fails then return fail("wt: boom\nmore") end
    return ok(fake:json(repo.rows))
  elseif argv[1] == "wt" and argv[2] == "switch" then
    return repo.switch_fails and fail("needs approval\n") or ok(fake:json({ path = FEAT, branch = argv[3] }))
  end
  return fail("unexpected command: " .. line)
end

local function fresh(opts)
  fake:reset()
  fake.env.HOME = HOME
  fake.env.SHELL = "/bin/zsh"
  fake.cwd = FEAT
  fake.dirs = { [MAIN] = true, [FEAT] = true }
  fake.run = answer_command
  repo = {
    top = FEAT,
    git_dir = true,
    rows = wt_list_rows(),
    refs = { "refs/heads/feat", "refs/heads/main", "refs/heads/stale",
             "refs/remotes/origin/HEAD", "refs/remotes/origin/main" },
  }
  local options = { script = SCRIPT, picker = "native" }
  for k, v in pairs(opts or {}) do options[k] = v end
  return t.load_plugin(options)
end

local function key_ctx()
  return { origin = "key", session_id = fake:add_session("home"), block_id = "block:focused" }
end

local function questions() return fake:calls_to("ui.pick") end
local function question() local q = questions(); return q[#q] and q[#q].args end

-- The ids, details and icons of the last question's items, as strings.
local function item_ids(prompt)
  local ids = {}
  for i, item in ipairs(prompt.items) do ids[i] = item.id end
  return ids
end

local function floats() return fake:calls_to("session.new_layer") end

-- The script arguments of the last float.
local function float_args()
  local layers = floats()
  local layer = layers[#layers]
  if not layer then return nil end
  local command, args = layer.args.layout.block.options.command, {}
  for i = 2, #command do args[#args + 1] = command[i] end
  return args, layer.args
end

local function ran(argv_line)
  for _, cmd in ipairs(fake:commands()) do
    if table.concat(cmd.argv, " ") == argv_line then return cmd end
  end
  return nil
end

--------------------------------------------------------------------------------
t.section("the option")
--------------------------------------------------------------------------------

do
  local M = fresh{ picker = "fzf" }
  t.check("an unknown picker is ignored with a warning",
    M.options.picker == "float" and #fake:warnings() == 1 and fake:warnings()[1]:find("picker", 1, true),
    t.show(fake:warnings()))
end

do
  local M = fresh()
  M.open(key_ctx())
  t.check("native asks in the palette instead of opening a float",
    #questions() == 1 and #floats() == 0)
end

do
  local M = fresh{ picker = "float" }
  M.open(key_ctx())
  t.check("float opens the fzf float without asking",
    #questions() == 0 and t.same_list(float_args(), { "pick", "--base", "@" }), t.show(float_args() or {}))
end

--------------------------------------------------------------------------------
t.section("when Rex can't ask in the palette")
--------------------------------------------------------------------------------

do
  local M = fresh()
  rex.ui = nil
  M.open(key_ctx())
  t.check("a Rex without rex.ui gets the fzf float, with a warning",
    t.same_list(float_args(), { "pick", "--base", "@" }) and #fake:warnings() == 1, t.show(fake:warnings()))
end

do
  local M = fresh()
  local ctx = key_ctx()
  ctx.server = "devbox"
  M.open(ctx)
  M.open_remove(ctx)
  t.check("a session on another host gets the floats, without a warning or a command run here",
    #questions() == 0 and #floats() == 2 and #fake:commands() == 0 and #fake:warnings() == 0)
end

for _, why in ipairs{ "unsupported", "no_client" } do
  local M = fresh()
  fake:answer(nil, why)
  M.open(key_ctx())
  t.check(why .. " falls back to the fzf float",
    t.same_list(float_args(), { "pick", "--base", "@" }) and #fake:warnings() == 1, t.show(float_args() or {}))
end

do
  local M = fresh()
  fake:answer(nil, "busy")
  local err = t.error_of(M.open, key_ctx())
  t.check("busy is an error, with no float", err and err:find("already asking", 1, true) and #floats() == 0, err)
end

do
  local M = fresh()
  fake:answer(nil, "failed", "the prompt was too big")
  local err = t.error_of(M.open, key_ctx())
  t.check("failed is an error that says why", err and err:find("the prompt was too big", 1, true), err)
end

--------------------------------------------------------------------------------
t.section("what the switch picker lists")
--------------------------------------------------------------------------------

do
  local M = fresh()
  M.open(key_ctx())
  local prompt = question()
  t.check("worktrees, then branches without one, each once",
    t.same_list(item_ids(prompt), { "main", "feat", "stale" }), t.show(item_ids(prompt)))
  t.check("a worktree shows its directory with ~ and a folder",
    prompt.items[2].subtitle == "~/src/app.feat" and prompt.items[2].icon == "folder"
      and prompt.items[2].detail == "worktree" and prompt.items[1].detail == "main")
  t.check("a branch shows a branch icon", prompt.items[3].icon == "branch" and prompt.items[3].detail == "branch")
  t.check("typed text is accepted, to create a branch", prompt.allow_other == true and prompt.title == "Worktree")
  t.check("git and wt run in the focused terminal's directory through the login shell",
    ran("wt list --format=json").cwd == FEAT
      and t.same_list(ran("wt list --format=json").shell,
        { "/bin/zsh", "-lc", 'exec "$@"', "rex-worktrunk", "wt", "list", "--format=json" }))
end

do
  local M = fresh{ remotes = true }
  M.open(key_ctx())
  local prompt = question()
  t.check("remotes adds remote-tracking branches, but not origin/HEAD",
    t.same_list(item_ids(prompt), { "main", "feat", "stale", "origin/main" })
      and prompt.items[4].detail == "remote", t.show(item_ids(prompt)))
end

do
  local M = fresh()
  repo.rows = { items = {
    { branch = "main", worktree = { path = MAIN, main = true } },
    { branch = "feat", worktree = { path = FEAT } },
  } }
  fake:answer("feat")
  local result = M.open(key_ctx())
  t.check("reads worktrunk's schema 2 list output",
    t.same_list(item_ids(question()), { "main", "feat", "stale" }) and result.path == FEAT,
    t.show(item_ids(question())))
end

do
  local M = fresh()
  fake.env.SHELL = "/opt/homebrew/bin/fish"
  M.open(key_ctx())
  t.check("fish runs commands with $argv",
    t.same_list(ran("wt list --format=json").shell,
      { "/opt/homebrew/bin/fish", "-l", "-c", "exec $argv", "wt", "list", "--format=json" }))
end

do
  local M = fresh()
  repo.top, repo.git_dir = nil, false
  local err = t.error_of(M.open, key_ctx())
  t.check("outside a repository is an error, asked nothing",
    err and err:find("not a git repository: " .. FEAT, 1, true) and #questions() == 0, err)
end

do
  local M = fresh()
  repo.wt_list_fails = true
  local err = t.error_of(M.open, key_ctx())
  t.check("a failing wt list is an error with its first line", err and err:find("wt list failed: wt: boom", 1, true), err)
end

do
  local M = fresh()
  fake.cwd = nil
  local err = t.error_of(M.open, key_ctx())
  t.check("an unknown working directory is an error", err and err:find("working directory", 1, true), err)
end

--------------------------------------------------------------------------------
t.section("what a pick does")
--------------------------------------------------------------------------------

do
  local M = fresh()
  local ctx = key_ctx()
  fake:answer("main")
  local result = M.open(ctx)
  local switch = ran("wt switch main --no-cd --format=json")
  t.check("an existing worktree runs wt switch here", switch ~= nil and switch.cwd == FEAT)
  t.check("and opens its session in the app, with no float",
    result.created and result.path == MAIN and t.same_list(fake:selected(), { result.session_id })
      and #floats() == 0 and #fake:calls_to("client.perform") == 0, t.show(fake:selected()))
  t.check("remembering the session it was picked from, adopted for the worktree it was in",
    t.same_list(fake:registry_lines(), {
      MAIN .. "\t" .. result.session_id .. "\t" .. ctx.session_id,
      FEAT .. "\t" .. ctx.session_id .. "\t\tadopted",
    }), t.show(fake:registry_lines()))
end

do
  local M = fresh()
  local ctx = key_ctx()
  fake:answer("feat")
  local result = M.open(ctx)
  t.check("the worktree it is picked from shows the session it is picked from",
    not result.created and result.session_id == ctx.session_id and #fake:calls_to("session.create") == 0)
end

do
  local M = fresh{ label = function(_, worktree) return worktree.branch .. "@" .. worktree.main end }
  fake:answer("main")
  local result = M.open(key_ctx())
  t.check("passes the branch and main checkout to the label option",
    fake:session(result.session_id).label == "main@" .. MAIN, t.show(fake:labels()))
end

do
  local M = fresh()
  fake:answer({ text = "  feat " })
  local result = M.open(key_ctx())
  t.check("typed text naming a worktree's branch switches to it too", result.path == FEAT and #floats() == 0)
end

do
  local M = fresh()
  repo.switch_fails = true
  fake:answer("feat")
  M.open(key_ctx())
  t.check("a failing wt switch goes on in the float, where its error shows",
    t.same_list(float_args(), { "switch", "feat", "--base", "@" }) and #fake:selected() == 0
      and fake:warnings()[1]:find("needs approval", 1, true), t.show(float_args() or {}))
end

do
  local M = fresh{ slugify = true, remotes = true }
  fake:answer("stale")
  M.open(key_ctx())
  local args, layer = float_args()
  t.check("a branch without a worktree is created in the float, without --remotes",
    t.same_list(args, { "switch", "stale", "--base", "@", "--slugify" })
      and layer.layout.block.options.cwd == FEAT and layer.layout.block.label == "worktree"
      and #fake:calls_to("block.process") == 1, t.show(args))
end

do
  local M = fresh{ base = false }
  fake:answer({ text = "Fix Login Bug" })
  M.open(key_ctx())
  t.check("typed text is created in the float as typed, for the script to slug",
    t.same_list(float_args(), { "switch", "Fix Login Bug" }), t.show(float_args() or {}))
end

do
  local M = fresh()
  fake:answer({ text = "^" })
  M.open(key_ctx())
  t.check("a worktrunk shortcut goes to the float", t.same_list(float_args(), { "switch", "^", "--base", "@" }))
end

do
  local M = fresh()
  local cancelled = M.open(key_ctx())
  fake:answer({ text = "   " })
  local blank = M.open(key_ctx())
  t.check("cancelling, or typing nothing, does nothing",
    cancelled.cancelled and blank.cancelled and #floats() == 0 and #fake:selected() == 0
      and ran("wt switch feat --no-cd --format=json") == nil)
end

--------------------------------------------------------------------------------
t.section("the remove picker")
--------------------------------------------------------------------------------

do
  local M = fresh()
  fake:answer("feat")
  M.open_remove(key_ctx())
  local prompt = question()
  local args, layer = float_args()
  t.check("lists worktrees but never the main checkout",
    t.same_list(item_ids(prompt), { "feat" }) and prompt.items[1].subtitle == "~/src/app.feat"
      and prompt.title == "Remove worktree" and not prompt.allow_other, t.show(item_ids(prompt)))
  t.check("removes the pick in the float, without fzf",
    t.same_list(args, { "remove", "feat" }) and layer.layout.block.label == "worktree remove", t.show(args))
end

do
  local M = fresh()
  repo.rows = { wt_list_rows()[1] }
  M.open_remove(key_ctx())
  t.check("with only the main checkout, says there is nothing to remove",
    #question().items == 0 and question().placeholder:find("Nothing to remove", 1, true) and #floats() == 0)
end

do
  local M = fresh()
  local result = M.open_remove(key_ctx())
  t.check("cancelling removes nothing", result.cancelled and #floats() == 0)
end

do
  local M = fresh()
  fake:answer(nil, "unsupported")
  M.open_remove(key_ctx())
  t.check("unsupported falls back to the fzf remove float", t.same_list(float_args(), { "remove" }))
end

do
  local M = fresh()
  repo.top, repo.git_dir = nil, false
  local err = t.error_of(M.open_remove, key_ctx())
  t.check("outside a repository is an error", err and err:find("not a git repository", 1, true), err)
end

do
  local M = fresh()
  repo.top = nil   -- a bare repository: no checkout, but a git directory
  fake:answer("feat")
  M.open_remove(key_ctx())
  t.check("works in a bare repository", t.same_list(float_args(), { "remove", "feat" }))
end

t.done(function() fake:cleanup() end)
