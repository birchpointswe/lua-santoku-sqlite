local test = require("santoku.test")
local serialize = require("santoku.serialize") -- luacheck: ignore

local err = require("santoku.error")
local assert = err.assert

local tbl = require("santoku.table")
local teq = tbl.equals

local validate = require("santoku.validate")
local eq = validate.isequal

local sqlite = require("lsqlite3")
local sql = require("santoku.sqlite")

local iter = require("santoku.iter")
local collect = iter.collect
local take = iter.take

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
  ]])

  local city = getcity("Tampa")
  assert(teq(city, { name = "Tampa", state = "Florida" }))

  local city = getcity("Albany")
  assert(teq(city, { name = "Albany", state = "New York" }))

  local getcitystate = db.getter([[
    select * from cities where name = ?
  ]], "state")

  local state = getcitystate("Albany")
  assert(eq(state, "New York"))

  local getstates = db.iter([[
    select * from cities
  ]])

  assert(teq(collect(getstates()), {
    { name = "New York", state = "New York" },
    { name = "Buffalo", state = "New York" },
    { name = "Albany", state = "New York" },
    { name = "Tampa", state = "Florida" },
    { name = "Miami", state = "Florida" },
  }))

  local allstates = db.all([[
    select * from cities
  ]])

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

  for i = 1, 100 do
    addn(i)
  end

  local getns = db.iter([[
    select * from numbers
  ]])

  local as = collect(take(2, getns()))
  local bs = collect(take(2, getns()))

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

  for i = 1, 100 do
    addn(i)
  end

  local getns = db.getter([[
    with evens as (select * from numbers where n % 2 == 0)
    select n from evens
    order by n desc
  ]])

  assert(teq({ n = 100 }, getns()))

end)
