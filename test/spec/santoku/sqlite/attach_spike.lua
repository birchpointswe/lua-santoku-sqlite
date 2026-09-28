local test = require("santoku.test")

local err = require("santoku.error")
local assert = err.assert
local pcall = err.pcall

local sqlite = require("santoku.sqlite.db")
local sql = require("santoku.sqlite")
local str = require("santoku.string")
local arr = require("santoku.array")
local fs = require("santoku.fs")

local KEY_A = str.rep("A", 32)
local KEY_B = str.rep("B", 32)

local BUILD = sqlite.wasm and "wasm" or "native"

local PARENTS = {
  { label = "unix" },
  { label = "unix-none", parent = "unix-none" },
}

local DDL = [[
  create table records (id text primary key, idx text not null, body text);
  create index records_idx on records (idx);
]]

local seq = 0

local function tmpname (n)
  seq = seq + 1
  return "tk-att-" .. n .. "-" .. tostring(seq) .. ".db"
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

local function spit (p, s)
  fs.writefile(p, s, "wb")
end

local function say (...)
  local parts = { BUILD }
  for i = 1, select("#", ...) do
    parts[#parts + 1] = tostring((select(i, ...)))
  end
  str.printf("SPIKE %s\n", arr.concat(parts, " | "))
end

local function try (fn)
  local r = { pcall(fn) }
  if r[1] then
    return true, r[2]
  end
  return false, tostring(r[2]) .. " (" .. tostring(r[3]) .. ")"
end

local function open (p, key, parent)
  local ok, e = sqlite.key_set(p, key, parent)
  assert(ok == true, e)
  local raw, eo = sqlite.open_encrypted(p, key, parent)
  assert(raw ~= nil, eo)
  local d = sql(raw)
  d.exec("pragma journal_mode = TRUNCATE")
  d.exec("pragma synchronous = NORMAL")
  d.exec("pragma temp_store = MEMORY")
  return d
end

local function close (d, p, parent)
  d.close()
  sqlite.key_clear(p, parent)
end

local function one (d, q, ...)
  local rows = d.query(q, ...)
  return rows[1] and rows[1][1]
end

local function count (d, t)
  return one(d, "select count(*) from " .. t)
end

local function integrity (d, schema)
  local rows = d.query("pragma " .. schema .. ".integrity_check")
  local out = {}
  for i = 1, #rows do out[#out + 1] = tostring(rows[i][1]) end
  return arr.concat(out, "; ")
end

local function probe (fn)
  local ok, v = try(fn)
  if ok then return v end
  return "ERR " .. v
end

local function fill (d, t, from, to, tag, pad)
  local ins = d.runner("insert into " .. t .. " (id, idx, body) values (?1, ?2, ?3)")
  d.transaction(function ()
    for i = from, to do
      ins(tag .. i, str.format("%s-%08d", tag, i), "body " .. tag .. " " .. i .. (pad or ""))
    end
  end)
end

local function pair (label, parent)
  local pa, pb = tmpname("a-" .. label), tmpname("b-" .. label)
  rm(pa) rm(pb)
  local db = open(pb, KEY_B, parent)
  db.exec(DDL)
  local da = open(pa, KEY_A, parent)
  da.exec(DDL)
  da.exec("attach database '" .. pb .. "' as m")
  return da, db, pa, pb
end

local function unpair (da, db, pa, pb, parent)
  pcall(function () da.exec("detach database m") end)
  close(da, pa, parent)
  close(db, pb, parent)
  rm(pa) rm(pb)
end

test("q1: attach a differently keyed encrypted file", function ()
  for _, P in ipairs(PARENTS) do
    local pa, pb = tmpname("q1a"), tmpname("q1b")
    rm(pa) rm(pb)
    local db = open(pb, KEY_B, P.parent)
    db.exec(DDL)
    fill(db, "records", 1, 5, "b")
    close(db, pb, P.parent)
    local da = open(pa, KEY_A, P.parent)
    local ok0, e0 = try(function () da.exec("attach database '" .. pb .. "' as m") end)
    say("q1", P.label, "attach with no key registered", ok0, e0)
    assert(ok0 == false)
    assert(sqlite.key_set(pb, KEY_B, P.parent) == true)
    da.exec("attach database '" .. pb .. "' as m")
    local n = count(da, "m.records")
    say("q1", P.label, "plain path attach count", n)
    assert(n == 5)
    da.exec("detach database m")
    local okd, ed = try(function ()
      da.exec("attach database './" .. pb .. "' as m")
      return count(da, "m.records")
    end)
    say("q1", P.label, "dot-slash path attach", okd, ed)
    pcall(function () da.exec("detach database m") end)
    local oku, eu = try(function ()
      da.exec("attach database 'file:" .. pb .. "?mode=ro' as m")
      return count(da, "m.records")
    end)
    say("q1", P.label, "uri attach", oku, eu)
    pcall(function () da.exec("detach database m") end)
    sqlite.key_clear(pb, P.parent)
    close(da, pa, P.parent)
    rm(pa) rm(pb) rm("file:" .. pb .. "?mode=ro")
  end
end)

test("q2: visibility and integrity with the file on two connections", function ()
  for _, P in ipairs(PARENTS) do
    local da, db, pa, pb = pair("q2v", P.parent)
    fill(db, "records", 1, 50, "b")
    assert(count(da, "m.records") == 50, "attach did not see sheet-connection writes")
    fill(da, "m.records", 1, 30, "a")
    assert(count(db, "records") == 80, "sheet connection did not see attach writes")
    db.query("update records set body = 'changed-by-b' where id = 'b7'")
    assert(one(da, "select body from m.records where id = 'b7'") == "changed-by-b")
    da.query("update m.records set body = 'changed-by-a' where id = 'b8'")
    assert(one(db, "select body from records where id = 'b8'") == "changed-by-a")
    local expect = 80
    local mismatch = 0
    for i = 1, 300 do
      if i % 3 == 0 then
        db.query("insert into records (id, idx, body) values (?1, ?2, ?3)",
          "x" .. i, str.format("x-%08d", i), "from b " .. i)
        expect = expect + 1
      elseif i % 3 == 1 then
        da.query("insert into m.records (id, idx, body) values (?1, ?2, ?3)",
          "y" .. i, str.format("y-%08d", i), "from a " .. i)
        expect = expect + 1
      else
        da.query("update m.records set body = body || '.' where idx < ?1", str.format("b-%08d", i % 50))
        db.query("delete from records where id = ?1", "y" .. (i - 1))
        expect = expect - 1
      end
      if count(da, "m.records") ~= expect or count(db, "records") ~= expect then
        mismatch = mismatch + 1
      end
    end
    local ia, ib, im = integrity(da, "main"), integrity(db, "main"), integrity(da, "m")
    say("q2v", P.label, "mismatches", mismatch, "expect", expect,
      "integrity a.main", ia, "b", ib, "a.m", im)
    assert(mismatch == 0)
    assert(ia == "ok" and ib == "ok" and im == "ok")
    da.exec("detach database m")
    close(db, pb, P.parent)
    local dc = open(pb, KEY_B, P.parent)
    local nc, ic = count(dc, "records"), integrity(dc, "main")
    say("q2v", P.label, "cold reopen count", nc, "integrity", ic)
    assert(nc == expect and ic == "ok")
    close(dc, pb, P.parent)
    close(da, pa, P.parent)
    rm(pa) rm(pb)
  end
end)

test("q2: locking between the sheet connection and the attach", function ()
  for _, P in ipairs(PARENTS) do
    local native = P.parent == nil

    local da, db, pa, pb = pair("q2l", P.parent)
    fill(db, "records", 1, 20, "b")

    db.begin("immediate")
    db.query("insert into records (id, idx, body) values ('u1', 'u-1', 'uncommitted')")
    local okw, ew = try(function ()
      da.query("insert into m.records (id, idx, body) values ('w1', 'w-1', 'attach write')")
    end)
    local okr, er = try(function () return count(da, "m.records") end)
    local okc, ec = try(function () db.commit() end)
    if not okc then pcall(function () db.rollback() end) end
    local fb = probe(function () return count(db, "records") end)
    local fa = probe(function () return count(da, "m.records") end)
    local survivors = probe(function ()
      return one(db, "select group_concat(id) from records where id in ('u1', 'w1')")
    end)
    local ib = probe(function () return integrity(db, "main") end)
    local im = probe(function () return integrity(da, "m") end)
    say("q2l-a", P.label, "attach write during sheet write txn", okw, ew,
      "attach read", okr, er, "sheet commit", okc, ec,
      "final b", fb, "final a.m", fa, "survivors", survivors, "integrity b", ib, "a.m", im)
    if native then
      assert(okw == false, "attach write must be blocked while the sheet holds RESERVED")
      assert(okr == true and er == 20, "attach read should see the committed 20 rows")
      assert(okc == true and fb == 21 and fa == 21)
    end

    local okg, eg
    db.begin("immediate")
    okg, eg = try(function () return da.getter("select count(*) as n from main.records", "n")() end)
    pcall(function () db.rollback() end)
    say("q2l-d", P.label, "wrapper getter (begin immediate) during sheet write txn", okg, eg)
    if native then assert(okg == false) end

    unpair(da, db, pa, pb, P.parent)

    da, db, pa, pb = pair("q2s", P.parent)
    local pad = str.rep("z", 600)
    fill(db, "records", 1, 1500, "b", pad)
    db.exec("pragma cache_size = 16")
    db.begin("immediate")
    db.query("update records set body = 'DIRTY-' || id || ?1", pad)
    local jb = slurp(pb .. "-journal")
    local oks, es = try(function ()
      return one(da, "select body from m.records where id = 'b7'")
    end)
    local okc2, ec2 = try(function () db.commit() end)
    if not okc2 then pcall(function () db.rollback() end) end
    local dirty = probe(function ()
      return one(db, "select count(*) from records where body like 'DIRTY-%'")
    end)
    local ib2 = probe(function () return integrity(db, "main") end)
    local im2 = probe(function () return integrity(da, "m") end)
    local seen = oks and str.sub(tostring(es), 1, 12) or es
    say("q2l-b", P.label, "journal bytes mid-txn", jb and #jb or "none",
      "attach read during spilled write", oks, seen,
      "sheet commit", okc2, ec2, "dirty rows after", dirty,
      "integrity b", ib2, "a.m", im2)
    if native then
      assert(oks == false, "attach read must be blocked while the sheet holds EXCLUSIVE")
      assert(okc2 == true and dirty == 1500 and ib2 == "ok" and im2 == "ok")
    end
    pcall(function () da.exec("detach database m") end)
    close(db, pb, P.parent)
    local okcold, ecold = try(function ()
      local dc = open(pb, KEY_B, P.parent)
      local r = integrity(dc, "main") .. " rows " .. tostring(count(dc, "records")) ..
        " dirty " .. tostring(one(dc, "select count(*) from records where body like 'DIRTY-%'"))
      close(dc, pb, P.parent)
      return r
    end)
    say("q2l-b", P.label, "cold reopen after spilled overlap", okcold, ecold)
    close(da, pa, P.parent)
    rm(pa) rm(pb)

    da, db, pa, pb = pair("q2c", P.parent)
    fill(db, "records", 1, 1500, "b", pad)
    local stmt = da.db:prepare("select id, body from m.records order by idx")
    local got = 0
    for _ = 1, 3 do
      if stmt:step() == 100 then got = got + 1 end
    end
    local okc3, ec3 = try(function ()
      db.query("update records set body = 'NEW-' || id || ?1", pad)
    end)
    local rest, stale, fresh = 0, 0, 0
    local rc
    while true do
      rc = stmt:step()
      if rc ~= 100 then break end
      rest = rest + 1
      local body = tostring(stmt:get_value(1))
      if str.sub(body, 1, 4) == "NEW-" then fresh = fresh + 1 else stale = stale + 1 end
    end
    stmt:reset()
    local ib3 = probe(function () return integrity(db, "main") end)
    local im3 = probe(function () return integrity(da, "m") end)
    say("q2l-c", P.label, "sheet write while attach cursor open", okc3, ec3,
      "cursor rows after", got + rest, "final rc", rc, "stale", stale, "fresh", fresh,
      "integrity b", ib3, "a.m", im3)
    if native then
      assert(okc3 == false, "sheet write must be blocked while the attach cursor holds SHARED")
      assert(got + rest == 1500 and rc == 101)
    end
    unpair(da, db, pa, pb, P.parent)
  end
end)

test("q3: read-only attach", function ()
  local da, db, pa, pb = pair("q3", nil)
  fill(db, "records", 1, 5, "b")
  da.exec("detach database m")
  local oku, eu = try(function ()
    da.exec("attach database 'file:" .. pb .. "?mode=ro' as r")
    return count(da, "r.records")
  end)
  say("q3", "uri mode=ro attach", oku, eu)
  pcall(function () da.exec("detach database r") end)
  rm("file:" .. pb .. "?mode=ro")
  da.exec("attach database '" .. pb .. "' as m")
  da.exec("pragma query_only = 1")
  local okw, ew = try(function ()
    da.query("insert into m.records (id, idx, body) values ('q', 'q', 'q')")
  end)
  local okm, em = try(function ()
    da.query("insert into main.records (id, idx, body) values ('q', 'q', 'q')")
  end)
  local okr, er = try(function () return count(da, "m.records") end)
  say("q3", "query_only: write m", okw, ew, "write main", okm, em, "read m", okr, er)
  da.exec("pragma query_only = 0")
  unpair(da, db, pa, pb, nil)
end)

test("q4: journal written through the attach stays encrypted", function ()
  local da, db, pa, pb = pair("q4", nil)
  local pad = str.rep("z", 600)
  fill(db, "records", 1, 1500, "clean", pad)
  da.exec("pragma m.cache_size = 16")
  local snap_db, snap_j
  local ok = pcall(function ()
    return da.transaction(function ()
      da.query("update m.records set body = 'SENTINELPLAINTEXT-' || id || ?1", pad)
      snap_db = slurp(pb)
      snap_j = slurp(pb .. "-journal")
      error("abort")
    end)
  end)
  assert(ok == false)
  local restored = one(da, "select count(*) from m.records where body like 'body clean%'")
  say("q4", "journal bytes", snap_j and #snap_j or "none",
    "magic", snap_j and str.sub(snap_j, 1, 8),
    "plaintext in journal", snap_j and (str.find(snap_j, "body clean", 1, true) ~= nil),
    "sentinel in journal", snap_j and (str.find(snap_j, "SENTINELPLAINTEXT", 1, true) ~= nil),
    "rows restored after rollback", restored)
  assert(snap_j ~= nil and #snap_j > 0, "no journal mid-transaction")
  assert(str.sub(snap_j, 1, 8) == "TKSQENC1", "journal is not in the encrypted container")
  assert(not str.find(snap_j, "body clean", 1, true))
  assert(not str.find(snap_j, "SENTINELPLAINTEXT", 1, true))
  assert(not str.find(snap_db, "SENTINELPLAINTEXT", 1, true))
  assert(restored == 1500)
  unpair(da, db, pa, pb, nil)
  local pj = tmpname("q4hot")
  rm(pj)
  spit(pj, snap_db)
  spit(pj .. "-journal", snap_j)
  local dj = open(pj, KEY_B, nil)
  local clean = one(dj, "select count(*) from records where body like 'body clean%'")
  local ij = integrity(dj, "main")
  say("q4", "cold open of attach-written hot journal: clean rows", clean, "integrity", ij)
  assert(clean == 1500 and ij == "ok")
  close(dj, pj, nil)
  rm(pj)
end)

test("q5: query plan for a keyset-paged union all", function ()
  local da, db, pa, pb = pair("q5", nil)
  fill(da, "main.records", 1, 400, "a")
  fill(db, "records", 1, 400, "b")
  local plans = {
    compound = "select id, idx from main.records where idx > ?1 union all " ..
      "select id, idx from m.records where idx > ?1 order by idx limit ?2",
    compound_body = "select id, idx, body from main.records where idx > ?1 union all " ..
      "select id, idx, body from m.records where idx > ?1 order by idx limit ?2",
    subquery = "select id, idx, body from (select id, idx, body from main.records union all " ..
      "select id, idx, body from m.records) where idx > ?1 order by idx limit ?2",
  }
  local sorted = {}
  for _, name in ipairs({ "compound", "compound_body", "subquery" }) do
    local rows = da.query("explain query plan " .. plans[name], "", 50)
    local lines = {}
    for i = 1, #rows do lines[#lines + 1] = tostring(rows[i][4]) end
    local plan = arr.concat(lines, " / ")
    sorted[name] = str.find(plan, "TEMP B-TREE", 1, true) ~= nil
    say("q5", name, plan)
    local seen, cursor, pages, ordered = 0, "", 0, true
    while true do
      local page = da.query(plans[name], cursor, 50)
      if #page == 0 then break end
      pages = pages + 1
      for i = 1, #page do
        if page[i][2] <= cursor then ordered = false end
        cursor = page[i][2]
      end
      seen = seen + #page
    end
    say("q5", name, "rows paged", seen, "pages", pages, "ordered", ordered)
    assert(seen == 800 and ordered)
  end
  assert(not sorted.compound, "compound union all fell back to a temp b-tree sort")
  assert(not sorted.compound_body, "compound union all with body fell back to a temp b-tree sort")
  unpair(da, db, pa, pb, nil)
end)

test("q6: limits, per-schema pragmas, detach, key lifetime", function ()
  local da, db, pa, pb = pair("q6", nil)
  fill(db, "records", 1, 10, "b")
  say("q6", "after attach: m.journal_mode", one(da, "pragma m.journal_mode"),
    "m.synchronous", one(da, "pragma m.synchronous"),
    "main.journal_mode", one(da, "pragma main.journal_mode"),
    "main.synchronous", one(da, "pragma main.synchronous"),
    "temp_store", one(da, "pragma temp_store"))
  da.exec("pragma journal_mode = TRUNCATE")
  say("q6", "after unqualified journal_mode: m.journal_mode", one(da, "pragma m.journal_mode"))

  local n, first_fail = 0, nil
  for i = 1, 12 do
    local ok, e = try(function () da.exec("attach database ':memory:' as x" .. i) end)
    if ok then n = n + 1 elseif not first_fail then first_fail = e end
  end
  say("q6", "extra :memory: attaches accepted beside m", n, "first failure", first_fail)
  for i = 1, 12 do pcall(function () da.exec("detach database x" .. i) end) end

  local stmt = da.db:prepare("select id from m.records")
  stmt:step()
  local okd, ed = try(function () da.exec("detach database m") end)
  say("q6", "detach with open statement", okd, ed)
  assert(okd == false)
  stmt:reset()
  local okd2, ed2 = try(function () da.exec("detach database m") end)
  say("q6", "detach after reset", okd2, ed2)
  assert(okd2 == true)

  da.exec("attach database '" .. pb .. "' as m")
  close(db, pb, nil)
  local okr, er = try(function () return count(da, "m.records") end)
  local okw, ew = try(function ()
    da.query("insert into m.records (id, idx, body) values ('late', 'late', 'late')")
  end)
  say("q6", "sheet closed and key cleared: attach read", okr, er, "attach write", okw, ew)
  pcall(function () da.exec("detach database m") end)
  assert(sqlite.key_set(pb, KEY_B) == true)
  da.exec("attach database '" .. pb .. "' as m")
  local db2 = open(pb, KEY_B, nil)
  close(db2, pb, nil)
  local okr2, er2 = try(function () return count(da, "m.records") end)
  local okw2, ew2 = try(function ()
    da.query("insert into m.records (id, idx, body) values ('late', 'late', 'late')")
    return count(da, "m.records")
  end)
  say("q6", "sheet closed, attach side holds its own key_set: attach read", okr2, er2,
    "attach write", okw2, ew2)
  assert(okr2 == true and okw2 == true)
  pcall(function () da.exec("detach database m") end)
  sqlite.key_clear(pb)
  close(da, pa, nil)
  rm(pa) rm(pb)
end)
