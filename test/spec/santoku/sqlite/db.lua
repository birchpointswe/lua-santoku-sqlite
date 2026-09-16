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

test("progress budget interrupts a runaway query", function ()
  local db = sql(sqlite.open_memory())
  db.progress(100, 3)
  local runaway = function ()
    return db.query(
      "with recursive c(x) as (select 1 union all select x + 1 from c) select max(x) from c")
  end
  assert(eq(pcall(runaway), false))
  assert(eq(pcall(runaway), false))
  db.progress(100, 3)
  assert(eq(pcall(runaway), false))
  db.progress(nil)
  local rows = db.query("select 1")
  assert(eq(rows[1][1], 1))
  db.close()
end)

test("progress budget survives the coroutine that installed it", function ()
  local db = sql(sqlite.open_memory())
  local co = coroutine.create(function ()
    db.progress(100, 3)
  end)
  coroutine.resume(co)
  co = nil -- luacheck: ignore
  collectgarbage("collect")
  collectgarbage("collect")
  local ok = pcall(function ()
    return db.query(
      "with recursive c(x) as (select 1 union all select x + 1 from c) select max(x) from c")
  end)
  assert(eq(ok, false))
  db.progress(nil)
  db.close()
end)

test("authorizer policy survives the coroutine that installed it", function ()
  local db = sql(sqlite.open_memory())
  db.exec("create table t (n integer)")
  local co = coroutine.create(function ()
    db.authorizer({
      deny = { sqlite.ATTACH, sqlite.DETACH },
      pragmas = { "table_info" },
    })
  end)
  coroutine.resume(co)
  co = nil -- luacheck: ignore
  collectgarbage("collect")
  collectgarbage("collect")
  db.query("select n from t")
  db.query("pragma table_info(t)")
  assert(eq(pcall(function () db.query("attach ':memory:' as other") end), false))
  assert(eq(pcall(function () db.query("pragma page_size") end), false))
  db.authorizer(nil)
  db.close()
end)

test("closed handles and finalized statements raise", function ()
  local db = sql(sqlite.open_memory())
  db.exec("create table t (n integer)")
  local stmt = db.db:prepare("select n from t")
  db.close()
  assert(eq(pcall(function () return stmt:step() end), false))
  assert(eq(pcall(function () return stmt:reset() end), false))
  assert(eq(pcall(function () return stmt:column_names() end), false))
  assert(eq(pcall(function () return db.db:exec("select 1") end), false))
  assert(eq(pcall(function () return db.db:prepare("select 1") end), false))
  assert(eq(pcall(function () return db.db:progress(100, 3) end), false))
  assert(eq(pcall(function () return db.db:authorizer(nil) end), false))
  assert(eq(pcall(function () return db.db:last_insert_rowid() end), false))
end)

test("authorizer policy denies codes and gates pragmas", function ()
  local db = sql(sqlite.open_memory())
  db.exec("create table t (n integer)")
  db.authorizer({
    deny = { sqlite.ATTACH, sqlite.DETACH, sqlite.DROP_TABLE },
    pragmas = { "TABLE_INFO", "integrity_check" },
  })
  db.query("select n from t")
  db.exec("insert into t (n) values (1)")
  db.exec("create table u (m integer)")
  assert(eq(pcall(function () db.query("attach ':memory:' as other") end), false))
  assert(eq(pcall(function () db.exec("drop table u") end), false))
  db.query("pragma table_info(t)")
  db.query("pragma Table_Info(t)")
  db.query("pragma integrity_check")
  assert(eq(pcall(function () db.query("pragma page_size") end), false))
  assert(eq(pcall(function () db.query("pragma user_version") end), false))
  db.authorizer({ deny = { sqlite.ATTACH } })
  assert(eq(pcall(function () db.query("pragma table_info(t)") end), false))
  db.authorizer(nil)
  db.query("attach ':memory:' as other2")
  db.query("pragma page_size")
  db.close()
end)

test("authorizer policy rejects malformed specs and denies after", function ()
  local db = sql(sqlite.open_memory())
  db.exec("create table t (n integer)")
  local bad = {
    function () return db.authorizer(function () return true end) end,
    function () return db.authorizer("deny everything") end,
    function () return db.authorizer({ denies = { sqlite.ATTACH } }) end,
    function () return db.authorizer({ deny = sqlite.ATTACH }) end,
    function () return db.authorizer({ deny = { "attach" } }) end,
    function () return db.authorizer({ deny = { 1.5 } }) end,
    function () return db.authorizer({ deny = { 9999 } }) end,
    function () return db.authorizer({ pragmas = { 1 } }) end,
    function () return db.authorizer({ pragmas = { "" } }) end,
  }
  for i = 1, #bad do
    assert(eq(pcall(bad[i]), false))
    assert(eq(pcall(function () db.query("select n from t") end), false))
  end
  db.authorizer({ deny = { sqlite.ATTACH }, pragmas = { "table_info" } })
  db.query("select n from t")
  db.authorizer(nil)
  db.query("select n from t")
  db.close()
end)
