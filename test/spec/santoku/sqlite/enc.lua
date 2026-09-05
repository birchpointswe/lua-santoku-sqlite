local test = require("santoku.test")

local err = require("santoku.error")
local assert = err.assert

local sqlite = require("santoku.sqlite.db")
local sql = require("santoku.sqlite")
local str = require("santoku.string")
local num = require("santoku.num")
local fs = require("santoku.fs")

local KEY_A = str.rep("A", 32)
local KEY_B = str.rep("B", 32)

local WAL_OK = not sqlite.wasm

local seq = 0

local function tmpname (n)
  seq = seq + 1
  return "tk-enc-" .. n .. "-" .. tostring(seq) .. ".db"
end

local function rm (p)
  fs.rm(p, true)
  fs.rm(p .. "-journal", true)
  fs.rm(p .. "-wal", true)
  fs.rm(p .. "-shm", true)
end

local function slurp (p)
  if not fs.exists(p) then return nil end
  return fs.readfile(p, "rb")
end

local function seed (db, rows)
  db.runner([[
    create table notes (id integer primary key, body text)
  ]])()
  local ins = db.runner("insert into notes (id, body) values (?1, ?2)")
  for i = 1, rows do
    ins(i, "the quick brown fox jumps over the lazy dog " .. i)
  end
end

test("encrypted db round-trips across reopen", function ()
  local p = tmpname("roundtrip")
  rm(p)
  local raw = sqlite.open_encrypted(p, KEY_A)
  assert(raw ~= nil, "open_encrypted returned nil")
  seed(sql(raw), 20)
  raw:close_vm()
  raw:close()
  local raw2 = sqlite.open_encrypted(p, KEY_A)
  assert(raw2 ~= nil)
  local db2 = sql(raw2)
  assert(db2.getter("select count(*) as n from notes", "n")() == 20)
  assert(db2.getter("select body from notes where id = 7", "body")()
    == "the quick brown fox jumps over the lazy dog 7")
  raw2:close_vm()
  raw2:close()
  rm(p)
end)

test("wrong key cannot read the database", function ()
  local p = tmpname("wrongkey")
  rm(p)
  local raw = sqlite.open_encrypted(p, KEY_A)
  seed(sql(raw), 5)
  raw:close_vm()
  raw:close()
  local ok = pcall(function ()
    local r = sqlite.open_encrypted(p, KEY_B)
    if r == nil then error("open failed") end
    return sql(r).getter("select count(*) as n from notes", "n")()
  end)
  assert(ok == false, "wrong key must not yield readable data")
  rm(p)
end)

