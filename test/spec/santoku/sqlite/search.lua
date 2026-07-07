local test = require("santoku.test")

local err = require("santoku.error")
local assert = err.assert
local pcall = err.pcall

local validate = require("santoku.validate")
local eq = validate.isequal

local sqlite = require("santoku.sqlite.db")
local sql = require("santoku.sqlite")
local search = require("santoku.sqlite.search")

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

local function by_id (rows)
  local m = {}
  for i = 1, #rows do
    m[rows[i].id] = rows[i].score
  end
  return m
end

local function close (a, b)
  return math.abs(a - b) < 1e-6
end

test("weighted: batch add, cosine ranking, remove, reindex", function ()

  local db = sql(sqlite.open_memory())
  local idx = search.create(db, { name = "docs" })



  idx.add(
    { "a", "b", "c" },
    mkcsr(
      { 0, 3, 6, 8 },
      { 1, 2, 3, 2, 3, 4, 5, 6 },
      { 1, 1, 1, 1, 1, 1, 1, 1 }))


  local res = idx.search(mkcsr({ 0, 2 }, { 2, 3 }, { 1, 1 }), 10)
  local scores = by_id(res)
  assert(eq(#res, 2))
  assert(scores.a ~= nil and scores.b ~= nil)
  assert(scores.c == nil)

  local expected = 2 / math.sqrt(6)
  assert(close(scores.a, expected))
  assert(close(scores.b, expected))


  idx.remove({ "a" })
  res = idx.search(mkcsr({ 0, 2 }, { 2, 3 }, { 1, 1 }), 10)
  assert(eq(#res, 1))
  assert(eq(res[1].id, "b"))


  idx.add({ "a" }, mkcsr({ 0, 2 }, { 7, 8 }, { 1, 1 }))
  res = idx.search(mkcsr({ 0, 2 }, { 2, 3 }, { 1, 1 }), 10)
  assert(eq(#res, 1))
  assert(eq(res[1].id, "b"))

  res = idx.search(mkcsr({ 0, 1 }, { 7 }, { 1 }), 10)
  assert(eq(#res, 1))
  assert(eq(res[1].id, "a"))

end)

test("weighted: tf weights affect ranking", function ()

  local db = sql(sqlite.open_memory())
  local idx = search.create(db, { name = "w" })


  idx.add(
    { "x", "y" },
    mkcsr({ 0, 2, 4 }, { 1, 9, 1, 8 }, { 3, 1, 1, 1 }))


  local res = idx.search(mkcsr({ 0, 1 }, { 1 }, { 1 }), 10)
  assert(eq(#res, 2))
  assert(eq(res[1].id, "x"))

end)

test("presence-only: ranks by match count", function ()

  local db = sql(sqlite.open_memory())
  local idx = search.create(db, { name = "pres", weighted = false })

  idx.add(
    { "a", "b" },
    mkcsr({ 0, 3, 5 }, { 1, 2, 3, 1, 4 }))


  local res = idx.search(mkcsr({ 0, 3 }, { 1, 2, 3 }), 10)
  assert(eq(#res, 2))
  assert(eq(res[1].id, "a"))
  assert(eq(res[1].score, 3))
  assert(eq(res[2].id, "b"))
  assert(eq(res[2].score, 1))

end)

test("partition: namespaces are isolated", function ()

  local db = sql(sqlite.open_memory())
  local idx = search.create(db, { name = "p", partition = true })

  idx.add("u1", { "doc1" }, mkcsr({ 0, 2 }, { 1, 2 }, { 1, 1 }))
  idx.add("u2", { "doc2" }, mkcsr({ 0, 2 }, { 1, 2 }, { 1, 1 }))

  local r1 = idx.search("u1", mkcsr({ 0, 2 }, { 1, 2 }, { 1, 1 }), 10)
  assert(eq(#r1, 1))
  assert(eq(r1[1].id, "doc1"))

  local r2 = idx.search("u2", mkcsr({ 0, 2 }, { 1, 2 }, { 1, 1 }), 10)
  assert(eq(#r2, 1))
  assert(eq(r2[1].id, "doc2"))


  idx.clear("u1")
  assert(eq(#idx.search("u1", mkcsr({ 0, 2 }, { 1, 2 }, { 1, 1 }), 10), 0))
  assert(eq(#idx.search("u2", mkcsr({ 0, 2 }, { 1, 2 }, { 1, 1 }), 10), 1))

end)

test("partition: custom column name", function ()

  local db = sql(sqlite.open_memory())
  local idx = search.create(db, { name = "cn", partition = "sub" })

  idx.add("u1", { "doc1" }, mkcsr({ 0, 2 }, { 1, 2 }, { 1, 1 }))
  idx.add("u2", { "doc2" }, mkcsr({ 0, 2 }, { 1, 2 }, { 1, 1 }))


  assert(eq(db.getter("select sub from cn_tf where id = 'doc1'")(), "u1"))

  local r1 = idx.search("u1", mkcsr({ 0, 2 }, { 1, 2 }, { 1, 1 }), 10)
  assert(eq(#r1, 1))
  assert(eq(r1[1].id, "doc1"))

  idx.remove("u2", { "doc2" })
  assert(eq(#idx.search("u2", mkcsr({ 0, 2 }, { 1, 2 }, { 1, 1 }), 10), 0))
  assert(eq(#idx.search("u1", mkcsr({ 0, 2 }, { 1, 2 }, { 1, 1 }), 10), 1))

end)

test("errors: empty row", function ()

  local db = sql(sqlite.open_memory())
  local idx = search.create(db, { name = "e" })


  local ok = pcall(idx.add, { "a", "b" }, mkcsr({ 0, 0, 2 }, { 1, 2 }, { 1, 1 }))
  assert(eq(ok, false))

end)

test("counted: derives tf from occurrence counts when no weights", function ()

  local db = sql(sqlite.open_memory())
  local idx = search.create(db, { name = "cnt" })




  idx.add({ "a", "b" }, mkcsr({ 0, 3, 6 }, { 1, 1, 2, 1, 2, 2 }))


  assert(eq(db.getter("select tf from cnt_tf where id = 'a' and token = 1")(), 2))
  assert(eq(db.getter("select tf from cnt_tf where id = 'b' and token = 2")(), 2))


  local res = idx.search(mkcsr({ 0, 2 }, { 1, 1 }), 10)
  assert(eq(#res, 2))
  assert(eq(res[1].id, "a"))

  assert(math.abs(res[1].score - (4 / (2 * math.sqrt(5)))) < 1e-6)

  assert(math.abs(res[2].score - (2 / (2 * math.sqrt(5)))) < 1e-6)

end)

test("counted: a valued query against a counted index still works", function ()

  local db = sql(sqlite.open_memory())
  local idx = search.create(db, { name = "mix" })


  idx.add({ "a", "b" }, mkcsr({ 0, 2, 4 }, { 1, 1, 1, 2 }))


  local res = idx.search(mkcsr({ 0, 1 }, { 1 }, { 1 }), 10)
  assert(eq(#res, 2))
  assert(eq(res[1].id, "a"))

end)

test("transaction wrapping rolls back a failed batch", function ()

  local db = sql(sqlite.open_memory())
  local idx = search.create(db, { name = "tx" })

  idx.add({ "keep" }, mkcsr({ 0, 1 }, { 1 }, { 1 }))


  local ok = pcall(db.transaction, function ()
    idx.add({ "x", "y" }, mkcsr({ 0, 1, 1 }, { 2 }, { 1 }))
  end)
  assert(eq(ok, false))


  assert(eq(#idx.search(mkcsr({ 0, 1 }, { 2 }, { 1 }), 10), 0))
  assert(eq(#idx.search(mkcsr({ 0, 1 }, { 1 }, { 1 }), 10), 1))

end)
