-- Checks how worktree sessions are found, reused and closed, against a fake
-- rex. Needs Lua 5.1 only:
--
--   lua test/session_test.lua

local tmp = os.tmpname()
os.remove(tmp)
os.execute("mkdir -p '" .. tmp .. "'")

-- Lua 5.1 has no setenv: point XDG_STATE_HOME at tmp through os.getenv.
local getenv = os.getenv
os.getenv = function(k)
  if k == "XDG_STATE_HOME" then return tmp end
  return getenv(k)
end

local dirs, server, next_id = {}, {}, 0
local function reset()
  server, next_id = {}, 0
  os.remove(tmp .. "/rex-worktrunk/sessions")
end

rex = {
  log = function() end,
  exec = function(argv)
    if argv[1] == "test" then return { ok = dirs[argv[3]] == true } end
    if argv[1] == "mkdir" then os.execute("mkdir -p '" .. argv[3] .. "'") end
    return { ok = true }
  end,
  call = function(method, args)
    if method == "session.list" then
      local list = {}
      for _, s in ipairs(server) do list[#list + 1] = s end
      return { sessions = list }
    elseif method == "session.create" then
      next_id = next_id + 1
      local s = { session_id = "session:" .. next_id, label = args.label }
      server[#server + 1] = s
      return { session_id = s.session_id }
    elseif method == "session.destroy" then
      for i, s in ipairs(server) do
        if s.session_id == args.session_id then table.remove(server, i) end
      end
      return {}
    end
    return {}
  end,
  client = { queue = function() end },
  layout = { block = function(b) return b end },
  action = function() end,
}

local root = debug.getinfo(1, "S").source:match("^@(.*)/test/") or "."
package.path = root .. "/?.lua;" .. package.path
local M = dofile(root .. "/init.lua")
local ctx = { origin = "key", session_id = "session:none" }

local failed = 0
local function check(name, cond)
  if cond then print("ok   " .. name) else print("FAIL " .. name); failed = failed + 1 end
end
local function count() return #server end

-- 1. A label that needs the directory: close still finds the session.
reset()
dirs = { ["/r/app"] = true, ["/r/app.worktrees/fix"] = true }
M.setup{ label = function(path)
  if not dirs[path] then error("gone") end
  return "app 󰙅 " .. path:match("([^/]+)$")
end }
local go = M.go(ctx, "/r/app.worktrees/fix/")
check("created with the custom label", server[1].label == "app 󰙅 fix")
check("reused on the next pick", M.go(ctx, "/r/app.worktrees/fix").session_id == go.session_id and count() == 1)
dirs["/r/app.worktrees/fix"] = nil
check("closed after the directory is gone", M.close(ctx, "/r/app.worktrees/fix", "/r/app").closed and count() == 0)

-- 2. Worktrees sharing a label get their own sessions; closing one spares the rest.
reset()
dirs = { ["/r/app"] = true, ["/r/app.worktrees/a"] = true, ["/r/app.worktrees/b"] = true }
M.options.label = function() return "same" end
local main = M.go(ctx, "/r/app").session_id
local a = M.go(ctx, "/r/app.worktrees/a").session_id
local b = M.go(ctx, "/r/app.worktrees/b").session_id
check("one session each despite one label", count() == 3 and a ~= b and a ~= main)
M.close(ctx, "/r/app.worktrees/a", "/r/app")
check("closing a keeps b and main", count() == 2 and M.go(ctx, "/r/app.worktrees/b").session_id == b
  and M.go(ctx, "/r/app").session_id == main)
check("closing an unknown path closes nothing", not M.close(ctx, "/r/other", "/r/app").closed and count() == 2)
server[#server + 1] = { session_id = "session:manual", label = "app" }
check("a hand-made session with a matching label is never closed",
  not M.close(ctx, "/r/elsewhere/app").closed and count() == 3)

-- A renamed or vanished session: rename is harmless, a destroyed one is recreated.
server[1].label = "renamed by hand"
check("found after a rename", M.go(ctx, "/r/app").session_id == main)
table.remove(server, 1)
check("recreated after it was destroyed elsewhere", M.go(ctx, "/r/app").session_id ~= main)

-- 3. A nil, empty or failing label falls back to the directory name, once.
for name, fn in pairs{
  ["nil"] = function() return nil end,
  empty = function() return "  " end,
  error = function() error("boom") end,
  number = function() return 42 end,
} do
  reset()
  dirs = { ["/r/app.worktrees/x"] = true }
  M.options.label = fn
  M.go(ctx, "/r/app.worktrees/x")
  M.go(ctx, "/r/app.worktrees/x")
  check(name .. " label falls back and reuses", count() == 1 and server[1].label == "x")
end

os.execute("rm -rf '" .. tmp .. "'")
if failed > 0 then os.exit(1) end
