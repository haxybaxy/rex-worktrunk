-- An in-memory stand-in for the `rex` global that init.lua talks to: sessions,
-- apps, the focused terminal and the floating layers, with every call recorded
-- in order so tests can check what the plugin asked Rex to do.
--
--   local fake = require("fake_rex").install()
--   fake:reset()
--   local id = fake:add_session("app")
--
-- For the native picker: rex.ui.pick answers with what fake:answer queued,
-- commands run through the login shell are recorded as "cmd" and answered by
-- fake.run(argv, opts), and rex.json.decode reads the text fake:json made.
--
-- The plugin's registry file is real; it lives in a temporary XDG_STATE_HOME
-- that fake.env points os.getenv at, along with any other variable a test sets.

local Fake = {}
Fake.__index = Fake

local function shell_quote(s)
  return "'" .. s:gsub("'", "'\\''") .. "'"
end

local function temp_dir()
  math.randomseed(os.time())
  local base = (os.getenv("TMPDIR") or "/tmp"):gsub("/+$", "")
  local dir = base .. "/rex-worktrunk-test." .. os.time() .. "." .. math.random(1, 1e9)
  os.execute("mkdir -p " .. shell_quote(dir))
  return dir
end

-- Put the fake in place of the rex global and of os.getenv's view of the
-- environment. Returns the fake.
function Fake.install()
  local fake = setmetatable({ tmp = temp_dir() }, Fake)
  fake.env = { XDG_STATE_HOME = fake.tmp .. "/state" }

  local getenv = os.getenv
  os.getenv = function(name)
    if fake.env[name] ~= nil then return fake.env[name] or nil end
    return getenv(name)
  end

  rex = fake:api()
  fake:reset()
  return fake
end

-- Forget every session, app, call and file from the previous test.
function Fake:reset()
  self.dirs = {}         -- [path] = true for each directory that exists
  self.sessions = {}     -- { session_id, label, windows, active } in creation order;
                         -- windows holds { window_id, label, layout, block_id } per tab
  self.attached = {}     -- [session_id] = true once the plugin attached to it
  self.apps = {}         -- { client_id, attached = { [session_id] = true }, refuses = message }
  self.cwd = nil         -- the focused terminal's working directory; nil if unknown
  self.calls = {}        -- every call, in order: { name = ..., args = ... }
  self.logs = {}         -- { level, message }
  self.actions = {}      -- [name] = the table given to rex.action
  self.queue_fails = nil -- message rex.client.queue raises, as with no client
  self.intercept = {}    -- [method] = function(args) -> handled, result, err
  self.answers = {}      -- what rex.ui.pick answers, in order: { value, why, detail }
  self.run = nil         -- function(argv, opts) -> rex.exec's result, for login-shell commands
  self.json_values = {}  -- [text] = the value rex.json.decode returns for it
  self.next_id = 0
  rex.ui = self.ui       -- a test may set it to nil, as in a Rex without prompts
  os.execute("rm -rf " .. shell_quote(self.env.XDG_STATE_HOME))
end