test("no plaintext reaches the disk", function ()
  local p = tmpname("plaintext")
  rm(p)
  local raw = sqlite.open_encrypted(p, KEY_A)
  seed(sql(raw), 40)
  raw:close_vm()
  raw:close()
  local blob = slurp(p)
  assert(blob ~= nil and #blob > 0, "no file written")
  assert(not blob:find("notes", 1, true), "table name leaked to disk")
  assert(not blob:find("quick brown fox", 1, true), "row content leaked to disk")
  assert(not blob:find("CREATE TABLE", 1, true), "schema leaked to disk")
  assert(not blob:find("SQLite format 3", 1, true), "sqlite header leaked to disk")
  assert(blob:sub(1, 8) == "TKSQENC1", "missing container magic")
  rm(p)
end)

test("rollback works and journalled content never lands in cleartext", function ()
  local p = tmpname("journal")
  rm(p)
  local raw = sqlite.open_encrypted(p, KEY_A)
  local db = sql(raw)
  seed(db, 10)
  local ok = pcall(function ()
    return db.transaction(function ()
      db.runner("insert into notes (id, body) values (?1, ?2)")(1000, "rolled back sentinel")
      error("abort")
    end)
  end)
  assert(ok == false, "transaction should have aborted")
  assert(db.getter("select count(*) as n from notes", "n")() == 10,
    "rollback did not restore row count")
  raw:close_vm()
  raw:close()
  local blob = slurp(p)
  assert(not blob:find("rolled back sentinel", 1, true),
    "journalled content leaked to disk")
  rm(p)
end)

test("larger dataset spanning many pages", function ()
  local p = tmpname("many")
  rm(p)
  local raw = sqlite.open_encrypted(p, KEY_A)
  seed(sql(raw), 2000)
  raw:close_vm()
  raw:close()
  local raw2 = sqlite.open_encrypted(p, KEY_A)
  local db2 = sql(raw2)
  assert(db2.getter("select count(*) as n from notes", "n")() == 2000)
  assert(db2.getter("select body from notes where id = 1999", "body")()
    == "the quick brown fox jumps over the lazy dog 1999")
  raw2:close_vm()
  raw2:close()
  local blob = slurp(p)
  assert(not blob:find("quick brown fox", 1, true))
  rm(p)
end)

test("updates and deletes rewrite pages correctly", function ()
  local p = tmpname("mutate")
  rm(p)
  local raw = sqlite.open_encrypted(p, KEY_A)
  local db = sql(raw)
  seed(db, 100)
  local upd = db.runner("update notes set body = ?2 where id = ?1")
  for i = 1, 100, 2 do
    upd(i, "updated body " .. i)
  end
  local del = db.runner("delete from notes where id = ?1")
  for i = 2, 100, 4 do
    del(i)
  end
  raw:close_vm()
  raw:close()
  local raw2 = sqlite.open_encrypted(p, KEY_A)
  local db2 = sql(raw2)
  assert(db2.getter("select body from notes where id = 51", "body")() == "updated body 51")
  assert(db2.getter("select count(*) as n from notes where id = 2", "n")() == 0)
  raw2:close_vm()
  raw2:close()
  rm(p)
end)

test("rejects a wrong-size key", function ()
  local p = tmpname("badkey")
  rm(p)
  local raw, e = sqlite.open_encrypted(p, "tooshort")
  assert(raw == nil)
  assert(e == "key must be exactly 32 bytes")
  rm(p)
end)

test("refuses to open a plaintext database as encrypted", function ()
  local p = tmpname("plainopen")
  rm(p)
  local raw = sqlite.open(p)
  seed(sql(raw), 3)
  raw:close_vm()
  raw:close()
  local ok = pcall(function ()
    local r = sqlite.open_encrypted(p, KEY_A)
    if r == nil then error("open failed") end
    return sql(r).getter("select count(*) as n from notes", "n")()
  end)
  assert(ok == false, "plaintext db must not open as encrypted")
  rm(p)
end)

test("two encrypted databases with different keys coexist", function ()
  local p1 = tmpname("coexist1")
  local p2 = tmpname("coexist2")
  rm(p1) rm(p2)
  local r1 = sqlite.open_encrypted(p1, KEY_A)
  local r2 = sqlite.open_encrypted(p2, KEY_B)
  local d1, d2 = sql(r1), sql(r2)
  seed(d1, 5)
  seed(d2, 7)
  assert(d1.getter("select count(*) as n from notes", "n")() == 5)
  assert(d2.getter("select count(*) as n from notes", "n")() == 7)
  r1:close_vm()
  r1:close()
  r2:close_vm()
  r2:close()
  local ok = pcall(function ()
    local r = sqlite.open_encrypted(p1, KEY_B)
    if r == nil then error("open failed") end
    return sql(r).getter("select count(*) as n from notes", "n")()
  end)
  assert(ok == false, "keys must not be interchangeable")
  rm(p1) rm(p2)
end)

test("key_set enables ATTACH of a differently-keyed database", function ()
  local pa, pb = tmpname("atta"), tmpname("attb")
  rm(pa) rm(pb)
  local ra = sqlite.open_encrypted(pa, KEY_A)
  seed(sql(ra), 3)
  ra:close_vm() ra:close()
  local rb = sqlite.open_encrypted(pb, KEY_B)
  seed(sql(rb), 4)
  rb:close_vm() rb:close()

  local r = sqlite.open_encrypted(pa, KEY_A)
  local d = sql(r)
  local ok = pcall(function () return d.exec("attach database '" .. pb .. "' as b") end)
  assert(ok == false, "attach without a registered key must fail")
  r:close_vm() r:close()

  assert(sqlite.key_set(pb, KEY_B) == true)
  local r2 = sqlite.open_encrypted(pa, KEY_A)
  local d2 = sql(r2)
  d2.exec("attach database '" .. pb .. "' as b")
  local n = d2.getter(
    "select count(*) as n from (select id from main.notes union all select id from b.notes)", "n")()
  assert(n == 7, "expected 3 + 4 rows across the attached databases, got " .. tostring(n))
  d2.exec("detach database b")
  r2:close_vm() r2:close()
  assert(sqlite.key_clear(pb) == true)
  rm(pa) rm(pb)
end)

test("key_set rejects a conflicting key and a wrong size", function ()
  local p = tmpname("keyset")
  local bad, e = sqlite.key_set(p, "short")
  assert(bad == nil and e == "key must be exactly 32 bytes")
  assert(sqlite.key_set(p, KEY_A) == true)
  local conflict, e2 = sqlite.key_set(p, KEY_B)
  assert(conflict == nil)
  assert(e2 == "path already registered with a different key")
  sqlite.key_clear(p)
end)

test("attached databases inherit the connection's VFS", function ()

  local pe, pp = tmpname("vfse"), tmpname("vfsp")
  rm(pe) rm(pp)
  local re = sqlite.open_encrypted(pe, KEY_A)
  seed(sql(re), 2)
  re:close_vm() re:close()
  assert(sqlite.key_set(pe, KEY_A) == true)
  local rp = sqlite.open(pp)
  local dp = sql(rp)
  dp.runner("create table x (i integer)")()
  local ok = pcall(function ()
    dp.exec("attach database '" .. pe .. "' as e")
    return dp.getter("select count(*) as n from e.notes", "n")()
  end)
  assert(ok == false, "a plain connection must not be able to read an encrypted attach")
  rp:close_vm() rp:close()
  sqlite.key_clear(pe)
  rm(pe) rm(pp)
end)

test("merged read connection: in-memory main with encrypted attaches", function ()

  local pa, pb = tmpname("mga"), tmpname("mgb")
  rm(pa) rm(pb)
  local ra = sqlite.open_encrypted(pa, KEY_A)
  seed(sql(ra), 3)
  ra:close_vm() ra:close()
  local rb = sqlite.open_encrypted(pb, KEY_B)
  seed(sql(rb), 4)
  rb:close_vm() rb:close()

  assert(sqlite.key_set(pa, KEY_A) == true)
  assert(sqlite.key_set(pb, KEY_B) == true)
  local vfs = sqlite.enc_vfs()
  assert(type(vfs) == "string" and vfs ~= "")

  local r = sqlite.open_v2(":memory:", vfs)
  assert(r ~= nil, "could not open :memory: on the encrypting vfs")
  local d = sql(r)
  d.exec("attach database '" .. pa .. "' as s1")
  d.exec("attach database '" .. pb .. "' as s2")
  local n = d.getter(
    "select count(*) as n from (select id from s1.notes union all select id from s2.notes)", "n")()
  assert(n == 7, "expected 7 merged rows, got " .. tostring(n))

  assert(d.getter("select body from s1.notes where id = 1", "body")()
    == "the quick brown fox jumps over the lazy dog 1")
  assert(d.getter("select body from s2.notes where id = 4", "body")()
    == "the quick brown fox jumps over the lazy dog 4")
  d.exec("detach database s1")
  d.exec("detach database s2")
  r:close_vm() r:close()
  sqlite.key_clear(pa) sqlite.key_clear(pb)
  rm(pa) rm(pb)
end)

local HDR, BLOCK, OVH = 128, 4096, 40
local FRAME = BLOCK + OVH
local DATA0 = HDR + FRAME

local function spit (p, s)
  fs.writefile(p, s, "wb")
end

local function frame_nonce (blob, i)
  local off = DATA0 + i * FRAME
  return blob:sub(off + 1, off + 24)
end

test("every write of a block draws a fresh nonce", function ()

  local p = tmpname("nonce")
  rm(p)
  local raw = sqlite.open_encrypted(p, KEY_A)
  local db = sql(raw)
  seed(db, 5)
  raw:close_vm() raw:close()
  local n1 = frame_nonce(slurp(p), 0)

  local raw2 = sqlite.open_encrypted(p, KEY_A)
  local db2 = sql(raw2)

  db2.runner("update notes set body = ?2 where id = ?1")(1, "changed")
  raw2:close_vm() raw2:close()
  local n2 = frame_nonce(slurp(p), 0)

  assert(#n1 == 24 and #n2 == 24)
  assert(n1 ~= n2, "frame 0 nonce was reused across a rewrite")
  rm(p)
end)

test("a tampered frame fails the read instead of returning garbage", function ()
  local p = tmpname("tamper")
  rm(p)
  local raw = sqlite.open_encrypted(p, KEY_A)
  seed(sql(raw), 20)
  raw:close_vm() raw:close()

  local blob = slurp(p)

  local pos = DATA0 + 24 + 100
  local byte = blob:byte(pos + 1)
  local flipped = str.char((byte + 1) % 256)
  spit(p, blob:sub(1, pos) .. flipped .. blob:sub(pos + 2))

  local ok = pcall(function ()
    local r = sqlite.open_encrypted(p, KEY_A)
    if r == nil then error("open failed") end
    return sql(r).getter("select count(*) as n from notes", "n")()
  end)
  assert(ok == false, "tampered ciphertext must not be readable")
  rm(p)
end)

test("frames cannot be reordered (AAD binds the block index)", function ()
  local p = tmpname("reorder")
  rm(p)
  local raw = sqlite.open_encrypted(p, KEY_A)
  seed(sql(raw), 200)
  raw:close_vm() raw:close()

  local blob = slurp(p)
  assert(#blob >= DATA0 + 2 * FRAME, "need at least two frames")
  local f0 = blob:sub(DATA0 + 1, DATA0 + FRAME)
  local f1 = blob:sub(DATA0 + FRAME + 1, DATA0 + 2 * FRAME)

  spit(p, blob:sub(1, DATA0) .. f1 .. f0 .. blob:sub(DATA0 + 2 * FRAME + 1))

  local ok = pcall(function ()
    local r = sqlite.open_encrypted(p, KEY_A)
    if r == nil then error("open failed") end
    return sql(r).getter("select count(*) as n from notes", "n")()
  end)
  assert(ok == false, "swapped frames must not decrypt")
  rm(p)
end)

test("frames cannot be transplanted between files (AAD binds the file salt)", function ()

  local p1, p2 = tmpname("tp1"), tmpname("tp2")
  rm(p1) rm(p2)
  local r1 = sqlite.open_encrypted(p1, KEY_A)
  seed(sql(r1), 200)
  r1:close_vm() r1:close()
  local r2 = sqlite.open_encrypted(p2, KEY_A)
  seed(sql(r2), 200)
  r2:close_vm() r2:close()

  local b1, b2 = slurp(p1), slurp(p2)
  assert(#b1 >= DATA0 + 2 * FRAME and #b2 >= DATA0 + 2 * FRAME)

  local graft = b1:sub(DATA0 + FRAME + 1, DATA0 + 2 * FRAME)
  spit(p2, b2:sub(1, DATA0 + FRAME) .. graft .. b2:sub(DATA0 + 2 * FRAME + 1))

  local ok = pcall(function ()
    local r = sqlite.open_encrypted(p2, KEY_A)
    if r == nil then error("open failed") end
    return sql(r).getter("select count(*) as n from notes", "n")()
  end)
  assert(ok == false, "a frame from another file must not decrypt")
  rm(p1) rm(p2)
end)

test("page sizes smaller and larger than the block round-trip", function ()
  for _, ps in ipairs({ 512, 8192 }) do
    local p = tmpname("ps" .. ps)
    rm(p)
    local raw = sqlite.open_encrypted(p, KEY_A)
    local db = sql(raw)
    db.exec("pragma page_size = " .. ps)
    seed(db, 300)
    raw:close_vm() raw:close()
    local raw2 = sqlite.open_encrypted(p, KEY_A)
    local db2 = sql(raw2)
    assert(db2.getter("select count(*) as n from notes", "n")() == 300,
      "row count wrong at page_size " .. ps)
    assert(db2.getter("select body from notes where id = 299", "body")()
      == "the quick brown fox jumps over the lazy dog 299",
      "row content wrong at page_size " .. ps)
    raw2:close_vm() raw2:close()
    assert(not slurp(p):find("quick brown fox", 1, true))
    rm(p)
  end
end)

test("values larger than a block round-trip (overflow pages)", function ()
  local p = tmpname("big")
  rm(p)
  local big = str.rep("x", 200000) .. "-END"
  local raw = sqlite.open_encrypted(p, KEY_A)
  local db = sql(raw)
  db.runner("create table blobs (id integer primary key, body text)")()
  db.runner("insert into blobs (id, body) values (?1, ?2)")(1, big)
  raw:close_vm() raw:close()
  local raw2 = sqlite.open_encrypted(p, KEY_A)
  local got = sql(raw2).getter("select body from blobs where id = 1", "body")()
  assert(got == big, "large value did not round-trip")
  raw2:close_vm() raw2:close()
  rm(p)
end)

test("vacuum rewrites the file and keeps it encrypted", function ()
  local p = tmpname("vacuum")
  rm(p)
  local raw = sqlite.open_encrypted(p, KEY_A)
  local db = sql(raw)
  seed(db, 500)
  db.runner("delete from notes where id > ?1")(100)
  db.exec("vacuum")
  assert(db.getter("select count(*) as n from notes", "n")() == 100)
  raw:close_vm() raw:close()
  local raw2 = sqlite.open_encrypted(p, KEY_A)
  assert(sql(raw2).getter("select count(*) as n from notes", "n")() == 100)
  raw2:close_vm() raw2:close()
  local blob = slurp(p)
  assert(blob:sub(1, 8) == "TKSQENC1")
  assert(not blob:find("quick brown fox", 1, true))
  rm(p)
end)

test("a second connection sees writes made by the first", function ()

  local p = tmpname("twoconn")
  rm(p)
  local ra = sqlite.open_encrypted(p, KEY_A)
  local da = sql(ra)
  seed(da, 10)

  assert(sqlite.key_set(p, KEY_A) == true)
  local rb = sqlite.open_encrypted(p, KEY_A)
  local dbb = sql(rb)
  assert(dbb.getter("select count(*) as n from notes", "n")() == 10)

  local ins = da.runner("insert into notes (id, body) values (?1, ?2)")
  for i = 11, 800 do
    ins(i, "the quick brown fox jumps over the lazy dog " .. i)
  end

  local n = dbb.getter("select count(*) as n from notes", "n")()
  assert(n == 800, "second connection saw " .. tostring(n) .. " rows, expected 800")

  ra:close_vm() ra:close()
  rb:close_vm() rb:close()
  sqlite.key_clear(p)
  rm(p)
end)

test("the -journal file itself is encrypted mid-transaction", function ()

  local p = tmpname("jrnl")
  rm(p)
  local raw = sqlite.open_encrypted(p, KEY_A)
  local db = sql(raw)
  seed(db, 200)

  local jrnl_seen, jrnl_blob = false, nil
  local ok = pcall(function ()
    return db.transaction(function ()

      local upd = db.runner("update notes set body = ?2 where id = ?1")
      for i = 1, 200 do
        upd(i, "SENTINELPLAINTEXT-" .. i .. "-the quick brown fox")
      end
      local j = slurp(p .. "-journal")
      if j and #j > 0 then jrnl_seen, jrnl_blob = true, j end
      error("abort")
    end)
  end)
  assert(ok == false)
  raw:close_vm() raw:close()

  assert(jrnl_seen, "no journal file was observed mid-transaction")

  assert(not jrnl_blob:find("quick brown fox", 1, true),
    "journal leaked page pre-images in cleartext")
  assert(not jrnl_blob:find("SENTINELPLAINTEXT", 1, true),
    "journal leaked new page images in cleartext")
  assert(not jrnl_blob:find("notes", 1, true), "journal leaked the schema")
  assert(jrnl_blob:sub(1, 8) == "TKSQENC1", "journal is not in the encrypted container")
  rm(p)
end)

test("a hot journal is decrypted and rolled back on a cold open", function ()

  local p, pj, pn = tmpname("hotj"), tmpname("hotj-withj"), tmpname("hotj-noj")
  rm(p) rm(pj) rm(pn)
  local pad = str.rep("z", 600)
  local raw = sqlite.open_encrypted(p, KEY_A)
  local db = sql(raw)
  db.exec("pragma cache_size = 16")
  db.runner("create table notes (id integer primary key, body text)")()
  local ins = db.runner("insert into notes (id, body) values (?1, ?2)")
  for i = 1, 3000 do ins(i, "clean-" .. i .. "-" .. pad) end
  raw:close_vm() raw:close()

  local snap_db, snap_j
  local r2 = sqlite.open_encrypted(p, KEY_A)
  local d2 = sql(r2)
  d2.exec("pragma cache_size = 16")
  local ok = pcall(function ()
    return d2.transaction(function ()
      local upd = d2.runner("update notes set body = ?2 where id = ?1")
      for i = 1, 3000 do upd(i, "DIRTY-" .. i .. "-" .. pad) end
      snap_db = slurp(p)
      snap_j = slurp(p .. "-journal")
      error("abort")
    end)
  end)
  assert(ok == false)
  r2:close_vm() r2:close()
  assert(snap_j ~= nil and #snap_j > 0, "no journal present mid-transaction")

  spit(pn, snap_db)
  local okn = pcall(function ()
    local rn = sqlite.open_encrypted(pn, KEY_A)
    if rn == nil then error("open failed") end
    return sql(rn).getter("select body from notes where id = 7", "body")()
  end)
  assert(okn == false,
    "a mid-transaction snapshot without its journal must not expose uncommitted pages")

  spit(pj, snap_db)
  spit(pj .. "-journal", snap_j)
  local r3 = sqlite.open_encrypted(pj, KEY_A)
  assert(r3 ~= nil, "database with a hot journal failed to open")
  local d3 = sql(r3)
  assert(d3.getter("select count(*) as n from notes", "n")() == 3000,
    "row count wrong after hot-journal recovery")
  assert(d3.getter("select body from notes where id = 7", "body")():sub(1, 8) == "clean-7-",
    "hot journal was not rolled back -- uncommitted data survived")
  r3:close_vm() r3:close()
  rm(p) rm(pj) rm(pn)
end)

test("clearing the key of an open database fails writes loudly", function ()

  local p = tmpname("keygone")
  rm(p)
  local raw = sqlite.open_encrypted(p, KEY_A)
  local db = sql(raw)
  seed(db, 3)
  assert(sqlite.key_clear(p) == true)
  local ok = pcall(function ()
    db.runner("insert into notes (id, body) values (?1, ?2)")(100, "late write")
  end)
  assert(ok == false, "write with a cleared key must fail, not draw a random journal key")
  raw:close_vm() raw:close()
  rm(p)
end)

test("wal mode round-trips and the wal file is encrypted", function ()
  if not WAL_OK then return end
  local p = tmpname("wal")
  rm(p)
  local raw = sqlite.open_encrypted(p, KEY_A)
  local db = sql(raw)
  db.exec("pragma journal_mode = wal")
  assert(db.getter("pragma journal_mode", "journal_mode")() == "wal",
    "journal_mode=wal was refused by the shim")
  seed(db, 200)
  local wal = slurp(p .. "-wal")
  assert(wal ~= nil and #wal > 0, "no wal file written")
  assert(wal:sub(1, 8) == "TKSQENC1", "wal is not in the encrypted container")
  assert(not wal:find("quick brown fox", 1, true), "wal leaked row content")
  assert(not wal:find("notes", 1, true), "wal leaked the schema")
  raw:close_vm() raw:close()
  local raw2 = sqlite.open_encrypted(p, KEY_A)
  local db2 = sql(raw2)
  assert(db2.getter("select count(*) as n from notes", "n")() == 200)
  assert(db2.getter("select body from notes where id = 199", "body")()
    == "the quick brown fox jumps over the lazy dog 199")
  raw2:close_vm() raw2:close()
  rm(p)
end)

test("wal: a second connection reads while the first writes", function ()
  if not WAL_OK then return end
  local p = tmpname("walconc")
  rm(p)
  local ra = sqlite.open_encrypted(p, KEY_A)
  local da = sql(ra)
  da.exec("pragma journal_mode = wal")
  seed(da, 10)
  assert(sqlite.key_set(p, KEY_A) == true)
  local rb = sqlite.open_encrypted(p, KEY_A)
  local dbb = sql(rb)
  assert(dbb.getter("select count(*) as n from notes", "n")() == 10)
  local ins = da.runner("insert into notes (id, body) values (?1, ?2)")
  for i = 11, 500 do
    ins(i, "the quick brown fox jumps over the lazy dog " .. i)
  end
  local n = dbb.getter("select count(*) as n from notes", "n")()
  assert(n == 500, "second connection saw " .. tostring(n) .. " rows, expected 500")
  ra:close_vm() ra:close()
  rb:close_vm() rb:close()
  sqlite.key_clear(p)
  rm(p)
end)

test("wal: a corrupted tail recovers instead of failing the open", function ()

  if not WAL_OK then return end
  local p = tmpname("waltear")
  rm(p)
  local raw = sqlite.open_encrypted(p, KEY_A)
  local db = sql(raw)
  db.exec("pragma journal_mode = wal")
  db.exec("pragma wal_autocheckpoint = 0")
  seed(db, 50)
  local ins = db.runner("insert into notes (id, body) values (?1, ?2)")
  for i = 51, 100 do
    ins(i, "the quick brown fox jumps over the lazy dog " .. i)
  end
  local snap_db, snap_wal = slurp(p), slurp(p .. "-wal")
  raw:close_vm() raw:close()
  assert(snap_wal ~= nil and #snap_wal > HDR + 2 * FRAME, "wal was empty before the tear")

  local cut = #snap_wal - num.floor(FRAME / 2)
  local byte = snap_wal:byte(cut)
  spit(p, snap_db or "")
  spit(p .. "-wal",
    snap_wal:sub(1, cut - 1) .. str.char((byte + 1) % 256) .. snap_wal:sub(cut + 1))
  fs.rm(p .. "-shm", true)
  local raw2 = sqlite.open_encrypted(p, KEY_A)
  assert(raw2 ~= nil, "torn wal tail made the database unopenable")
  local db2 = sql(raw2)
  local n = db2.getter("select count(*) as n from notes", "n")()
  assert(n >= 50, "recovery lost committed pre-tear data, got " .. tostring(n))
  assert(db2.getter("select body from notes where id = 7", "body")()
    == "the quick brown fox jumps over the lazy dog 7")
  raw2:close_vm() raw2:close()
  rm(p)
end)

test("read-modify-write of an existing frame also draws a fresh nonce", function ()

  local p = tmpname("rmwnonce")
  rm(p)
  local raw = sqlite.open_encrypted(p, KEY_A)
  local db = sql(raw)
  db.exec("pragma page_size = 512")
  seed(db, 50)
  raw:close_vm() raw:close()
  local n0 = frame_nonce(slurp(p), 0)

  local seen = { [n0] = true }
  for round = 1, 3 do
    local r = sqlite.open_encrypted(p, KEY_A)
    local d = sql(r)
    d.runner("update notes set body = ?2 where id = ?1")(1, "rmw round " .. round)
    r:close_vm() r:close()
    local n = frame_nonce(slurp(p), 0)
    assert(#n == 24)
    assert(not seen[n], "frame 0 nonce repeated across a read-modify-write")
    seen[n] = true
  end
  rm(p)
end)

local function snapshots_around_update (name)
  local p = tmpname(name)
  rm(p)
  local raw = sqlite.open_encrypted(p, KEY_A)
  seed(sql(raw), 20)
  raw:close_vm() raw:close()
  local before = slurp(p)
  local r2 = sqlite.open_encrypted(p, KEY_A)
  sql(r2).runner("update notes set body = ?2 where id = ?1")(1, "edited after snapshot")
  r2:close_vm() r2:close()
  local after = slurp(p)
  assert(#before >= DATA0 + FRAME and #after >= DATA0 + FRAME)
  return p, before, after
end

test("an earlier frame cannot be spliced back in (write counter in the AAD)", function ()
  local p, before, after = snapshots_around_update("rollpage")
  local old0 = before:sub(DATA0 + 1, DATA0 + FRAME)
  spit(p, after:sub(1, DATA0) .. old0 .. after:sub(DATA0 + FRAME + 1))
  local ok = pcall(function ()
    local r = sqlite.open_encrypted(p, KEY_A)
    if r == nil then error("open failed") end
    return sql(r).getter("select count(*) as n from notes", "n")()
  end)
  assert(ok == false, "a rolled-back page ciphertext must not be readable")
  rm(p)
end)

test("splicing the counter frame along with the page fails the root check", function ()
  local p, before, after = snapshots_around_update("rollctr")
  local oldc = before:sub(HDR + 1, HDR + FRAME)
  local old0 = before:sub(DATA0 + 1, DATA0 + FRAME)
  spit(p, after:sub(1, HDR) .. oldc .. old0 .. after:sub(DATA0 + FRAME + 1))
  local ok = pcall(function ()
    local r = sqlite.open_encrypted(p, KEY_A)
    if r == nil then error("open failed") end
    return sql(r).getter("select count(*) as n from notes", "n")()
  end)
  assert(ok == false, "a rolled-back counter frame must not verify against the root")
  rm(p)
end)

test("whole-file rollback to a consistent snapshot still opens (documented residual)", function ()
  local p, before = snapshots_around_update("rollfull")
  spit(p, before)
  local r = sqlite.open_encrypted(p, KEY_A)
  assert(r ~= nil)
  local db = sql(r)
  assert(db.getter("select count(*) as n from notes", "n")() == 20)
  assert(db.getter("select body from notes where id = 1", "body")()
    == "the quick brown fox jumps over the lazy dog 1")
  r:close_vm() r:close()
  rm(p)
end)

test("a version-1 container is rejected", function ()
  local p = tmpname("v1rej")
  rm(p)
  local raw = sqlite.open_encrypted(p, KEY_A)
  seed(sql(raw), 5)
  raw:close_vm() raw:close()
  local blob = slurp(p)
  spit(p, blob:sub(1, 8) .. str.char(1) .. blob:sub(10))
  local ok = pcall(function ()
    local r = sqlite.open_encrypted(p, KEY_A)
    if r == nil then error("open failed") end
    return sql(r).getter("select count(*) as n from notes", "n")()
  end)
  assert(ok == false, "a v1-version header must not open")
  rm(p)
end)
