local test = require("santoku.test")

local err = require("santoku.error")
local assert = err.assert
local pcall = err.pcall

local tbl = require("santoku.table")
local teq = tbl.equals

local validate = require("santoku.validate")
local eq = validate.isequal

local sqlite = require("santoku.sqlite.db")
local sql = require("santoku.sqlite")

local ivec = require("santoku.ivec")
local fvec = require("santoku.fvec")
local num = require("santoku.num")

local function drain (stmt)
  local out = {}
  while true do
    local res = stmt:step()
    if res == 100 then
      out[#out + 1] = stmt:get_value(0)
    elseif res == 101 then
      stmt:reset()
      return out
    else
      stmt:reset()
      return error("step failed")
    end
  end
end

test("auto-detects a vec param as a carray", function ()
  local db = sql(sqlite.open_memory())
  local q = db.all("select value from carray(?) order by rowid", true)
  assert(teq(q(ivec.create({ 10, 20, 30 })), {
    { value = 10 }, { value = 20 }, { value = 30 },
  }))
end)

test("explicit bind_carray binds the whole vector", function ()
  local db = sql(sqlite.open_memory())
  local stmt = db.db:prepare("select value from carray(?1) order by rowid")
  local v = ivec.create({ 1, 2, 3, 4, 5 })
  stmt:reset()
  stmt:bind_carray(1, v)
  assert(teq(drain(stmt), { 1, 2, 3, 4, 5 }))
end)

test("bind_carray slices with (start, count)", function ()
  local db = sql(sqlite.open_memory())
  local stmt = db.db:prepare("select value from carray(?1) order by rowid")
  local v = ivec.create({ 1, 2, 3, 4, 5 })
  stmt:reset()
  stmt:bind_carray(1, v, 1, 3)
  assert(teq(drain(stmt), { 2, 3, 4 }))
  stmt:reset()
  stmt:bind_carray(1, v, 4, 1)
  assert(teq(drain(stmt), { 5 }))
  stmt:reset()
  stmt:bind_carray(1, v, 0, 0)
  assert(teq(drain(stmt), {}))
end)

test("bind_carray slices float vectors", function ()
  local db = sql(sqlite.open_memory())
  local stmt = db.db:prepare("select value from carray(?1) order by rowid")
  local v = fvec.create({ 1.5, 2.5, 3.5 })
  stmt:reset()
  stmt:bind_carray(1, v, 1, 2)
  local got = drain(stmt)
  assert(eq(#got, 2))
  assert(num.abs(got[1] - 2.5) < 1e-6)
  assert(num.abs(got[2] - 3.5) < 1e-6)
end)

test("bind_carray rejects an out-of-range slice", function ()
  local db = sql(sqlite.open_memory())
  local stmt = db.db:prepare("select value from carray(?1) order by rowid")
  local v = ivec.create({ 1, 2, 3 })
  assert(eq(pcall(function () stmt:bind_carray(1, v, 2, 5) end), false))
  assert(eq(pcall(function () stmt:bind_carray(1, v, -1, 2) end), false))
end)
