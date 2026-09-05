local err = require("santoku.error")
local arr = require("santoku.array")
local error = err.error
local assert = err.assert
local pcall = err.pcall

local PROTO = 1
local BUCKETS = 256
local MOD = 2147483648

local NOW = "cast(round(unixepoch('now', 'subsec') * 1000) as integer)"
local HLCX = "printf('%014d', pt) || '.' || printf('%08x', c) || '.' || lower(hex(randomblob(8)))"

local RESERVED = { rid = true, hlc = true, seq = true, del = true }

local function valid_name (s)
  return type(s) == "string" and s:match("^[%a_][%w_]*$") ~= nil
end

local function strhash (s)
  local h = 5381
  for i = 1, #s do
    h = (h * 131 + s:byte(i)) % MOD
  end
  return h
end

local function hlc_parse (h)
  if type(h) ~= "string" then return nil end
  local pt, c = h:match("^(%d%d%d%d%d%d%d%d%d%d%d%d%d%d)%.(%x%x%x%x%x%x%x%x)%.%x+$")
  if not pt then return nil end
  return tonumber(pt), tonumber(c, 16)
end

local function wins (rhlc, rdel, lhlc, ldel)
  if lhlc == nil then return true end
  if rhlc > lhlc then return true end
  if rhlc == lhlc and rdel and not ldel then return true end
  return false
end

