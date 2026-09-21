local test = require("santoku.test")

local err = require("santoku.error")
local assert = err.assert

local validate = require("santoku.validate")
local eq = validate.isequal

local sqlite = require("santoku.sqlite.db")
local sql = require("santoku.sqlite")
local fts = require("santoku.sqlite.fts")

local ivec = require("santoku.ivec")
local fvec = require("santoku.fvec")
local csr = require("santoku.csr")

local function mkcsr (offsets, tokens, weights)
  local off = ivec.create(offsets)
  local nbr = ivec.create(tokens)
  if weights then
    return csr.create({ offsets = off, neighbors = nbr, values = fvec.create(weights) })
  else
    return csr.create({ offsets = off, neighbors = nbr })
  end
end

local function ids_of (rows)
  local m = {}
  for i = 1, #rows do
    m[rows[i].id] = true
  end
  return m
end

test("fts: add, search, remove, clear with text ids", function ()

  local db = sql(sqlite.open_memory())
  local idx = fts.create(db, { name = "docs" })

  idx.add(
    { "a", "b", "c" },
    mkcsr(
      { 0, 3, 6, 8 },
      { 1, 2, 3, 2, 3, 4, 5, 6 },
      { 1, 1, 1, 1, 1, 1, 1, 1 }))

  local res = idx.search(mkcsr({ 0, 2 }, { 2, 3 }, { 1, 1 }), 10)
  local got = ids_of(res)
  assert(eq(#res, 2))
  assert(got.a == true)
  assert(got.b == true)
  assert(got.c == nil)

  res = idx.search(mkcsr({ 0, 1 }, { 5 }, { 1 }), 10)
  assert(eq(#res, 1))
  assert(eq(res[1].id, "c"))

  idx.remove({ "a" })
  res = idx.search(mkcsr({ 0, 2 }, { 2, 3 }, { 1, 1 }), 10)
  assert(eq(#res, 1))
  assert(eq(res[1].id, "b"))

  idx.clear()
  res = idx.search(mkcsr({ 0, 2 }, { 2, 3 }, { 1, 1 }), 10)
  assert(eq(#res, 0))

end)

test("fts: term frequency is preserved and affects ranking", function ()

  local db = sql(sqlite.open_memory())
  local idx = fts.create(db, { name = "docs" })

  idx.add(
    { "many", "few" },
    mkcsr(
      { 0, 2, 4 },
      { 1, 9, 1, 9 },
      { 5, 1, 1, 5 }))

  local res = idx.search(mkcsr({ 0, 1 }, { 1 }, { 1 }), 10)
  assert(eq(#res, 2))
  assert(eq(res[1].id, "many"))

  res = idx.search(mkcsr({ 0, 1 }, { 9 }, { 1 }), 10)
  assert(eq(#res, 2))
  assert(eq(res[1].id, "few"))

end)

test("fts: re-adding an id replaces rather than duplicates", function ()

  local db = sql(sqlite.open_memory())
  local idx = fts.create(db, { name = "docs" })

  idx.add({ "a" }, mkcsr({ 0, 2 }, { 1, 2 }, { 1, 1 }))
  idx.add({ "a" }, mkcsr({ 0, 2 }, { 7, 8 }, { 1, 1 }))

  local res = idx.search(mkcsr({ 0, 1 }, { 1 }, { 1 }), 10)
  assert(eq(#res, 0))

  res = idx.search(mkcsr({ 0, 1 }, { 7 }, { 1 }), 10)
  assert(eq(#res, 1))
  assert(eq(res[1].id, "a"))

  local n = db.getter("select count(*) as n from docs_map", "n")()
  assert(eq(n, 1))

end)

test("fts: query terms are OR-ed rather than AND-ed", function ()

  local db = sql(sqlite.open_memory())
  local idx = fts.create(db, { name = "docs" })

  idx.add(
    { "one", "two" },
    mkcsr(
      { 0, 1, 2 },
      { 1, 2 },
      { 1, 1 }))

  local res = idx.search(mkcsr({ 0, 2 }, { 1, 2 }, { 1, 1 }), 10)
  assert(eq(#res, 2))

end)
