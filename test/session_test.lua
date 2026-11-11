-- Checks how worktree sessions are created, found, remembered and closed,
-- against the fake rex in fake_rex.lua. Needs only Lua 5.1 (or LuaJIT):
--
--   luajit test/session_test.lua

local here = (debug.getinfo(1, "S").source or ""):gsub("^@", ""):match("^(.*)/[^/]*$") or "."
package.path = here .. "/?.lua;" .. package.path

local t = require("helper")
local fake = require("fake_rex").install()

local MAIN, FIX, FEAT = "/src/app", "/src/app.fix", "/src/app.feat"

-- A clean fake with the repo's directories, and a fresh plugin.
local function fresh(opts)
  fake:reset()
  fake.dirs = { [MAIN] = true, [FIX] = true, [FEAT] = true }
  return t.load_plugin(opts)
end

-- The context of an action run from session_id: from a key in the app by
-- default, or origin "cli" as when the picker float runs `rex do`.
local function from(session_id, origin)
  return { origin = origin or "key", session_id = session_id }
end

--------------------------------------------------------------------------------
t.section("opening a worktree's session")
--------------------------------------------------------------------------------

do
  local M = fresh()
  local home = fake:add_session("home")
  local first = M.go(from(home), FIX .. "/")
  t.check("creates a session labelled after the directory",
    first.created and fake:session(first.session_id).label == "app.fix", t.show(fake:labels()))
  t.check("normalizes the path", first.path == FIX, first.path)
  t.check("shows the new session in the app", t.same_list(fake:selected(), { first.session_id }))

  local again = M.go(from(home), FIX)
  t.check("reuses the session on the next pick",
    again.session_id == first.session_id and not again.created and #fake:calls_to("session.create") == 1)

  fake:session(first.session_id).label = "renamed by hand"
  t.check("finds it after it was renamed", M.go(from(home), FIX).session_id == first.session_id)

  fake:remove_session(first.session_id)
  local recreated = M.go(from(home), FIX)
  t.check("creates it again after it was destroyed elsewhere",
    recreated.created and recreated.session_id ~= first.session_id)
end

do
  local M = fresh()
  local err = t.error_of(M.go, from(nil), "/src/missing")
  t.check("refuses a path that isn't a directory",
    err and err:find("not a directory: /src/missing", 1, true) and #fake:calls_to("session.create") == 0, err)
end

do
  local M = fresh()
  local lookalike = fake:add_session("app.fix")
  local opened = M.go(from(nil), FIX)
  t.check("never adopts a session it didn't create, even with the same label",
    opened.created and opened.session_id ~= lookalike)
end

do
  local M = fresh{ label = function() return "same" end }
  local main = M.go(from(nil), MAIN).session_id
  local fix = M.go(from(nil), FIX).session_id
  local feat = M.go(from(nil), FEAT).session_id
  t.check("gives each worktree its own session when labels collide",
    #fake.sessions == 3 and main ~= fix and fix ~= feat and main ~= feat)
end

do
  local M = fresh{ label = function(path) return "app 󰙅 " .. path:match("([^/]+)$") end }
  M.go(from(nil), FIX)
  t.check("uses the label option for a new session", fake.sessions[1].label == "app 󰙅 app.fix", fake.sessions[1].label)
end

for name, label in pairs{
  ["a nil"] = function() return nil end,
  ["an empty"] = function() return "  " end,
  ["a failing"] = function() error("boom") end,
  ["a non-string"] = function() return 42 end,
} do
  local M = fresh{ label = label }
  M.go(from(nil), FIX)
  M.go(from(nil), FIX)
  t.check(name .. " label falls back to the directory name, once",
    #fake.sessions == 1 and fake.sessions[1].label == "app.fix", t.show(fake:labels()))
end

do
  local M = fresh{ label = function() error("boom") end }
  M.go(from(nil), FIX)
  t.check("warns when the label function fails", #fake:warnings() == 1, t.show(fake:warnings()))
end

do
  local seen
  local M = fresh{ layout = function(label, path) seen = { label, path }; return { block = { flavor = "x" } } end }
  M.go(from(nil), FIX)
  t.check("builds a new session's layout with the layout option",
    seen and seen[1] == "app.fix" and seen[2] == FIX
      and fake:calls_to("session.create")[1].args.initial_windows[1].layout.block.flavor == "x")
end

--------------------------------------------------------------------------------
t.section("remembering where a worktree was opened from")
--------------------------------------------------------------------------------

do
  local M = fresh()
  local home = fake:add_session("home")
  local fix = M.go(from(home), FIX).session_id
  t.check("records the session it was opened from as its origin",
    t.same_list(fake:registry_lines(), { FIX .. "\t" .. fix .. "\t" .. home }), t.show(fake:registry_lines()))

  local other = fake:add_session("other")
  M.go(from(other), FIX)
  t.check("keeps the first origin when opened again from elsewhere",
    t.same_list(fake:registry_lines(), { FIX .. "\t" .. fix .. "\t" .. home }), t.show(fake:registry_lines()))

  fake:remove_session(home)
  M.go(from(other), FIX)
  t.check("replaces an origin that no longer exists",
    t.same_list(fake:registry_lines(), { FIX .. "\t" .. fix .. "\t" .. other }), t.show(fake:registry_lines()))

  fake:remove_session(other)
  M.go(from(fix), FIX)
  t.check("never records a session as its own origin",
    t.same_list(fake:registry_lines(), { FIX .. "\t" .. fix .. "\t" .. other }), t.show(fake:registry_lines()))
end

do
  local M = fresh()
  local fix = M.go(from(nil), FIX).session_id
  t.check("records no origin when the request came from no session",
    t.same_list(fake:registry_lines(), { FIX .. "\t" .. fix }), t.show(fake:registry_lines()))
end

--------------------------------------------------------------------------------
t.section("closing a removed worktree's session")
--------------------------------------------------------------------------------

do
  local M = fresh()
  local home = fake:add_session("home")
  local fix = M.go(from(home), FIX).session_id
  fake.calls = {}
  local result = M.close(from(home), FIX, MAIN)
  t.check("closes it", result.closed and result.session_id == fix and fake:session(fix) == nil)
  t.check("leaves the app alone when it is viewing another session",
    #fake:selected() == 0 and result.moved_to == nil)
  t.check("forgets the worktree", #fake:registry_lines() == 0, t.show(fake:registry_lines()))
  t.check("a second close finds nothing to do", not M.close(from(home), FIX, MAIN).closed)
end

do
  local M = fresh()
  local home = fake:add_session("home")
  local fix = M.go(from(home), FIX).session_id
  fake.calls = {}
  local result = M.close(from(fix), FIX, MAIN)
  t.check("takes the app back to the origin when it is viewing the session",
    result.moved_to == home and t.same_list(fake:selected(), { home }), t.show(fake:selected()))
  local select_at = fake:first("client.queue")
  local destroy_at = fake:first("session.destroy")
  t.check("moves the app before destroying the session",
    select_at and destroy_at and select_at < destroy_at)
  t.check("closes it", fake:session(fix) == nil)
end

do
  local M = fresh()
  local home = fake:add_session("home")
  local main = M.go(from(home), MAIN).session_id
  local fix = M.go(from(home), FIX).session_id
  fake:remove_session(home)
  fake.calls = {}
  local result = M.close(from(fix), FIX, MAIN)
  t.check("falls back to the main checkout's session when the origin is gone",
    result.moved_to == main and t.same_list(fake:selected(), { main }), t.show(fake:selected()))
end

do
  local M = fresh()
  local home = fake:add_session("home")
  local fix = M.go(from(home), FIX).session_id
  fake:remove_session(home)
  local main = fake:add_session("app")
  fake.calls = {}
  local result = M.close(from(fix), FIX, MAIN)
  t.check("then to a session labelled the way the plugin labels the main checkout",
    result.moved_to == main and t.same_list(fake:selected(), { main }), t.show(fake:selected()))
  t.check("without tracking or closing that session", fake:session(main) ~= nil and #fake:registry_lines() == 0)
end

do
  -- The reported bug: with no session for the main checkout, closing the
  -- worktree's session created one just to land in it.
  local M = fresh()
  local home = fake:add_session("home")
  local fix = M.go(from(home), FIX).session_id
  fake:remove_session(home)
  fake:add_session("my own name for the repo")
  fake.calls = {}
  local result = M.close(from(fix), FIX, MAIN)
  t.check("never creates a session when there is nowhere to go back to",
    result.closed and #fake:calls_to("session.create") == 0, t.show(fake:labels()))
  t.check("still closes the session and leaves the app where Rex puts it",
    fake:session(fix) == nil and result.moved_to == nil and #fake:selected() == 0)
end

do
  local M = fresh()
  local home = fake:add_session("home")
  local fix = M.go(from(home), FIX).session_id
  fake.queue_fails = "no client"
  local result = M.close(from(fix), FIX, MAIN)
  t.check("still closes the session when the app won't switch",
    result.closed and result.moved_to == nil and fake:session(fix) == nil)
  t.check("and warns about the switch", #fake:warnings() == 1, t.show(fake:warnings()))
end

do
  -- The picker and worktrunk's post-remove hook both close the worktree; the
  -- other one destroys the session between this one's lookup and destroy.
  local M = fresh()
  local fix = M.go(from(nil), FIX).session_id
  fake.intercept["session.attach"] = function(args)
    fake:remove_session(args.session_id)
    return true, nil, "session_not_found"
  end
  local err = t.error_of(M.close, from(nil), FIX, MAIN)
  t.check("treats a session destroyed meanwhile as closed", err == nil and fake:session(fix) == nil, err)
end

do
  local M = fresh()
  local fix = M.go(from(nil), FIX).session_id
  fake.intercept["session.destroy"] = function() return true, nil, "permission denied" end
  local err = t.error_of(M.close, from(nil), FIX, MAIN)
  t.check("reports a session that could not be destroyed",
    err and err:find("permission denied", 1, true) and fake:session(fix) ~= nil, err)
end

do
  local M = fresh{ label = function(path)
    if not fake.dirs[path] then error("gone") end
    return "app 󰙅 " .. path:match("([^/]+)$")
  end }
  local fix = M.go(from(nil), FIX).session_id
  fake.dirs[FIX] = nil
  t.check("closes it after the directory is gone, without a label",
    M.close(from(nil), FIX, MAIN).closed and fake:session(fix) == nil)
end

do
  local M = fresh()
  local main = M.go(from(nil), MAIN).session_id
  local fix = M.go(from(nil), FIX).session_id
  local feat = M.go(from(nil), FEAT).session_id
  M.close(from(nil), FIX, MAIN)
  t.check("spares the other worktrees' sessions",
    fake:session(main) and fake:session(feat) and fake:session(fix) == nil
      and M.go(from(nil), FEAT).session_id == feat and M.go(from(nil), MAIN).session_id == main)
end

do
  local M = fresh()
  local lookalike = fake:add_session("app.fix")
  t.check("never closes a session it didn't open, even with the same label",
    not M.close(from(nil), FIX, MAIN).closed and fake:session(lookalike) ~= nil)
  t.check("closes nothing for an unknown path", not M.close(from(nil), "/src/other", MAIN).closed)
end

--------------------------------------------------------------------------------
t.section("asking the app to show a session")
--------------------------------------------------------------------------------

for _, origin in ipairs{ "key", "palette" } do
  local M = fresh()
  local opened = M.go(from(nil, origin), FIX)
  local queued = fake:calls_to("client.queue")
  t.check("queues session.select for the app that ran a " .. origin .. " action",
    #queued == 1 and queued[1].args.args.session_id == opened.session_id and #fake:calls_to("client.perform") == 0)
end

do
  local M = fresh()
  local home = fake:add_session("home")
  fake:add_app({})
  local viewer = fake:add_app({ home })
  M.go(from(home, "cli"), FIX)
  local performed = fake:calls_to("client.perform")
  t.check("from the CLI, asks the app viewing the session it came from",
    #performed == 1 and performed[1].args.client_id == viewer.client_id)
end

do
  local M = fresh()
  local refusing = fake:add_app({}, "remote control is off")
  local willing = fake:add_app({})
  M.go(from(fake:add_session("home"), "cli"), FIX)
  local performed = fake:calls_to("client.perform")
  t.check("from the CLI, falls back to any app that will",
    #performed == 2 and performed[1].args.client_id == refusing.client_id
      and performed[2].args.client_id == willing.client_id)
end

do
  local M = fresh()
  fake:add_app({}, "remote control is off")
  local err = t.error_of(M.go, from(nil, "cli"), FIX)
  t.check("says so when no app will, keeping the session",
    err and err:find("would not show it: remote control is off", 1, true) and #fake.sessions == 1, err)
  err = t.error_of(fresh().go, from(nil, "cli"), FIX)
  t.check("says so when no app is connected", err and err:find("no Rex app is connected", 1, true), err)
end

--------------------------------------------------------------------------------
t.section("the registry file")
--------------------------------------------------------------------------------

do
  local M = fresh()
  local legacy = fake:add_session("app.fix")
  fake:write_registry{ FIX .. "\t" .. legacy }
  t.check("reads lines without an origin", M.go(from(nil), FIX).session_id == legacy)
end

do
  local M = fresh()
  local fix = M.go(from(nil), FIX).session_id
  t.check("creates its directory when missing", #fake:registry_lines() == 1)
  local feat = M.go(from(nil), FEAT).session_id
  t.check("keeps one sorted line per worktree",
    t.same_list(fake:registry_lines(), { FEAT .. "\t" .. feat, FIX .. "\t" .. fix }), t.show(fake:registry_lines()))
  fake:remove_session(feat)
  M.go(from(nil), FIX)
  t.check("drops worktrees whose session is gone",
    t.same_list(fake:registry_lines(), { FIX .. "\t" .. fix }), t.show(fake:registry_lines()))
end

t.done(function() fake:cleanup() end)