local function create (db, opts)

  assert(type(opts) == "table", "sync.create: opts table required")

  local prefix = opts.prefix or "sync"
  assert(valid_name(prefix), "sync.create: opts.prefix must be a valid identifier")

  local schema = opts.schema
  if schema ~= nil then
    assert(valid_name(schema), "sync.create: opts.schema must be a valid identifier")
  end

  local space = opts.space or ""
  assert(type(space) == "string", "sync.create: opts.space must be a string")

  local batch = opts.batch or 500
  assert(type(batch) == "number" and batch > 0, "sync.create: opts.batch must be a positive number")

  local max_skew = opts.max_skew or 86400000
  assert(type(max_skew) == "number" and max_skew > 0, "sync.create: opts.max_skew must be positive")

  local hash = opts.hash or strhash
  assert(type(hash) == "function", "sync.create: opts.hash must be a function")

  local aad = opts.aad
  if aad ~= nil then
    assert(type(aad) == "function", "sync.create: opts.aad must be a function")
  else
    aad = function (sp, tbl, rid, hlc)
      return sp .. ":" .. tbl .. ":" .. rid .. ":" .. hlc
    end
  end

  local on_codec_error = opts.on_codec_error or "abort"
  assert(on_codec_error == "abort" or on_codec_error == "quarantine",
    "sync.create: opts.on_codec_error must be abort or quarantine")

  local codec, encode, decode = opts.codec, opts.encode, opts.decode
  if codec ~= nil then
    assert(type(codec) == "table" and type(codec.enc) == "function" and type(codec.dec) == "function",
      "sync.create: opts.codec must have enc and dec functions")
    assert(type(encode) == "function" and type(decode) == "function",
      "sync.create: opts.codec requires opts.encode and opts.decode")
  end

  assert(type(opts.tables) == "table" and next(opts.tables) ~= nil,
    "sync.create: opts.tables must be a non-empty table")

  local names, specs, versions = {}, {}, {}

  for name, spec in pairs(opts.tables) do
    assert(valid_name(name), "sync.create: table name must be a valid identifier")
    assert(type(spec) == "table", "sync.create: table spec must be a table: " .. name)
    local pk = spec.pk
    assert(type(pk) == "table" and #pk > 0, "sync.create: " .. name .. " needs a non-empty pk")
    local cols = spec.columns
    assert(type(cols) == "table" and #cols > 0, "sync.create: " .. name .. " needs non-empty columns")
    local gran = spec.granularity or "row"
    assert(gran == "row" or gran == "column",
      "sync.create: " .. name .. " granularity must be row or column")
    local version = spec.version or 1
    assert(type(version) == "number" and version >= 1,
      "sync.create: " .. name .. " version must be >= 1")
    local seen = {}
    for _, c in ipairs(pk) do
      assert(valid_name(c), "sync.create: " .. name .. " pk column must be a valid identifier")
      assert(not RESERVED[c], "sync.create: " .. name .. " column name is reserved: " .. c)
      assert(not seen[c], "sync.create: " .. name .. " duplicate column: " .. c)
      seen[c] = true
    end
    for _, c in ipairs(cols) do
      assert(valid_name(c), "sync.create: " .. name .. " column must be a valid identifier")
      assert(not RESERVED[c], "sync.create: " .. name .. " column name is reserved: " .. c)
      assert(not seen[c], "sync.create: " .. name .. " column repeats a pk column: " .. c)
      seen[c] = true
    end
    local blob = {}
    for _, c in ipairs(spec.blobs or {}) do
      local found = false
      for _, d in ipairs(cols) do
        if c == d then found = true end
      end
      assert(found, "sync.create: " .. name .. " blob column not in columns: " .. tostring(c))
      blob[c] = true
    end
    local after_apply = spec.after_apply
    assert(after_apply == nil or type(after_apply) == "function",
      "sync.create: " .. name .. " after_apply must be a function")
    local seed = spec.seed
    if seed ~= nil then
      assert(valid_name(seed),
        "sync.create: " .. name .. " seed must be a valid identifier")
      for _, c in ipairs(pk) do
        assert(seed ~= c,
          "sync.create: " .. name .. " seed cannot be a pk column: " .. seed)
      end
    end
    specs[name] = { pk = pk, columns = cols, granularity = gran, blob = blob,
      version = version, after_apply = after_apply, seed = seed }
    versions[name] = version
    names[#names + 1] = name
  end

  arr.sort(names)

  local q = schema and (schema .. ".") or ""
  local meta = q .. prefix .. "_meta"
  local peers_tbl = q .. prefix .. "_peer"

  local function shadow_of (name) return q .. name .. "_" .. prefix end
  local function colshadow_of (name) return q .. name .. "_" .. prefix .. "_col" end
  local function base_of (name) return q .. name end

  local function rid_expr (name, alias)
    local parts = {}
    for i, c in ipairs(specs[name].pk) do
      parts[i] = alias and (alias .. "." .. c) or c
    end
    return "json_array(" .. arr.concat(parts, ", ") .. ")"
  end

  db.exec(
    "create table if not exists " .. meta .. " (" ..
    "id integer primary key check (id = 1), " ..
    "replica text not null, seq integer not null default 0, " ..
    "applying integer not null default 0, pt integer not null default 0, " ..
    "c integer not null default 0, gc_hlc text, " ..
    "gc_seq integer not null default 0);" ..
    "insert or ignore into " .. meta .. " (id, replica) values (1, lower(hex(randomblob(16))));" ..
    "create table if not exists " .. peers_tbl .. " (" ..
    "peer text primary key, cursor integer not null default 0, " ..
    "served integer not null default 0);")

  local stamp =
    "update " .. meta .. " set seq = seq + 1, " ..
    "c = case when " .. NOW .. " > pt then 0 else c + 1 end, " ..
    "pt = max(pt, " .. NOW .. ") where id = 1;"

  local guard = "when (select applying from " .. meta .. " where id = 1) = 0"

  for _, name in ipairs(names) do
    local spec = specs[name]
    local shadow = shadow_of(name)
    local colshadow = colshadow_of(name)
    local rnew = rid_expr(name, "new")
    local rold = rid_expr(name, "old")
    local column = spec.granularity == "column"

    local ddl =
      "create table if not exists " .. shadow .. " (" ..
      "rid text primary key, hlc text not null, seq integer not null, " ..
      "del integer not null default 0);" ..
      "create index if not exists " .. q .. name .. "_" .. prefix .. "_seq on " ..
      name .. "_" .. prefix .. " (seq);" ..
      "create index if not exists " .. q .. name .. "_" .. prefix .. "_rid on " ..
      name .. " (" .. rid_expr(name) .. ");"
    if column then
      ddl = ddl ..
        "create table if not exists " .. colshadow .. " (" ..
        "rid text not null, col text not null, hlc text not null, " ..
        "primary key (rid, col));"
    end
    db.exec(ddl)

    local watch = {}
    for _, c in ipairs(spec.pk) do watch[#watch + 1] = c end
    for _, c in ipairs(spec.columns) do watch[#watch + 1] = c end

    local function upsert_row (rid, del)
      return
        "insert into " .. shadow .. " (rid, hlc, seq, del) " ..
        "select " .. rid .. ", " .. HLCX .. ", seq, " .. del .. " from " .. meta .. " where id = 1 " ..
        "on conflict (rid) do update set hlc = excluded.hlc, seq = excluded.seq, del = excluded.del;"
    end

    local ins_body = stamp .. upsert_row(rnew, 0)
    if column then
      ins_body = ins_body .. "delete from " .. colshadow .. " where rid = " .. rnew .. ";"
      for _, c in ipairs(spec.columns) do
        ins_body = ins_body ..
          "insert into " .. colshadow .. " (rid, col, hlc) " ..
          "select " .. rnew .. ", '" .. c .. "', " .. HLCX .. " from " .. meta .. " where id = 1 " ..
          "on conflict (rid, col) do update set hlc = excluded.hlc;"
      end
    end

    local upd_body = stamp ..
      "insert into " .. shadow .. " (rid, hlc, seq, del) " ..
      "select " .. rold .. ", " .. HLCX .. ", seq, 1 from " .. meta .. " " ..
      "where id = 1 and " .. rold .. " is not " .. rnew .. " " ..
      "on conflict (rid) do update set hlc = excluded.hlc, seq = excluded.seq, del = 1;"
    if column then
      upd_body = upd_body ..
        "delete from " .. colshadow .. " where rid = " .. rold ..
        " and " .. rold .. " is not " .. rnew .. ";"
    end
    upd_body = upd_body .. upsert_row(rnew, 0)
    if column then
      for _, c in ipairs(spec.columns) do
        upd_body = upd_body ..
          "insert into " .. colshadow .. " (rid, col, hlc) " ..
          "select " .. rnew .. ", '" .. c .. "', " .. HLCX .. " from " .. meta .. " " ..
          "where id = 1 and new." .. c .. " is not old." .. c .. " " ..
          "on conflict (rid, col) do update set hlc = excluded.hlc;"
      end
    end

    local del_body = stamp .. upsert_row(rold, 1)
    if column then
      del_body = del_body .. "delete from " .. colshadow .. " where rid = " .. rold .. ";"
    end

    db.exec(
      "drop trigger if exists " .. q .. name .. "_" .. prefix .. "_ai;" ..
      "create trigger " .. q .. name .. "_" .. prefix .. "_ai after insert on " .. name .. " " ..
      guard .. " begin " .. ins_body .. " end;" ..
      "drop trigger if exists " .. q .. name .. "_" .. prefix .. "_au;" ..
      "create trigger " .. q .. name .. "_" .. prefix .. "_au after update of " ..
      arr.concat(watch, ", ") .. " on " .. name .. " " ..
      guard .. " begin " .. upd_body .. " end;" ..
      "drop trigger if exists " .. q .. name .. "_" .. prefix .. "_ad;" ..
      "create trigger " .. q .. name .. "_" .. prefix .. "_ad after delete on " .. name .. " " ..
      guard .. " begin " .. del_body .. " end;")
  end

  local get_replica = db.getter("select replica from " .. meta .. " where id = 1")
  local get_seq = db.getter("select seq from " .. meta .. " where id = 1")
  local get_gc_seq = db.getter("select gc_seq from " .. meta .. " where id = 1")
  local set_gc = db.runner(
    "update " .. meta .. " set gc_hlc = ?1, gc_seq = seq where id = 1")
  local enter_quiet = db.runner(
    "update " .. meta .. " set applying = applying + 1 where id = 1")
  local exit_quiet = db.runner(
    "update " .. meta .. " set applying = max(0, applying - 1) where id = 1")
  local bump_clock = db.runner(
    "update " .. meta .. " set " ..
    "c = case when " .. NOW .. " > pt then 0 else c + 1 end, " ..
    "pt = max(pt, " .. NOW .. ") where id = 1")
  local next_seq = db.getter(
    "update " .. meta .. " set seq = seq + 1 where id = 1 returning seq")
  local ratchet = db.runner(
    "update " .. meta .. " set " ..
    "c = case when ?1 > pt then ?2 when ?1 = pt and ?2 > c then ?2 else c end, " ..
    "pt = max(pt, ?1) where id = 1 and ?1 <= " .. NOW .. " + " .. max_skew)
  local now_ms = db.getter("select " .. NOW)

  local get_cursor = db.getter("select cursor from " .. peers_tbl .. " where peer = ?1")
  local get_served = db.getter("select served from " .. peers_tbl .. " where peer = ?1")
  local set_cursor = db.runner(
    "insert into " .. peers_tbl .. " (peer, cursor) values (?1, ?2) " ..
    "on conflict (peer) do update set cursor = max(cursor, excluded.cursor)")
  local set_served = db.runner(
    "insert into " .. peers_tbl .. " (peer, served) values (?1, ?2) " ..
    "on conflict (peer) do update set served = max(served, excluded.served)")
  local del_peer = db.runner("delete from " .. peers_tbl .. " where peer = ?1")
  local list_peers = db.all("select peer, cursor, served from " .. peers_tbl .. " order by peer", true)

  local T = {}

  for _, name in ipairs(names) do
    local spec = specs[name]
    local shadow = shadow_of(name)
    local colshadow = colshadow_of(name)
    local base = base_of(name)
    local column = spec.granularity == "column"
    local rid_t = rid_expr(name)
    local rid_q = rid_expr(name, name)

    local minted_hlc =
      "(select printf('%014d', pt) || '.' || printf('%08x', c) from " .. meta ..
      " where id = 1) || '.' || lower(hex(randomblob(8)))"
    if spec.seed then
      minted_hlc = "coalesce(nullif(" .. name .. "." .. spec.seed .. ", ''), " ..
        minted_hlc .. ")"
    end

    local sel = {}
    local all_cols = {}
    for _, c in ipairs(spec.pk) do all_cols[#all_cols + 1] = c end
    for _, c in ipairs(spec.columns) do all_cols[#all_cols + 1] = c end
    for i, c in ipairs(all_cols) do
      sel[i] = spec.blob[c] and ("hex(b." .. c .. ") as " .. c) or ("b." .. c .. " as " .. c)
    end

    local enum_live = db.all(
      "select s.rid as rid, s.hlc as hlc, s.seq as seq, 0 as del, " ..
      arr.concat(sel, ", ") ..
      " from " .. shadow .. " s join " .. base .. " b on " ..
      rid_expr(name, "b") .. " = s.rid " ..
      "where s.del = 0 and s.seq > ?1 order by s.seq limit ?2", true)

    local enum_dead = db.all(
      "select rid, hlc, seq, 1 as del from " .. shadow ..
      " where del = 1 and seq > ?1 order by seq limit ?2", true)

    local function enum (from, lim)
      local out = enum_live(from, lim)
      for _, r in ipairs(enum_dead(from, lim)) do
        out[#out + 1] = r
      end
      arr.sort(out, function (a, b) return a.seq < b.seq end)
      if #out > lim then
        local cut = {}
        for i = 1, lim do cut[i] = out[i] end
        return cut
      end
      return out
    end

    local fetch_live = db.all(
      "select s.rid as rid, s.hlc as hlc, s.seq as seq, 0 as del, " ..
      arr.concat(sel, ", ") ..
      " from " .. shadow .. " s join " .. base .. " b on " ..
      rid_expr(name, "b") .. " = s.rid where s.rid = ?1 and s.del = 0", true)

    local fetch_dead = db.all(
      "select rid, hlc, seq, 1 as del from " .. shadow ..
      " where rid = ?1 and del = 1", true)

    local function fetch_one (rid)
      local out = fetch_live(rid)
      if #out > 0 then return out end
      return fetch_dead(rid)
    end

    local ph, setters = {}, {}
    for i, c in ipairs(all_cols) do
      ph[i] = spec.blob[c] and ("unhex(:" .. c .. ")") or (":" .. c)
    end
    for _, c in ipairs(spec.columns) do
      setters[#setters + 1] = c .. " = excluded." .. c
    end

    local upsert_base = db.runner(
      "insert into " .. base .. " (" .. arr.concat(all_cols, ", ") .. ") values (" ..
      arr.concat(ph, ", ") .. ") on conflict (" .. arr.concat(spec.pk, ", ") ..
      ") do update set " .. arr.concat(setters, ", "))

    local col_set = {}
    if column then
      for _, c in ipairs(spec.columns) do
        col_set[c] = db.runner(
          "update " .. base .. " set " .. c .. " = " ..
          (spec.blob[c] and "unhex(?1)" or "?1") .. " where " .. rid_t .. " = ?2")
      end
    end

    T[name] = {
      spec = spec,
      column = column,
      all_cols = all_cols,
      enum = enum,
      fetch_one = fetch_one,
      upsert_base = upsert_base,
      col_set = col_set,
      del_base = db.runner("delete from " .. base .. " where " .. rid_t .. " = ?1"),
      get_shadow = db.getter("select hlc, del from " .. shadow .. " where rid = ?1", true),
      put_shadow = db.runner(
        "insert into " .. shadow .. " (rid, hlc, seq, del) values (?1, ?2, ?3, ?4) " ..
        "on conflict (rid) do update set hlc = excluded.hlc, seq = excluded.seq, del = excluded.del"),
      scan_shadow = db.all("select rid, hlc, del from " .. shadow, true),
      gc_del = db.runner("delete from " .. shadow .. " where del = 1 and hlc < ?1"),
      gc_count = db.getter(
        "select count(*) from " .. shadow .. " where del = 1 and hlc < ?1"),
      seq_catchup = db.runner(
        "update " .. meta .. " set seq = max(seq, " ..
        "(select coalesce(max(seq), 0) from " .. shadow .. ")) where id = 1"),
      get_cols = column and db.all(
        "select col, hlc from " .. colshadow .. " where rid = ?1", true) or nil,
      put_col = column and db.runner(
        "insert into " .. colshadow .. " (rid, col, hlc) values (?1, ?2, ?3) " ..
        "on conflict (rid, col) do update set hlc = excluded.hlc") or nil,
      del_cols = column and db.runner("delete from " .. colshadow .. " where rid = ?1") or nil,
      backfill = db.runner(
        "insert into " .. shadow .. " (rid, hlc, seq, del) " ..
        "select " .. rid_q .. ", " .. minted_hlc .. ", " ..
        "(select seq from " .. meta .. " where id = 1) + " ..
        "row_number() over (order by " .. arr.concat(spec.pk, ", ") .. "), 0 " ..
        "from " .. name .. " where not exists (select 1 from " .. shadow ..
        " s where s.rid = " .. rid_q .. ")"),
      max_hlc = spec.seed and db.getter("select max(hlc) from " .. shadow) or nil,
      backfill_cols = column and db.runner(
        "insert into " .. colshadow .. " (rid, col, hlc) " ..
        "select s.rid, x.value, s.hlc from " .. shadow .. " s, " ..
        "json_each(?1) x where not exists (select 1 from " .. colshadow ..
        " c where c.rid = s.rid and c.col = x.value)") or nil,
    }
  end

  local replica = get_replica()

  db.transaction(function ()
    enter_quiet()
    for _, name in ipairs(names) do
      local t = T[name]
      bump_clock()
      t.backfill()
      t.seq_catchup()
      if t.max_hlc then
        local pt, c = hlc_parse(t.max_hlc())
        if pt then ratchet(pt, c) end
      end
      if t.column then
        local list = {}
        for i, c in ipairs(t.spec.columns) do list[i] = '"' .. c .. '"' end
        t.backfill_cols("[" .. arr.concat(list, ",") .. "]")
      end
    end
    exit_quiet()
  end)

  local function pack (name, r)
    local t = T[name]
    local e = { t = name, rid = r.rid, hlc = r.hlc }
    if r.del == 1 then
      e.del = true
      return e
    end
    local vals = {}
    for _, c in ipairs(t.all_cols) do
      vals[c] = r[c]
    end
    if t.column then
      local hlcs = {}
      for _, cr in ipairs(t.get_cols(r.rid)) do
        hlcs[cr.col] = cr.hlc
      end
      e.hlcs = hlcs
    end
    if codec then
      e.ct = codec.enc(encode(vals), aad(space, name, r.rid, r.hlc))
    else
      e.vals = vals
    end
    return e
  end

  local function collect (from)
    local rows = {}
    for _, name in ipairs(names) do
      for _, r in ipairs(T[name].enum(from, batch + 1)) do
        rows[#rows + 1] = { seq = r.seq, name = name, row = r }
      end
    end
    arr.sort(rows, function (a, b)
      if a.seq == b.seq then return a.name < b.name end
      return a.seq < b.seq
    end)
    local more = false
    if #rows > batch then
      more = true
      local cut = rows[batch + 1].seq
      local keep = {}
      for i = 1, #rows do
        if rows[i].seq < cut then keep[#keep + 1] = rows[i] end
      end
      if #keep == 0 then
        for i = 1, #rows do
          if rows[i].seq == cut then keep[#keep + 1] = rows[i] end
        end
      end
      rows = keep
    end
    local changes = {}
    for i = 1, #rows do
      changes[i] = pack(rows[i].name, rows[i].row)
    end
    local last = #rows > 0 and rows[#rows].seq or nil
    return changes, more, last
  end

  local function fail (code)
    return { v = PROTO, space = space, replica = replica, err = code }
  end

  local function check (req)
    if type(req) ~= "table" or req.v ~= PROTO then return "proto" end
    if req.space ~= space then return "space" end
    if type(req.tables) == "table" then
      for name, v in pairs(req.tables) do
        if versions[name] ~= nil and versions[name] ~= v then return "version" end
      end
    end
    return nil
  end

  local function bundle (from)
    local changes, more, last = collect(from)
    local top = more and last or get_seq()
    return {
      v = PROTO,
      space = space,
      replica = replica,
      seq = top or from,
      more = more,
      tables = versions,
      changes = changes,
    }, top or from
  end

  local function request (peer, ropts)
    local cur = 0
    if peer ~= nil then cur = get_cursor(peer) or 0 end
    local req = {
      v = PROTO,
      space = space,
      replica = replica,
      cursor = cur,
      tables = versions,
    }
    if ropts and ropts.fetch then req.fetch = ropts.fetch end
    return req
  end

  local function respond (req)
    local bad = check(req)
    if bad then return fail(bad) end
    local from = tonumber(req.cursor) or 0
    if from > 0 and from < (tonumber(get_gc_seq()) or 0) then
      return fail("reset")
    end
    local res = bundle(from)
    if type(req.fetch) == "table" then
      local fetched = {}
      for name, rids in pairs(req.fetch) do
        local t = T[name]
        if t and type(rids) == "table" then
          for _, rid in ipairs(rids) do
            for _, r in ipairs(t.fetch_one(rid)) do
              fetched[#fetched + 1] = pack(name, r)
            end
          end
        end
      end
      res.fetched = fetched
    end
    return res
  end

  local function push (peer)
    assert(peer ~= nil, "sync.push: peer required")
    local res = bundle(get_served(peer) or 0)
    res.push = true
    return res
  end

  local function ack (peer, seq)
    assert(peer ~= nil, "sync.ack: peer required")
    set_served(peer, tonumber(seq) or 0)
  end

  local function unpack_vals (name, e)
    if e.ct then
      local plain, derr = codec.dec(e.ct, aad(space, name, e.rid, e.hlc))
      if not plain then return nil, derr or "codec" end
      local ok, vals = pcall(decode, plain)
      if not ok or type(vals) ~= "table" then return nil, "codec" end
      return vals
    end
    if type(e.vals) ~= "table" then return nil, "malformed" end
    return e.vals
  end

  local function unreadable (e, reason, stats)
    if on_codec_error ~= "quarantine" then
      return error("sync.apply: " .. tostring(reason) .. " in " .. tostring(e.t))
    end
    stats.unreadable[#stats.unreadable + 1] = {
      t = e.t, rid = e.rid, hlc = e.hlc, reason = reason or "codec",
    }
  end

  local function apply_one (e, stats)
    if type(e) ~= "table" or type(e.t) ~= "string" then
      return error("sync.apply: malformed change")
    end
    local t = T[e.t]
    if not t then return error("sync.apply: unknown table " .. e.t) end
    if type(e.rid) ~= "string" or type(e.hlc) ~= "string" then
      return error("sync.apply: malformed change in " .. e.t)
    end
    local pt = hlc_parse(e.hlc)
    if not pt then return error("sync.apply: malformed hlc in " .. e.t) end
    if pt > (now_ms() or 0) + max_skew then
      stats.poisoned = stats.poisoned + 1
      return
    end
    local cur = t.get_shadow(e.rid)
    local lhlc = cur and cur.hlc or nil
    local ldel = cur and cur.del == 1 or false
    if t.column and not e.del and cur and not ldel then
      local vals, derr = unpack_vals(e.t, e)
      if not vals then return unreadable(e, derr, stats) end
      local locals = {}
      for _, cr in ipairs(t.get_cols(e.rid)) do locals[cr.col] = cr.hlc end
      local took, top = false, lhlc
      for _, c in ipairs(t.spec.columns) do
        local rh = e.hlcs and e.hlcs[c] or e.hlc
        if wins(rh, false, locals[c], false) then
          t.col_set[c](vals[c], e.rid)
          t.put_col(e.rid, c, rh)
          took = true
          if rh > top then top = rh end
        end
      end
      if took then
        t.put_shadow(e.rid, top, next_seq(), 0)
        stats.applied = stats.applied + 1
        if t.spec.after_apply then
          t.spec.after_apply("update", e.rid, vals, top)
        end
      else
        stats.skipped = stats.skipped + 1
      end
      return
    end
    if not wins(e.hlc, e.del and true or false, lhlc, ldel) then
      stats.skipped = stats.skipped + 1
      return
    end
    if e.del then
      t.del_base(e.rid)
      if t.column then t.del_cols(e.rid) end
      t.put_shadow(e.rid, e.hlc, next_seq(), 1)
      stats.applied = stats.applied + 1
      if t.spec.after_apply then
        t.spec.after_apply("delete", e.rid, nil, e.hlc)
      end
      return
    end
    local vals, derr = unpack_vals(e.t, e)
    if not vals then return unreadable(e, derr, stats) end
    local args = {}
    for _, c in ipairs(t.all_cols) do
      args[c] = vals[c]
    end
    t.upsert_base(args)
    if t.column then
      t.del_cols(e.rid)
      for _, c in ipairs(t.spec.columns) do
        t.put_col(e.rid, c, (e.hlcs and e.hlcs[c]) or e.hlc)
      end
    end
    t.put_shadow(e.rid, e.hlc, next_seq(), 0)
    stats.applied = stats.applied + 1
    if t.spec.after_apply then
      t.spec.after_apply((cur == nil or ldel) and "insert" or "update",
        e.rid, vals, e.hlc)
    end
  end

  local function apply (res)
    if type(res) ~= "table" then return error("sync.apply: response table required") end
    if res.err then return error("sync.apply: peer error " .. tostring(res.err)) end
    local bad = check(res)
    if bad then return error("sync.apply: " .. bad) end
    if type(res.replica) ~= "string" then return error("sync.apply: response has no replica") end
    local stats = {
      peer = res.replica,
      applied = 0,
      skipped = 0,
      poisoned = 0,
      unreadable = {},
      more = res.more and true or false,
    }
    db.transaction(function ()
      db.exec("pragma defer_foreign_keys = on")
      enter_quiet()
      local top = nil
      for _, e in ipairs(res.changes or {}) do
        ratchet(hlc_parse(e.hlc))
        apply_one(e, stats)
        if type(e.hlc) == "string" and (top == nil or e.hlc > top) then top = e.hlc end
      end
      for _, e in ipairs(res.fetched or {}) do
        ratchet(hlc_parse(e.hlc))
        apply_one(e, stats)
      end
      exit_quiet()
      local seq = tonumber(res.seq) or 0
      if seq > 0 and #stats.unreadable == 0 then set_cursor(res.replica, seq) end
      stats.cursor = get_cursor(res.replica) or 0
    end)
    return stats
  end

  local function quiet (fn, ...)
    assert(type(fn) == "function", "sync.quiet: function required")
    return db.transaction(function (...)
      enter_quiet()
      return (function (ok, ...)
        exit_quiet()
        if not ok then
          return error(...)
        end
        return ...
      end)(pcall(fn, ...))
    end, ...)
  end

  local function digest ()
    local out = {}
    for _, name in ipairs(names) do
      local b, n = {}, 0
      for i = 1, BUCKETS do b[i] = 0 end
      for _, r in ipairs(T[name].scan_shadow()) do
        local i = hash(r.rid) % BUCKETS + 1
        b[i] = (b[i] + hash(r.rid .. ";" .. r.hlc .. ";" .. (r.del == 1 and "1" or "0"))) % MOD
        n = n + 1
      end
      out[name] = { n = n, b = b }
    end
    return { v = PROTO, space = space, replica = replica, tables = out }
  end

  local function compare (remote)
    assert(type(remote) == "table" and type(remote.tables) == "table",
      "sync.compare: digest table required")
    local mine = digest()
    local out = {}
    for name, rd in pairs(remote.tables) do
      local ld = mine.tables[name]
      if ld and type(rd.b) == "table" then
        local diff = {}
        for i = 1, BUCKETS do
          if (ld.b[i] or 0) ~= (rd.b[i] or 0) then diff[#diff + 1] = i end
        end
        if #diff > 0 then out[name] = diff end
      end
    end
    return out
  end

  local function manifest (sel)
    assert(type(sel) == "table", "sync.manifest: selection table required")
    local out = {}
    for name, buckets in pairs(sel) do
      local t = T[name]
      if t and type(buckets) == "table" then
        local want = {}
        for _, i in ipairs(buckets) do want[i] = true end
        local list = {}
        for _, r in ipairs(t.scan_shadow()) do
          if want[hash(r.rid) % BUCKETS + 1] then
            list[#list + 1] = { rid = r.rid, hlc = r.hlc, del = r.del == 1 or nil }
          end
        end
        out[name] = list
      end
    end
    return { v = PROTO, space = space, replica = replica, tables = out }
  end

  local function reconcile (remote)
    assert(type(remote) == "table" and type(remote.tables) == "table",
      "sync.reconcile: manifest table required")
    local fetch = {}
    for name, list in pairs(remote.tables) do
      local t = T[name]
      if t and type(list) == "table" then
        local want = {}
        for _, r in ipairs(list) do
          local cur = t.get_shadow(r.rid)
          local lhlc = cur and cur.hlc or nil
          local ldel = cur and cur.del == 1 or false
          if wins(r.hlc, r.del and true or false, lhlc, ldel) then
            want[#want + 1] = r.rid
          end
        end
        if #want > 0 then fetch[name] = want end
      end
    end
    return { fetch = fetch }
  end

  local function peers ()
    return list_peers()
  end

  local function forget (peer)
    assert(peer ~= nil, "sync.forget: peer required")
    del_peer(peer)
  end

  local function gc (before)
    assert(type(before) == "string" and hlc_parse(before),
      "sync.gc: before must be an hlc string")
    local n = 0
    db.transaction(function ()
      for _, name in ipairs(names) do
        n = n + (T[name].gc_count(before) or 0)
        T[name].gc_del(before)
      end
      set_gc(before)
    end)
    return n
  end

  local function detach (name)
    local t = T[name]
    assert(t ~= nil, "sync.detach: unknown table " .. tostring(name))
    db.exec(
      "drop trigger if exists " .. q .. name .. "_" .. prefix .. "_ai;" ..
      "drop trigger if exists " .. q .. name .. "_" .. prefix .. "_au;" ..
      "drop trigger if exists " .. q .. name .. "_" .. prefix .. "_ad;" ..
      "drop index if exists " .. q .. name .. "_" .. prefix .. "_rid;" ..
      "drop index if exists " .. q .. name .. "_" .. prefix .. "_seq;" ..
      "drop table if exists " .. shadow_of(name) .. ";" ..
      (t.column and ("drop table if exists " .. colshadow_of(name) .. ";") or ""))
    T[name] = nil
    versions[name] = nil
    for i = 1, #names do
      if names[i] == name then
        arr.remove(names, i, i)
        break
      end
    end
  end

  return {
    id = function () return replica end,
    seq = function () return get_seq() end,
    request = request,
    respond = respond,
    apply = apply,
    push = push,
    ack = ack,
    quiet = quiet,
    digest = digest,
    compare = compare,
    manifest = manifest,
    reconcile = reconcile,
    peers = peers,
    forget = forget,
    gc = gc,
    detach = detach,
  }
end

return { create = create }
