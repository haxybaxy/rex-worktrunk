-- Checks group = "tab": how a repository's session is found or created, and
-- how worktree tabs are opened, found, remembered and closed in it, against
-- the fake rex in fake_rex.lua. Needs only Lua 5.1 (or LuaJIT):
--
--   luajit test/tab_test.lua

local here = (debug.getinfo(1, "S").source or ""):gsub("^@", ""):match("^(.*)/[^/]*$") or "."
package.path = here .. "/?.lua;" .. package.path

local t = require("helper")
local fake = require("fake_rex").install()

local MAIN, FIX, FEAT = "/src/app", "/src/app.fix", "/src/app.feat"

-- A clean fake with the repo's directories, and a fresh plugin that groups by
-- tab unless opts says otherwise.
local function fresh(opts)
  fake:reset()
  fake.dirs = { [MAIN] = true, [FIX] = true, [FEAT] = true }
  opts = opts or {}
  if opts.group == nil then opts.group = "tab" end
  return t.load_plugin(opts)
end

-- The context of an action run from session_id: from a key in the app by
-- default, or origin "cli" as when the picker float runs `rex do`. block_id is
-- the block it was run in, when Rex knows.
local function from(session_id, origin, block_id)
  return { origin = origin or "key", session_id = session_id, block_id = block_id }
end

-- A request as the pickers make it for this repo.
local function request(branch, from_path)
  return { main = MAIN, branch = branch, from = from_path }
end

-- A session someone made by hand, with its one tab and that tab's block.
local function own_session(label)
  local id = fake:add_session(label)
  local tab = fake:window_ids(id)[1]
  return id, tab, fake:window(id, tab).block_id
end

-- A repo whose main checkout is open in the person's own session: a pick made
-- there opened FIX as a tab beside it. Returns the plugin, the session, the
-- main checkout's tab and FIX's.
local function beside_main(opts)
  local M = fresh(opts)
  local home, main_tab, block = own_session("my app")
  local fix = M.go(from(home, "key", block), FIX, request("fix", MAIN))
  return M, home, main_tab, fix.window_id
end

--------------------------------------------------------------------------------
t.section("opening a worktree's tab")
--------------------------------------------------------------------------------

