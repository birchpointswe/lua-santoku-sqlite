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
local fs = require("santoku.fs")
local utc = require("santoku.utc")
local random = require("santoku.random")
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
  local path = "tk_sqlite_test_" ..
    tostring(utc.time()) .. "_" .. tostring(random.num(1, 1000000)) .. ".db"
  fs.rm(path, true)
  local d1 = sql(sqlite.open(path))
  d1.exec("create table t (n)")
  d1.runner("insert into t (n) values (?)")(42)
  d1.close()
  local d2 = sql(sqlite.open(path))
  assert(eq(d2.getter("select n from t")(), 42))
  d2.close()
  fs.rm(path, true)
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

test("complete detects statement boundaries", function ()
  assert(eq(sqlite.complete("select 1;"), true))
  assert(eq(sqlite.complete("select 1"), false))
  assert(eq(sqlite.complete("insert into t values (';');"), true))
  assert(eq(sqlite.complete(
    "create trigger tr after insert on t begin select 1;"), false))
  assert(eq(sqlite.complete(
    "create trigger tr after insert on t begin select 1; end;"), true))
end)

test("query returns rows and column names for ad-hoc sql", function ()
  local db = sql(sqlite.open_memory())
  db.exec("create table t (a integer, b text)")
  local add = db.runner("insert into t (a, b) values (?, ?)")
  add(1, "x")
  add(2, "y")
  local rows, cols = db.query("select a, b from t order by a")
  assert(teq(cols, { "a", "b" }))
  assert(teq(rows, { { 1, "x" }, { 2, "y" } }))
  local rows2, cols2 = db.query("select b from t where a = ?", 2)
  assert(teq(cols2, { "b" }))
  assert(teq(rows2, { { "y" } }))
  local rows3, cols3 = db.query("select a from t where a > 100")
  assert(teq(cols3, { "a" }))
  assert(teq(rows3, {}))
  assert(eq(pcall(function () db.query("select nope from t") end), false))
end)

test("authorizer denies and detects", function ()
  local db = sql(sqlite.open_memory())
  db.exec("create table t (n integer)")
  local seen = {}
  db.authorizer(function (code, a)
    seen[#seen + 1] = { code, a }
    if code == sqlite.ATTACH then
      return false
    end
    return true
  end)
  assert(eq(pcall(function () db.query("attach ':memory:' as other") end), false))
  db.query("select n from t")
  local saw_attach = false
  local saw_read = false
  for i = 1, #seen do
    if seen[i][1] == sqlite.ATTACH then saw_attach = true end
    if seen[i][1] == sqlite.READ and seen[i][2] == "t" then saw_read = true end
  end
  assert(eq(saw_attach, true))
  assert(eq(saw_read, true))
  local ddl = {}
  db.authorizer(function (code, a)
    if code == sqlite.CREATE_TABLE or code == sqlite.DROP_TABLE
      or code == sqlite.ALTER_TABLE or code == sqlite.CREATE_VIEW
      or code == sqlite.DROP_VIEW then
      ddl[#ddl + 1] = { code, a }
    end
    return true
  end)
  db.exec("create table u (m integer)")
  assert(eq(#ddl, 1))
  assert(eq(ddl[1][1], sqlite.CREATE_TABLE))
  assert(eq(ddl[1][2], "u"))
  db.authorizer(nil)
  db.query("attach ':memory:' as other2")
  db.close()
end)
