local test = require("santoku.test")
local serialize = require("santoku.serialize") -- luacheck: ignore

local err = require("santoku.error")
local assert = err.assert
local pcall = err.pcall

local tbl = require("santoku.table")
local teq = tbl.equals

local validate = require("santoku.validate")
local eq = validate.isequal

local sqlite = require("santoku.sqlite.db")
local sql = require("santoku.sqlite")

local arr = require("santoku.array")
local icollect = arr.icollect

test("should wrap various functions", function ()

  local db = sql(sqlite.open_memory())

  local run_ddl = db.runner([[
    create table cities (
      name text,
      state text
    );
  ]])

  run_ddl()

  local addcity = db.runner([[
    insert into cities (name, state) values (?, ?)
  ]])

  addcity("New York", "New York")
  addcity("Buffalo", "New York")
  addcity("Albany", "New York")
  addcity("Tampa", "Florida")
  addcity("Miami", "Florida")

  local getcity = db.getter([[
    select * from cities where name = ?
  ]], true)

  local city = getcity("Tampa")
  assert(teq(city, { name = "Tampa", state = "Florida" }))

  local city = getcity("Albany")
  assert(teq(city, { name = "Albany", state = "New York" }))

  local getcitystate = db.getter([[
    select state from cities where name = ?
  ]])

  local state = getcitystate("Albany")
  assert(eq(state, "New York"))

  local getstates = db.iter([[
    select * from cities
  ]], true)

  assert(teq(icollect(getstates()), {
    { name = "New York", state = "New York" },
    { name = "Buffalo", state = "New York" },
    { name = "Albany", state = "New York" },
    { name = "Tampa", state = "Florida" },
    { name = "Miami", state = "Florida" },
  }))

  local allstates = db.all([[
    select * from cities
  ]], true)

  assert(teq(allstates(), {
    { name = "New York", state = "New York" },
    { name = "Buffalo", state = "New York" },
    { name = "Albany", state = "New York" },
    { name = "Tampa", state = "Florida" },
    { name = "Miami", state = "Florida" },
  }))

end)

test("should handle multiple iterators", function ()

  local db = sql(sqlite.open_memory())

  db.exec([[
    create table numbers (
      n integer
    );
  ]])

  local addn = db.inserter([[
    insert into numbers (n) values (?)
  ]])

  db.transaction("deferred", function (a, b, c)
    assert(teq({ a, b, c }, { 1, 2, 3 }))
    for i = 1, 100 do
      local x = addn(i)
      assert(teq({ x }, { i }))
    end
  end, 1, 2, 3)

  local getns = db.iter([[
    select * from numbers
  ]])

  local as = icollect(2, getns())
  local bs = icollect(2, getns())

  assert(teq(as, bs))

end)

test("should handle with clauses", function ()

  local db = sql(sqlite.open_memory())

  db.exec([[
    create table numbers (
      n integer
    );
  ]])

  local addn = db.inserter([[
    insert into numbers (n) values (?)
  ]])

  db.transaction(function (a, b, c)
    assert(teq({ a, b, c }, { 1, 2, 3 }))
    for i = 1, 100 do
      local x = addn(i)
      assert(teq({ x }, { i }))
    end
  end, 1, 2, 3)

  local getns = db.getter([[
    with evens as (select * from numbers where n % 2 == 0)
    select n from evens
    order by n desc
  ]])

  assert(teq({ 100 }, { getns() }))

end)

test("nested transaction", function ()
  local db = sql(sqlite.open_memory())
  db.transaction(function ()
    db.transaction(function ()

    end)
  end)
end)

test("binds named parameters", function ()
  local db = sql(sqlite.open_memory())
  db.exec("create table cities (name text, state text)")
  local add = db.runner("insert into cities (name, state) values (:name, :state)")
  add({ name = "Tampa", state = "Florida" })
  local get = db.getter("select state from cities where name = :name")
  assert(eq(get({ name = "Tampa" }), "Florida"))
end)

test("round-trips null and text with embedded zeros", function ()
  local db = sql(sqlite.open_memory())
  db.exec("create table t (a, b)")
  db.runner("insert into t (a, b) values (?, ?)")(nil, "x\0y")
  local row = db.getter("select a, b from t", true)()
  assert(eq(row.a, nil))
  assert(eq(row.b, "x\0y"))
end)

test("propagates sql errors", function ()
  local db = sql(sqlite.open_memory())
  assert(eq(pcall(function () db.exec("not valid sql") end), false))
  assert(eq(pcall(function () db.runner("select x from nope") end), false))
end)

test("persists to a file across open and close", function ()
  local dir = os.getenv("PREFIX")
  local path = (dir and (dir .. "/tmp") or "/tmp") ..
    "/tk_sqlite_test_" .. tostring(os.time()) .. "_" .. tostring(math.random(1, 1000000)) .. ".db"
  os.remove(path)
  local d1 = sql(sqlite.open(path))
  d1.exec("create table t (n)")
  d1.runner("insert into t (n) values (?)")(42)
  d1.close()
  local d2 = sql(sqlite.open(path))
  assert(eq(d2.getter("select n from t")(), 42))
  d2.close()
  os.remove(path)
end)

test("manual begin/commit and begin/rollback", function ()
  local db = sql(sqlite.open_memory())
  db.exec("create table t (n integer)")
  local addn = db.runner("insert into t (n) values (?)")
  local count = db.getter("select count(*) from t")

  db.begin("immediate")
  addn(1)
  addn(2)
  db.commit()
  assert(eq(count(), 2))

  db.begin()
  addn(3)
  db.rollback()
  assert(eq(count(), 2))
  db.close()
end)
