-- Shared by the Lua tests: a check function that counts failures, and a fresh
-- copy of the plugin for each test.
--
--   local t = require("helper")
--   t.section("what is being tested")
--   t.check("what should hold", condition, optional_detail)
--   t.done()   -- exits 1 if any check failed

local helper = {}

-- The repository root, absolute so the plugin can find worktrunk.sh beside it.
local test_dir = (debug.getinfo(1, "S").source or ""):gsub("^@", ""):match("^(.*)/[^/]*$") or "."
if test_dir:sub(1, 1) ~= "/" then test_dir = (os.getenv("PWD") or ".") .. "/" .. test_dir end
helper.root = test_dir:match("^(.*)/test$") or (test_dir .. "/..")

local failed = 0

function helper.section(name)
  print("\n" .. name)
end

function helper.check(name, condition, detail)
  if condition then
    print("  ok   " .. name)
  else
    print("  FAIL " .. name .. (detail ~= nil and ("\n       " .. tostring(detail)) or ""))
    failed = failed + 1
  end
end

-- A fresh copy of the plugin, set up with opts; its module state starts clean.
function helper.load_plugin(opts)
  local M = dofile(helper.root .. "/init.lua")
  return M.setup(opts or {})
end

-- The error a function raises, or nil if it returns.
function helper.error_of(fn, ...)
  local ok, err = pcall(fn, ...)
  if ok then return nil end
  return tostring(err)
end

function helper.same_list(a, b)
  if #a ~= #b then return false end
  for i = 1, #a do
    if a[i] ~= b[i] then return false end
  end
  return true
end

function helper.show(list)
  local parts = {}
  for i, v in ipairs(list) do parts[i] = tostring(v) end
  return "{ " .. table.concat(parts, ", ") .. " }"
end

function helper.done(cleanup)
  if cleanup then cleanup() end
  print()
  if failed > 0 then
    print(failed .. " check(s) failed")
    os.exit(1)
  end
  print("all checks passed")
  os.exit(0)
end

return helper