do
  local M = fresh()
  local home = fake:add_session("home")
  local fix = M.go(from(home), FIX .. "/", request("fix/login"))
  t.check("creates a session labelled after the main checkout",
    fix.created and fake:session(fix.session_id).label == "app" and #fake.sessions == 2, t.show(fake:labels()))
  t.check("with the worktree's tab, labelled after its branch",
    t.same_list(fake:window_ids(fix.session_id), { fix.window_id })
      and t.same_list(fake:window_labels(fix.session_id), { "fix/login" }),
    t.show(fake:window_labels(fix.session_id)))
  t.check("normalizes the path", fix.path == FIX, fix.path)
  t.check("shows the tab in the app",
    t.same_list(fake:shown(), { fix.session_id .. "/" .. fix.window_id }), t.show(fake:shown()))

  local feat = M.go(from(home), FEAT, request("feat"))
  t.check("opens the repo's next worktree as a tab in the same session",
    feat.created and feat.session_id == fix.session_id and feat.window_id ~= fix.window_id
      and #fake:calls_to("session.create") == 1
      and t.same_list(fake:window_labels(fix.session_id), { "fix/login", "feat" }),
    t.show(fake:window_labels(fix.session_id)))

  local again = M.go(from(home), FIX, request("fix/login"))
  t.check("reuses the tab on the next pick",
    again.window_id == fix.window_id and again.session_id == fix.session_id and not again.created
      and #fake:calls_to("session.new_window") == 1)

  fake:session(fix.session_id).label = "renamed by hand"
  fake:window(fix.session_id, fix.window_id).label = "also renamed"
  t.check("finds it after the session and the tab were renamed",
    M.go(from(home), FIX, request("fix/login")).window_id == fix.window_id)

  fake:remove_window(fix.session_id, fix.window_id)
  local reopened = M.go(from(home), FIX, request("fix/login"))
  t.check("opens it again in the same session after the tab was closed by hand",
    reopened.created and reopened.session_id == fix.session_id and reopened.window_id ~= fix.window_id
      and #fake:calls_to("session.create") == 1)

  fake:remove_session(fix.session_id)
  local recreated = M.go(from(home), FIX, request("fix/login"))
  t.check("creates the session again after it was destroyed elsewhere",
    recreated.created and recreated.session_id ~= fix.session_id
      and t.same_list(fake:window_ids(recreated.session_id), { recreated.window_id }))
end

do
  local calls = {}
  local M = fresh{ on_created = function(result, worktree) calls[#calls + 1] = { result, worktree } end }
  local home = fake:add_session("home")
  local fix = M.go(from(home), FIX, request("fix/login"))
  t.check("calls on_created for a new worktree tab",
    #calls == 1 and calls[1][1].window_id == fix.window_id and calls[1][1].created == true
      and calls[1][2].path == FIX and calls[1][2].branch == "fix/login" and calls[1][2].main == MAIN)
  M.go(from(home), FIX, request("fix/login"))
  t.check("doesn't call on_created when the tab is reopened", #calls == 1)
end

do
  local M = fresh()
  local lookalike = fake:add_session("app")
  local fix = M.go(from(nil), FIX, request("fix"))
  t.check("never takes a session for the repo's because of its label",
    fix.created and fix.session_id ~= lookalike and #fake:window_ids(lookalike) == 1)
end

do
  local M = fresh()
  local fix = M.go(from(nil), FIX, { main = MAIN })
  t.check("labels the tab after the directory when the branch isn't known",
    t.same_list(fake:window_labels(fix.session_id), { "app.fix" }), t.show(fake:window_labels(fix.session_id)))
end

do
  local M = fresh()
  local fix = M.go(from(nil), FIX)
  local feat = M.go(from(nil), FEAT)
  t.check("groups a worktree under itself when the request doesn't say the main checkout",
    fake:session(fix.session_id).label == "app.fix" and feat.session_id ~= fix.session_id
      and t.same_list(fake:window_labels(fix.session_id), { "app.fix" }), t.show(fake:labels()))
end

do
  local seen
  local M = fresh{ label = function(path, worktree) seen = { path, worktree }; return "wt " .. worktree.branch end }
  local fix = M.go(from(nil), FIX, request("fix"))
  t.check("uses the label option for the tab, not the session",
    seen and seen[1] == FIX and seen[2].main == MAIN and fake:session(fix.session_id).label == "app"
      and t.same_list(fake:window_labels(fix.session_id), { "wt fix" }), t.show(fake:window_labels(fix.session_id)))
end

do
  local M = fresh{ label = function() return ("x"):rep(200) end }
  local fix = M.go(from(nil), FIX, request("fix"))
  t.check("falls back to the branch when Rex refuses the label, with a warning",
    fix.created and #fake.sessions == 1 and t.same_list(fake:window_labels(fix.session_id), { "fix" })
      and #fake:warnings() == 1, t.show(fake:warnings()))
  local feat = M.go(from(nil), FEAT, request(("y"):rep(200)))
  t.check("and to the directory's name when it refuses the branch too",
    t.same_list(fake:window_labels(feat.session_id), { "fix", "app.feat" }) and #fake:warnings() == 3,
    t.show(fake:window_labels(feat.session_id)))
end

do
  local seen
  local M = fresh{ layout = function(label, path, worktree)
    seen = { label, path, worktree }
    return { block = { flavor = label } }
  end }
  M.go(from(nil), FIX, request("fix"))
  M.go(from(nil), FEAT, request("feat"))
  t.check("builds a tab's layout with the layout option",
    seen and seen[1] == "feat" and seen[2] == FEAT and seen[3].branch == "feat"
      and fake:calls_to("session.create")[1].args.initial_windows[1].layout.block.flavor == "fix"
      and fake:calls_to("session.new_window")[1].args.layout.block.flavor == "feat")
end

do
  local M = fresh{ layout = function() error("boom") end }
  local err = t.error_of(M.go, from(nil), FIX, request("fix"))
  t.check("reports a failing layout function without creating anything",
    err and err:find("layout function failed", 1, true) and #fake.sessions == 0, err)
end

do
  local M = fresh()
  local err = t.error_of(M.go, from(nil), "/src/missing", request("x"))
  t.check("refuses a path that isn't a directory",
    err and err:find("not a directory: /src/missing", 1, true) and #fake.sessions == 0, err)
end

--------------------------------------------------------------------------------
t.section("the repository's session")
--------------------------------------------------------------------------------

do
  local M, home, main_tab, fix_tab = beside_main()
  t.check("a pick made from the main checkout opens the tab in that session",
    #fake.sessions == 1 and #fake:calls_to("session.create") == 0
      and t.same_list(fake:window_ids(home), { main_tab, fix_tab })
      and t.same_list(fake:window_labels(home), { "", "fix" }), t.show(fake:window_labels(home)))
  t.check("remembers the tab it came from as the main checkout's, and the session as the repo's",
    t.same_list(fake:registry_lines(), {
      MAIN .. "\t" .. home .. "\t\tadopted\t" .. main_tab,
      MAIN .. "\t" .. home .. "\t\trepo-adopted",
      FIX .. "\t" .. home .. "\t" .. home .. "\t\t" .. fix_tab .. "\t" .. main_tab,
    }), t.show(fake:registry_lines()))

  local back = M.go(from(home), MAIN, request("main", FIX))
  t.check("picking the main checkout goes back to its tab",
    back.session_id == home and back.window_id == main_tab and not back.created
      and fake:shown()[#fake:shown()] == home .. "/" .. main_tab)

  fake:remove_window(home, main_tab)
  local feat = M.go(from(home), FEAT, request("feat", FIX))
  t.check("the session stays the repo's after the main checkout's tab is closed",
    feat.session_id == home and #fake.sessions == 1)
end

do
  local M = fresh()
  local home, first, first_block = own_session("my app")
  local second = fake:add_window(home, "logs")
  M.go(from(home, "key", first_block), FIX, request("fix", MAIN))
  t.check("the tab a pick came from is the one holding its block, not the one the session shows",
    fake:session(home).active ~= first and fake:registry_lines()[1] == MAIN .. "\t" .. home .. "\t\tadopted\t" .. first,
    t.show(fake:registry_lines()))

  local N = fresh()
  home = own_session("my app")
  second = fake:add_window(home, "logs")
  N.go(from(home), FIX, request("fix", MAIN))
  t.check("or the one the session shows when Rex doesn't say the block",
    fake:registry_lines()[1] == MAIN .. "\t" .. home .. "\t\tadopted\t" .. second, t.show(fake:registry_lines()))
end

do
  local M = fresh()
  local scratch, scratch_tab, block = own_session("scratch")
  local feat = M.go(from(scratch, "key", block), FEAT, request("feat", FIX))
  t.check("a pick made from another worktree gives the repo a session of its own",
    feat.created and feat.session_id ~= scratch and fake:session(feat.session_id).label == "app")
  t.check("and remembers the tab it came from as that worktree's",
    M.go(from(feat.session_id), FIX, request("fix")).window_id == scratch_tab and #fake.sessions == 2)
end

do
  local M, home, main_tab, fix_tab = beside_main()
  -- The main checkout's terminal has wandered into a worktree without a tab.
  M.go(from(home, "key", fake:window(home, main_tab).block_id), FEAT, request("feat", "/src/app.other"))
  t.check("a tab belongs to one worktree only",
    #fake:registry_lines() == 4 and M.go(from(home), MAIN, request("main")).window_id == main_tab,
    t.show(fake:registry_lines()))
  t.check("and a worktree keeps the tab it has", M.go(from(home), FIX, request("fix", MAIN)).window_id == fix_tab)
end

do
  local M = fresh()
  local home = fake:add_session("home")
  fake:add_app({})
  local viewer = fake:add_app({ home })
  local fix = M.go(from(home, "cli"), FIX, request("fix"))
  local performed = fake:calls_to("client.perform")
  t.check("from the CLI, asks the app for the session and the tab",
    #performed == 1 and performed[1].args.client_id == viewer.client_id
      and performed[1].args.args.session_id == fix.session_id
      and performed[1].args.args.window_id == fix.window_id)
end

--------------------------------------------------------------------------------
t.section("closing a removed worktree's tab")
--------------------------------------------------------------------------------

do
  local M, home, main_tab, fix_tab = beside_main()
  fake.calls = {}
  local result = M.close(from(home), FIX, MAIN)
  t.check("closes the tab and leaves the session open",
    result.closed and result.window_id == fix_tab and t.same_list(fake:window_ids(home), { main_tab }),
    t.show(fake:window_ids(home)))
  t.check("takes the app back to the tab the worktree was opened from",
    result.moved_to == home and result.moved_to_window == main_tab
      and t.same_list(fake:shown(), { home .. "/" .. main_tab }), t.show(fake:shown()))
  t.check("forgets the worktree and keeps the rest",
    t.same_list(fake:registry_lines(), {
      MAIN .. "\t" .. home .. "\t\tadopted\t" .. main_tab,
      MAIN .. "\t" .. home .. "\t\trepo-adopted",
    }), t.show(fake:registry_lines()))
  t.check("a second close finds nothing to do", not M.close(from(home), FIX, MAIN).closed)
end

do
  local M, home = beside_main()
  fake.calls = {}
  M.close(from(home), FIX, MAIN)
  local select_at, close_at = fake:first("client.queue"), fake:first("session.close_window")
  t.check("moves the app before closing the tab", select_at and close_at and select_at < close_at)
end

do
  local M, home, main_tab, fix_tab = beside_main()
  fake:session(home).active = main_tab
  fake.calls = {}
  local result = M.close(from(home), FIX, MAIN)
  t.check("leaves the app alone when the session shows another tab",
    result.closed and result.moved_to == nil and #fake:shown() == 0 and fake:window(home, fix_tab) == nil)
end

do
  local M, home, _, fix_tab = beside_main()
  local other = fake:add_session("other")
  fake.calls = {}
  local result = M.close(from(other), FIX, MAIN)
  t.check("leaves the app alone when it is viewing another session",
    result.closed and result.moved_to == nil and #fake:shown() == 0 and fake:window(home, fix_tab) == nil)
end

do
  local M, home, main_tab, fix_tab = beside_main()
  local feat = M.go(from(home, "key", fake:window(home, fix_tab).block_id), FEAT, request("feat", FIX))
  fake:remove_window(home, fix_tab)
  fake.calls = {}
  local result = M.close(from(home), FEAT, MAIN)
  t.check("falls back to the main checkout's tab when the origin tab is gone",
    result.closed and result.window_id == feat.window_id and result.moved_to_window == main_tab
      and t.same_list(fake:shown(), { home .. "/" .. main_tab }), t.show(fake:shown()))
end

do
  local M = fresh()
  local fix = M.go(from(nil), FIX, request("fix"))
  local feat = M.go(from(nil), FEAT, request("feat"))
  fake:session(fix.session_id).active = fix.window_id
  fake.calls = {}
  local result = M.close(from(fix.session_id), FIX, MAIN)
  t.check("with nowhere to go back to, closes the tab and leaves the app where Rex puts it",
    result.closed and result.moved_to == nil and #fake:shown() == 0
      and t.same_list(fake:window_ids(fix.session_id), { feat.window_id })
      and #fake:calls_to("session.create") == 0)
end

do
  local M = fresh()
  local home = fake:add_session("home")
  local fix = M.go(from(home), FIX, request("fix"))
  local result = M.close(from(home), FIX, MAIN)
  t.check("closes a session the plugin created once its last tab is closed",
    result.closed and fake:session(fix.session_id) == nil and fake:session(home) ~= nil)
  t.check("and forgets the repo's session", #fake:registry_lines() == 0, t.show(fake:registry_lines()))
end

do
  local M, home, main_tab = beside_main()
  fake:remove_window(home, main_tab)
  local result = M.close(from(nil), FIX, MAIN)
  t.check("never closes a session it didn't create, even when no tab is left",
    result.closed and fake:session(home) ~= nil and #fake:window_ids(home) == 0)
end

do
  local M, home, main_tab = beside_main()
  local result = M.close(from(home), MAIN, MAIN)
  t.check("forgets an adopted tab without closing it",
    not result.closed and fake:window(home, main_tab) ~= nil and #fake:calls_to("session.close_window") == 0)
end

do
  local M, home, _, fix_tab = beside_main()
  fake:remove_window(home, fix_tab)
  t.check("finds nothing to close when the tab was closed by hand",
    not M.close(from(home), FIX, MAIN).closed and #fake:calls_to("session.close_window") == 0)
  t.check("and forgets the worktree", #fake:registry_lines() == 2, t.show(fake:registry_lines()))
end

do
  -- The picker and worktrunk's post-remove hook both close the worktree; the
  -- other one closes the tab between this one's lookup and close.
  local M, home, _, fix_tab = beside_main()
  fake.intercept["session.close_window"] = function(args)
    fake:remove_window(args.session_id, args.window_id)
    return true, nil, "not_found"
  end
  local err = t.error_of(M.close, from(nil), FIX, MAIN)
  t.check("treats a tab closed meanwhile as closed", err == nil and fake:window(home, fix_tab) == nil, err)
end

do
  local M, home, _, fix_tab = beside_main()
  fake.intercept["session.close_window"] = function() return true, nil, "permission denied" end
  local err = t.error_of(M.close, from(nil), FIX, MAIN)
  t.check("reports a tab that could not be closed",
    err and err:find("permission denied", 1, true) and fake:window(home, fix_tab) ~= nil, err)
  t.check("and still remembers it, so closing can be tried again", #fake:registry_lines() == 3)
  fake.intercept = {}
  t.check("which then works", M.close(from(nil), FIX, MAIN).closed and fake:window(home, fix_tab) == nil)
end

do
  local M, home, _, fix_tab = beside_main()
  fake.queue_fails = "no client"
  local result = M.close(from(home), FIX, MAIN)
  t.check("still closes the tab when the app won't switch",
    result.closed and result.moved_to == nil and fake:window(home, fix_tab) == nil)
  t.check("and warns about the switch", #fake:warnings() == 1, t.show(fake:warnings()))
end

--------------------------------------------------------------------------------
t.section("changing the group option")
--------------------------------------------------------------------------------

do
  local M = fresh()
  local legacy = fake:add_session("app.fix")
  fake:write_registry{ FIX .. "\t" .. legacy }
  local fix = M.go(from(nil), FIX, request("fix"))
  t.check("a worktree that has a session keeps it",
    fix.session_id == legacy and fix.window_id == nil and not fix.created
      and t.same_list(fake:shown(), { legacy }), t.show(fake:shown()))
  t.check("which is closed as a session", M.close(from(nil), FIX, MAIN).closed and fake:session(legacy) == nil)
end

do
  local M = fresh()
  local fix = M.go(from(nil), FIX, request("fix"))
  local S = t.load_plugin{ group = "session" }
  local again = S.go(from(nil), FIX, request("fix"))
  t.check("a worktree that has a tab keeps it",
    again.session_id == fix.session_id and again.window_id == fix.window_id and not again.created)
  local feat = S.go(from(nil), FEAT, request("feat"))
  t.check("while a new worktree gets a session of its own",
    feat.created and feat.window_id == nil and feat.session_id ~= fix.session_id
      and fake:session(feat.session_id).label == "app.feat")
  t.check("and the tab is closed as a tab",
    S.close(from(nil), FIX, MAIN).window_id == fix.window_id and fake:session(feat.session_id) ~= nil)
end

do
  local S = fresh{ group = "session" }
  local main = S.go(from(nil), MAIN, request("main")).session_id
  local M = t.load_plugin{ group = "tab" }
  local fix = M.go(from(nil), FIX, request("fix"))
  t.check("the main checkout's own session becomes the repo's",
    fix.session_id == main and fix.window_id ~= nil and #fake.sessions == 1)
  local result = M.close(from(nil), MAIN, MAIN)
  t.check("and is then not destroyed while other worktrees have tabs in it",
    not result.closed and fake:session(main) ~= nil and fake:window(main, fix.window_id) ~= nil
      and M.go(from(nil), FIX, request("fix")).window_id == fix.window_id)
end

t.done(function() fake:cleanup() end)
