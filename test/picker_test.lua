-- Checks the picker floats and setup against the fake rex in fake_rex.lua:
-- the command each float runs, where it opens, and the actions setup defines.
-- Needs only Lua 5.1 (or LuaJIT):
--
--   luajit test/picker_test.lua

local here = (debug.getinfo(1, "S").source or ""):gsub("^@", ""):match("^(.*)/[^/]*$") or "."
package.path = here .. "/?.lua;" .. package.path

local t = require("helper")
local fake = require("fake_rex").install()

local REPO = "/src/app"
local ctx = { origin = "key", session_id = "session:here", block_id = "block:focused" }

local function fresh(opts)
  fake:reset()
  fake.cwd = REPO
  fake.env.HOME = "/home/me"
  return t.load_plugin(opts)
end

-- The new_layer request of the last picker opened.
local function last_layer()
  local layers = fake:calls_to("session.new_layer")
  return layers[#layers] and layers[#layers].args
end

local function command_of(layer)
  return layer.layout.block.options.command
end

-- The arguments after the script in a picker command.
local function script_args(command)
  local first = command[1] == "/bin/sh" and 6 or 2
  local args = {}
  for i = first, #command do args[#args + 1] = command[i] end
  return args
end

--------------------------------------------------------------------------------
t.section("the switch / create picker")
--------------------------------------------------------------------------------

do
  local M = fresh{ script = "/opt/wt/worktrunk.sh" }
  local result = M.open(ctx)
  local layer = last_layer()
  t.check("opens a float and returns its layer", result.layer_id and layer ~= nil)
  t.check("runs `pick --base @` by default",
    t.same_list(command_of(layer), { "/opt/wt/worktrunk.sh", "pick", "--base", "@" }), t.show(command_of(layer)))
  t.check("starts in the focused terminal's directory",
    layer.layout.block.options.cwd == REPO and fake:calls_to("block.process")[1].args.block_id == "block:focused")
  t.check("is a focused shell labelled worktree",
    layer.focus == true and layer.layout.block.flavor == "com.superlogical.terminal.shell"
      and layer.layout.block.label == "worktree")
  t.check("floats where the bounds option says",
    t.same_list(layer.bounds, { 0.15, 0.1, 0.7, 0.8 }), t.show(layer.bounds))
end

do
  local M = fresh{ script = "/opt/wt/worktrunk.sh", base = "^", remotes = true, slugify = true,
                   bounds = { 0, 0, 1, 1 } }
  M.open(ctx)
  local layer = last_layer()
  t.check("passes base, --remotes and --slugify",
    t.same_list(script_args(command_of(layer)), { "pick", "--base", "^", "--remotes", "--slugify" }),
    t.show(command_of(layer)))
  t.check("uses custom bounds", t.same_list(layer.bounds, { 0, 0, 1, 1 }))
end

do
  local M = fresh{ script = "/opt/wt/worktrunk.sh", base = false }
  M.open(ctx)
  t.check("leaves out --base when base is false",
    t.same_list(script_args(command_of(last_layer())), { "pick" }), t.show(command_of(last_layer())))
end

do
  local M = fresh{ script = "/opt/wt/worktrunk.sh" }
  local first = M.open(ctx).layer_id
  M.open(ctx)
  local closed = fake:calls_to("session.close_layer")
  t.check("replaces a picker that is already open",
    #closed == 1 and closed[1].args.layer_id == first and #fake:calls_to("session.new_layer") == 2)
end

do
  local M = fresh{ script = "/opt/wt/worktrunk.sh" }
  fake.cwd = nil
  local err = t.error_of(M.open, ctx)
  t.check("refuses when the focused terminal's directory is unknown",
    err and err:find("can't tell the working directory", 1, true) and last_layer() == nil, err)
end

--------------------------------------------------------------------------------
t.section("the remove picker")
--------------------------------------------------------------------------------

do
  local M = fresh{ script = "/opt/wt/worktrunk.sh" }
  M.open_remove(ctx)
  local layer = last_layer()
  t.check("runs `remove` in a float labelled worktree remove",
    t.same_list(command_of(layer), { "/opt/wt/worktrunk.sh", "remove" })
      and layer.layout.block.label == "worktree remove", t.show(command_of(layer)))
end

--------------------------------------------------------------------------------
t.section("finding the script")
--------------------------------------------------------------------------------

do
  local M = fresh{ script = "/home/me/.config/rex/rex-worktrunk/worktrunk.sh" }
  M.open_remove(ctx)
  local command = command_of(last_layer())
  t.check("starts a script under HOME from $HOME on the host the float runs on",
    t.same_list(command, { "/bin/sh", "-c", 'script=$HOME/$1; shift; exec "$script" "$@"',
                           "worktrunk.sh", ".config/rex/rex-worktrunk/worktrunk.sh", "remove" }),
    t.show(command))
end

do
  local M = fresh{ script = "~/bin/worktrunk.sh" }
  t.check("expands ~ in the script option", M.options.script == "/home/me/bin/worktrunk.sh", M.options.script)
end

do
  local M = fresh()
  M.open_remove(ctx)
  t.check("defaults to worktrunk.sh beside init.lua",
    M.options.script == t.root .. "/worktrunk.sh" and command_of(last_layer())[1] == t.root .. "/worktrunk.sh",
    M.options.script)
end

--------------------------------------------------------------------------------
t.section("setup")
--------------------------------------------------------------------------------

do
  local M = fresh{ bogus = 1 }
  local names = {}
  for name in pairs(fake.actions) do names[#names + 1] = name end
  table.sort(names)
  t.check("defines the four actions",
    t.same_list(names, { "worktree", "worktree_close", "worktree_go", "worktree_remove" }), t.show(names))
  t.check("warns about an unknown option and ignores it",
    #fake:warnings() == 1 and fake:warnings()[1]:find("bogus", 1, true) and M.options.bogus == nil,
    t.show(fake:warnings()))
  t.check("declares the actions' arguments",
    fake.actions.worktree_go.args.path == "string"
      and fake.actions.worktree_go.args.from == "string?"
      and fake.actions.worktree_go.args.branch == "string?"
      and fake.actions.worktree_go.args.main == "string?"
      and fake.actions.worktree_close.args.path == "string"
      and fake.actions.worktree_close.args.main == "string?")
end

do
  local M = fresh{ label = "a string", remotes = "yes", base = false }
  t.check("warns about an option of the wrong type and keeps the default",
    #fake:warnings() == 2 and M.options.label == nil and M.options.remotes == false and M.options.base == false,
    t.show(fake:warnings()))
end

do
  fresh{ script = "/opt/wt/worktrunk.sh" }
  fake.dirs = { [REPO .. ".fix"] = true }
  local opened = fake.actions.worktree_go.run(ctx, { path = REPO .. ".fix", branch = "fix" })
  local closed = fake.actions.worktree_close.run(ctx, { path = REPO .. ".fix", main = REPO })
  local picker = fake.actions.worktree.run(ctx, {})
  local remover = fake.actions.worktree_remove.run(ctx, {})
  t.check("runs each action through the module",
    opened.created and closed.closed and closed.session_id == opened.session_id
      and picker.layer_id and remover.layer_id)
end

t.done(function() fake:cleanup() end)