-- Queue rex.ui.pick's next answer: an item's id, { text = ... }, or nil with
-- a reason such as "cancelled". Unqueued questions are cancelled.
function Fake:answer(value, why, detail)
  self.answers[#self.answers + 1] = { value = value, why = why, detail = detail }
end

-- Text that rex.json.decode turns into value.
function Fake:json(value)
  local text = "json:" .. self:new_id("value")
  self.json_values[text] = value
  return text
end

-- The argv of each login-shell command, in order.
function Fake:commands()
  local found = {}
  for _, call in ipairs(self.calls) do
    if call.name == "cmd" then found[#found + 1] = call.args end
  end
  return found
end

-- The argv a login-shell command runs, or nil if argv isn't one: the
-- plugin's `$SHELL -lc 'exec "$@"' $0 ...` or fish's `fish -l -c 'exec $argv' ...`.
local function login_inner(argv)
  if argv[3] ~= 'exec "$@"' and argv[4] ~= "exec $argv" then return nil end
  local inner = {}
  for i = 5, #argv do inner[#inner + 1] = argv[i] end
  return inner
end

function Fake:cleanup()
  os.execute("rm -rf " .. shell_quote(self.tmp))
end

function Fake:new_id(kind)
  self.next_id = self.next_id + 1
  return kind .. ":" .. self.next_id
end

-- Add a session as if someone made it outside the plugin, with one tab.
-- Returns its ID.
function Fake:add_session(label)
  local id = self:new_id("session")
  self.sessions[#self.sessions + 1] = { session_id = id, label = label, windows = {} }
  self:add_window(id)
  return id
end

-- Add a tab holding one block to a session, and make it the tab the session
-- shows. Returns its window ID and its block's ID.
function Fake:add_window(session_id, label, layout)
  local session = self:session(session_id)
  local window = { window_id = self:new_id("window"), label = label, layout = layout,
                   block_id = self:new_id("block") }
  session.windows[#session.windows + 1] = window
  session.active = window.window_id
  return window.window_id, window.block_id
end

-- A session's tab and its place among the session's tabs, or nil.
function Fake:window(session_id, window_id)
  local session = self:session(session_id)
  for i, window in ipairs(session and session.windows or {}) do
    if window.window_id == window_id then return window, i end
  end
  return nil
end

-- Close a tab as if someone did it by hand.
function Fake:remove_window(session_id, window_id)
  local session = self:session(session_id)
  local _, i = self:window(session_id, window_id)
  if not i then return false end
  table.remove(session.windows, i)
  if session.active == window_id then
    local next = session.windows[i] or session.windows[i - 1]
    session.active = next and next.window_id or nil
  end
  return true
end

-- The labels of a session's tabs, in order.
function Fake:window_labels(session_id)
  local labels = {}
  for _, window in ipairs(self:session(session_id).windows) do labels[#labels + 1] = window.label or "" end
  return labels
end

-- A session's tabs, in order.
function Fake:window_ids(session_id)
  local ids = {}
  for _, window in ipairs(self:session(session_id).windows) do ids[#ids + 1] = window.window_id end
  return ids
end

function Fake:session(id)
  for i, s in ipairs(self.sessions) do
    if s.session_id == id then return s, i end
  end
  return nil
end

function Fake:remove_session(id)
  local _, i = self:session(id)
  if i then table.remove(self.sessions, i) end
end

function Fake:labels()
  local labels = {}
  for _, s in ipairs(self.sessions) do labels[#labels + 1] = s.label end
  return labels
end

-- Add a connected app, attached to the given sessions. refuses, when set, is
-- the error it answers client.perform with, as with Remote Control off.
function Fake:add_app(attached, refuses)
  local app = { client_id = self:new_id("client"), attached = {}, refuses = refuses }
  for _, id in ipairs(attached or {}) do app.attached[id] = true end
  self.apps[#self.apps + 1] = app
  return app
end

function Fake:record(name, args)
  self.calls[#self.calls + 1] = { name = name, args = args }
end

-- The recorded calls with this name, in order.
function Fake:calls_to(name)
  local found = {}
  for _, call in ipairs(self.calls) do
    if call.name == name then found[#found + 1] = call end
  end
  return found
end

-- The position of the first recorded call with this name, or nil.
function Fake:first(name)
  for i, call in ipairs(self.calls) do
    if call.name == name then return i end
  end
  return nil
end

-- The sessions the app was asked to show, in order, however it was asked.
function Fake:selected()
  local ids = {}
  for _, call in ipairs(self.calls) do
    if call.name == "client.queue" and call.args.action == "session.select" then
      ids[#ids + 1] = call.args.args.session_id
    elseif call.name == "client.perform" and call.args.action == "session.select" then
      ids[#ids + 1] = call.args.args.session_id
    end
  end
  return ids
end

-- The places the app was asked to show, in order: "session" or "session/tab".
function Fake:shown()
  local places = {}
  for _, call in ipairs(self.calls) do
    if (call.name == "client.queue" or call.name == "client.perform") and call.args.action == "session.select" then
      local args = call.args.args
      places[#places + 1] = args.session_id .. (args.window_id and ("/" .. args.window_id) or "")
    end
  end
  return places
end

function Fake:warnings()
  local found = {}
  for _, log in ipairs(self.logs) do
    if log.level == "warn" then found[#found + 1] = log.message end
  end
  return found
end

-- The registry file's lines, or {} when there is none.
function Fake:registry_lines()
  local lines = {}
  local f = io.open(self.env.XDG_STATE_HOME .. "/rex-worktrunk/sessions", "r")
  if not f then return lines end
  for line in f:lines() do lines[#lines + 1] = line end
  f:close()
  return lines
end

function Fake:write_registry(lines)
  local dir = self.env.XDG_STATE_HOME .. "/rex-worktrunk"
  os.execute("mkdir -p " .. shell_quote(dir))
  local f = assert(io.open(dir .. "/sessions", "w"))
  for _, line in ipairs(lines) do f:write(line, "\n") end
  f:close()
end

-- Server methods, called as rex.call(method, args).
local methods = {}

function methods.session_list(fake)
  local list = {}
  for _, s in ipairs(fake.sessions) do list[#list + 1] = { session_id = s.session_id, label = s.label } end
  return { sessions = list }
end

-- As the server does: a label has at most 128 characters.
local function label_refused(label)
  if #(label or "") > 128 then return "label is too long" end
  return nil
end

function methods.session_create(fake, args)
  local refused = label_refused(args.label)
  for _, window in ipairs(args.initial_windows or {}) do
    refused = refused or label_refused(window.window_label)
  end
  if refused then return nil, refused end
  local id = fake:new_id("session")
  fake.sessions[#fake.sessions + 1] = { session_id = id, label = args.label, windows = {} }
  local created = {}
  for _, window in ipairs(args.initial_windows or {}) do
    local window_id, block_id = fake:add_window(id, window.window_label, window.layout)
    created[#created + 1] = { window_id = window_id, block_ids = { block_id }, revision = #created + 1 }
  end
  return { session_id = id, initial_windows = created }
end

-- Attaching answers with the session's view, as session.view does.
function methods.session_attach(fake, args)
  local session = fake:session(args.session_id)
  if not session then return nil, "session_not_found" end
  fake.attached[args.session_id] = true
  local windows = {}
  for _, window in ipairs(session.windows) do
    windows[#windows + 1] = {
      window_id        = window.window_id,
      label            = window.label or "Window",
      focused_block_id = window.block_id,
      layers           = { { kind = "tiled", blocks = { { block_id = window.block_id } } } },
    }
  end
  return {
    client_id = "client:self",
    view = { session_id = session.session_id, label = session.label,
             active_window_id = session.active, windows = windows },
  }
end

-- As the server does: a method that takes a session only reaches one the
-- connection is attached to.
local function attached_session(fake, session_id)
  local session = fake:session(session_id)
  if not session then return nil, "session_not_found" end
  if not fake.attached[session_id] then return nil, "not attached to " .. session_id end
  return session
end

function methods.session_destroy(fake, args)
  local session, err = attached_session(fake, args.session_id)
  if not session then return nil, err end
  fake:remove_session(args.session_id)
  return {}
end

function methods.session_new_window(fake, args)
  local session, err = attached_session(fake, args.session_id)
  if not session then return nil, err end
  local refused = label_refused(args.window_label)
  if refused then return nil, refused end
  if args.layout == nil then return nil, "bad_request" end
  local window_id, block_id = fake:add_window(args.session_id, args.window_label, args.layout)
  return { window_id = window_id, block_ids = { block_id }, revision = 1 }
end

function methods.session_close_window(fake, args)
  local session, err = attached_session(fake, args.session_id)
  if not session then return nil, err end
  if not fake:remove_window(args.session_id, args.window_id) then return nil, "not_found" end
  return { revision = 1 }
end

function methods.client_list(fake, args)
  local clients = {}
  for _, app in ipairs(fake.apps) do
    if args.session_id == nil or app.attached[args.session_id] then
      clients[#clients + 1] = { client_id = app.client_id }
    end
  end
  return { clients = clients }
end

function methods.client_perform(fake, args)
  for _, app in ipairs(fake.apps) do
    if app.client_id == args.client_id then
      if app.refuses then return nil, app.refuses end
      return {}
    end
  end
  return nil, "client_not_found"
end

-- The rex table init.lua sees.
function Fake:api()
  local fake = self
  fake.ui = {
    pick = function(prompt)
      fake:record("ui.pick", prompt)
      local answer = table.remove(fake.answers, 1) or { why = "cancelled" }
      return answer.value, answer.why, answer.detail
    end,
  }
  return {
    log = function(level, message)
      fake.logs[#fake.logs + 1] = { level = level, message = message }
    end,

    ui = fake.ui,

    json = {
      decode = function(text)
        local value = fake.json_values[text]
        if value == nil then return nil, "not JSON the fake made: " .. tostring(text) end
        return value
      end,
    },

    exec = function(argv, opts)
      local inner = login_inner(argv)
      if inner then
        fake:record("cmd", { argv = inner, cwd = opts and opts.cwd, shell = argv })
        if fake.run then return fake.run(inner, opts or {}) end
        return { ok = true, code = 0, stdout = "", stderr = "" }
      end
      fake:record("exec", argv)
      if argv[1] == "test" and argv[2] == "-d" then return { ok = fake.dirs[argv[3]] == true } end
      if argv[1] == "mkdir" then os.execute("mkdir -p " .. shell_quote(argv[3])) end
      return { ok = true, code = 0, stdout = "", stderr = "" }
    end,

    call = function(method, args)
      args = args or {}
      fake:record(method, args)
      local intercept = fake.intercept[method]
      if intercept then
        local handled, result, err = intercept(args)
        if handled then return result, err end
      end
      local handler = methods[method:gsub("%.", "_")]
      if not handler then return nil, "unknown method " .. method end
      return handler(fake, args)
    end,

    client = {
      queue = function(action, args)
        if fake.queue_fails then error(fake.queue_fails, 0) end
        fake:record("client.queue", { action = action, args = args })
      end,
    },

    session = {
      new_layer = function(args)
        local id = fake:new_id("layer")
        fake:record("session.new_layer", args)
        return { layer_id = id }
      end,
      close_layer = function(args)
        fake:record("session.close_layer", args)
        return {}
      end,
    },

    block = {
      call = function(creator, method, args)
        fake:record("block." .. method, args)
        if creator == "com.superlogical.terminal" and method == "process" then
          if fake.cwd == nil then return nil, "not_found" end
          return { foreground = { cwd = fake.cwd } }
        end
        return nil, "unknown block method " .. method
      end,
    },

    layout = {
      block = function(block) return { block = block } end,
    },

    action = function(definition)
      fake.actions[definition.name] = definition
    end,
  }
end

return Fake
