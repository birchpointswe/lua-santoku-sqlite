local test = require("santoku.test")

local err = require("santoku.error")
local assert = err.assert

local validate = require("santoku.validate")
local eq = validate.isequal

local sqlite = require("santoku.sqlite.db")
local sql = require("santoku.sqlite")
local sync = require("santoku.sqlite.sync")

local function notes_peer (topts, sopts)
  local db = sql(sqlite.open_memory())
  db.exec([[
    create table notes (
      id text primary key,
      title text not null default '',
      body text not null default '',
      scratch text,
      done integer not null default 0
    )
  ]])
  local spec = { pk = { "id" }, columns = { "title", "body", "done" } }
  for k, v in pairs(topts or {}) do spec[k] = v end
  local o = { space = "t", tables = { notes = spec } }
  for k, v in pairs(sopts or {}) do o[k] = v end
  local s = sync.create(db, o)
  return {
    db = db,
    sync = s,
    add = db.runner("insert into notes (id, title) values (?1, ?2)"),
    settitle = db.runner("update notes set title = ?2 where id = ?1"),
    setbody = db.runner("update notes set body = ?2 where id = ?1"),
    setscratch = db.runner("update notes set scratch = ?2 where id = ?1"),
    drop = db.runner("delete from notes where id = ?1"),
    title = db.getter("select title from notes where id = ?1"),
    body = db.getter("select body from notes where id = ?1"),
    scratch = db.getter("select scratch from notes where id = ?1"),
    count = db.getter("select count(*) from notes"),
    shadows = db.getter("select count(*) from notes_sync"),
    tombs = db.getter("select count(*) from notes_sync where del = 1"),
  }
end

local function pull (dst, src)
  return dst.sync.apply(src.sync.respond(dst.sync.request(src.sync.id())))
end

local function converge (a, b)
  for _ = 1, 20 do
    local x = pull(a, b)
    local y = pull(b, a)
    if x.applied == 0 and y.applied == 0 and not x.more and not y.more then
      return
    end
  end
  return err.error("peers did not converge")
end

test("sqlite.sync", function ()

  test("triggers capture ordinary sql with no app-side funnel", function ()
    local a = notes_peer()
    assert(eq(0, a.shadows()))
    a.add("n1", "hello")
    assert(eq(1, a.shadows()))
    a.settitle("n1", "hello again")
    assert(eq(1, a.shadows()))
    assert(eq(0, a.tombs()))
    a.drop("n1")
    assert(eq(1, a.shadows()))
    assert(eq(1, a.tombs()))
  end)

  test("columns outside the config stay local and do not stamp", function ()
    local a = notes_peer()
    a.add("n1", "hello")
    local before = a.sync.seq()
    a.setscratch("n1", "local only")
    assert(eq(before, a.sync.seq()))
    local b = notes_peer()
    converge(a, b)
    assert(eq("hello", b.title("n1")))
    assert(eq(nil, b.scratch("n1")))
  end)

  test("pre-existing rows are backfilled when sync is enabled", function ()
    local db = sql(sqlite.open_memory())
    db.exec("create table notes (id text primary key, title text not null default '')")
    local add = db.runner("insert into notes (id, title) values (?1, ?2)")
    add("old1", "one")
    add("old2", "two")
    local s = sync.create(db, {
      space = "t",
      tables = { notes = { pk = { "id" }, columns = { "title" } } },
    })
    local shadows = db.getter("select count(*) from notes_sync")
    assert(eq(2, shadows()))
    assert(eq(2, s.seq()))
  end)

  test("first contact merges unrelated pre-existing data both ways", function ()
    local a, b = notes_peer(), notes_peer()
    a.add("a1", "alpha")
    a.add("a2", "beta")
    b.add("b1", "gamma")
    converge(a, b)
    assert(eq(3, a.count()))
    assert(eq(3, b.count()))
    assert(eq("gamma", a.title("b1")))
    assert(eq("alpha", b.title("a1")))
  end)

  test("the same logical row from a prior copy converges to one winner", function ()
    local a, b = notes_peer(), notes_peer()
    a.add("dup", "from a")
    b.add("dup", "from b")
    converge(a, b)
    assert(eq(1, a.count()))
    assert(eq(1, b.count()))
    assert(eq(a.title("dup"), b.title("dup")))
  end)

  test("concurrent edits converge and the loser stops propagating", function ()
    local a, b = notes_peer(), notes_peer()
    a.add("n1", "seed")
    converge(a, b)
    a.settitle("n1", "from a")
    b.settitle("n1", "from b")
    converge(a, b)
    assert(eq(a.title("n1"), b.title("n1")))
    local winner = a.title("n1")
    assert(winner == "from a" or winner == "from b")
    local quiet = pull(a, b)
    assert(eq(0, quiet.applied))
  end)

  test("a delete racing an edit is decided the same way on both peers", function ()
    local a, b = notes_peer(), notes_peer()
    a.add("n1", "seed")
    converge(a, b)
    a.drop("n1")
    b.settitle("n1", "still here")
    converge(a, b)
    assert(eq(a.count(), b.count()))
    assert(eq(a.title("n1"), b.title("n1")))
  end)

  test("a delete propagates when nothing races it", function ()
    local a, b = notes_peer(), notes_peer()
    a.add("n1", "seed")
    a.add("n2", "keep")
    converge(a, b)
    a.drop("n1")
    converge(a, b)
    assert(eq(1, b.count()))
    assert(eq("keep", b.title("n2")))
  end)

  test("applying the same response twice changes nothing", function ()
    local a, b = notes_peer(), notes_peer()
    b.add("n1", "once")
    local res = b.sync.respond(a.sync.request(b.sync.id()))
    local first = a.sync.apply(res)
    assert(eq(1, first.applied))
    local second = a.sync.apply(res)
    assert(eq(0, second.applied))
    assert(eq(1, second.skipped))
    assert(eq(1, a.count()))
    assert(eq("once", a.title("n1")))
  end)

  test("a cursor never regresses on a replayed older response", function ()
    local a, b = notes_peer(), notes_peer()
    b.add("n1", "one")
    local old = b.sync.respond(a.sync.request(b.sync.id()))
    b.add("n2", "two")
    local new = b.sync.respond(a.sync.request(b.sync.id()))
    a.sync.apply(new)
    local after = a.sync.apply(old).cursor
    assert(after >= new.seq)
    assert(eq(2, a.count()))
  end)

  test("push ships a delta without a request, and ack advances the high-water", function ()
    local a, b = notes_peer(), notes_peer()
    a.add("n1", "pushed")
    local bundle = a.sync.push(b.sync.id())
    assert(eq(1, #bundle.changes))
    local stats = b.sync.apply(bundle)
    assert(eq(1, stats.applied))
    assert(eq("pushed", b.title("n1")))
    local again = a.sync.push(b.sync.id())
    assert(eq(1, #again.changes))
    a.sync.ack(b.sync.id(), again.seq)
    a.add("n2", "next")
    local delta = a.sync.push(b.sync.id())
    assert(eq(1, #delta.changes))
    assert(eq("n2", delta.changes[1].vals.id))
  end)

  test("paging carries every change across batches", function ()
    local src = notes_peer(nil, { batch = 3 })
    local dst = notes_peer(nil, { batch = 3 })
    for i = 1, 10 do src.add("n" .. i, "t" .. i) end
    local rounds = 0
    while true do
      local res = src.sync.respond(dst.sync.request(src.sync.id()))
      local stats = dst.sync.apply(res)
      rounds = rounds + 1
      if not stats.more then break end
      assert(rounds < 20, "paging did not terminate")
    end
    assert(rounds > 1, "batch limit did not page")
    assert(eq(10, dst.count()))
  end)

  test("a mismatched space or table version is refused", function ()
    local a = notes_peer()
    local bad = a.sync.respond({ v = 1, space = "other", cursor = 0, tables = {} })
    assert(eq("space", bad.err))
    bad = a.sync.respond({ v = 1, space = "t", cursor = 0, tables = { notes = 99 } })
    assert(eq("version", bad.err))
    bad = a.sync.respond({ v = 2, space = "t", cursor = 0, tables = {} })
    assert(eq("proto", bad.err))
  end)

  test("digest and manifest locate a divergence that counts would miss", function ()
    local a, b = notes_peer(), notes_peer()
    a.add("n1", "one")
    a.add("n2", "two")
    converge(a, b)
    local clean = a.sync.compare(b.sync.digest())
    assert(eq(nil, clean.notes))
    b.db.exec("update notes set title = 'tampered' where id = 'n1'")
    b.db.exec("update notes_sync set hlc = '00000000000001.00000000.0000000000000000' where rid = json_array('n1')")
    local diff = a.sync.compare(b.sync.digest())
    assert(diff.notes ~= nil and #diff.notes > 0)
    local plan = b.sync.reconcile(a.sync.manifest(diff))
    assert(plan.fetch.notes ~= nil and #plan.fetch.notes == 1)
    local res = a.sync.respond(b.sync.request(a.sync.id(), { fetch = plan.fetch }))
    assert(res.fetched ~= nil and #res.fetched == 1)
    b.sync.apply(res)
    assert(eq("one", b.title("n1")))
  end)

  test("column granularity merges concurrent edits to different fields", function ()
    local a = notes_peer({ granularity = "column" })
    local b = notes_peer({ granularity = "column" })
    a.add("n1", "seed")
    converge(a, b)
    a.settitle("n1", "title from a")
    b.setbody("n1", "body from b")
    converge(a, b)
    assert(eq("title from a", a.title("n1")))
    assert(eq("title from a", b.title("n1")))
    assert(eq("body from b", a.body("n1")))
    assert(eq("body from b", b.body("n1")))
  end)

  test("row granularity lets one whole-row write win", function ()
    local a, b = notes_peer(), notes_peer()
    a.add("n1", "seed")
    converge(a, b)
    a.settitle("n1", "title from a")
    b.setbody("n1", "body from b")
    converge(a, b)
    assert(eq(a.title("n1"), b.title("n1")))
    assert(eq(a.body("n1"), b.body("n1")))
  end)

  test("composite and integer primary keys round-trip", function ()
    local function make ()
      local db = sql(sqlite.open_memory())
      db.exec([[
        create table entries (
          acct integer not null,
          slot integer not null,
          note text not null default '',
          primary key (acct, slot)
        )
      ]])
      local s = sync.create(db, {
        space = "t",
        tables = { entries = { pk = { "acct", "slot" }, columns = { "note" } } },
      })
      return {
        db = db, sync = s,
        add = db.runner("insert into entries (acct, slot, note) values (?1, ?2, ?3)"),
        note = db.getter("select note from entries where acct = ?1 and slot = ?2"),
        count = db.getter("select count(*) from entries"),
      }
    end
    local a, b = make(), make()
    a.add(1, 7, "first")
    b.add(2, 9, "second")
    converge(a, b)
    assert(eq(2, a.count()))
    assert(eq(2, b.count()))
    assert(eq("second", a.note(2, 9)))
    assert(eq("first", b.note(1, 7)))
  end)

  test("a primary key change becomes a delete plus an insert", function ()
    local a, b = notes_peer(), notes_peer()
    a.add("old", "moving")
    converge(a, b)
    a.db.exec("update notes set id = 'new' where id = 'old'")
    converge(a, b)
    assert(eq(nil, b.title("old")))
    assert(eq("moving", b.title("new")))
    assert(eq(1, b.count()))
  end)

  test("an injected codec hides values and binds them to table, rid and hlc", function ()
    local seen = {}
    local function make ()
      local db = sql(sqlite.open_memory())
      db.exec("create table notes (id text primary key, title text not null default '')")
      local s = sync.create(db, {
        space = "t",
        tables = { notes = { pk = { "id" }, columns = { "title" } } },
        encode = function (v) return v.id .. "\30" .. v.title end,
        decode = function (s2)
          local id, title = s2:match("^(.-)\30(.*)$")
          return { id = id, title = title }
        end,
        codec = {
          enc = function (plain, aad)
            seen[#seen + 1] = aad
            return aad .. "|" .. plain
          end,
          dec = function (ct, aad)
            local got, plain = ct:match("^(.-)|(.*)$")
            if got ~= aad then return nil, "auth_failed" end
            return plain
          end,
        },
      })
      return {
        db = db, sync = s,
        add = db.runner("insert into notes (id, title) values (?1, ?2)"),
        title = db.getter("select title from notes where id = ?1"),
      }
    end
    local a, b = make(), make()
    a.add("n1", "secret")
    local res = a.sync.respond(b.sync.request(a.sync.id()))
    assert(res.changes[1].vals == nil)
    assert(res.changes[1].ct ~= nil)
    assert(seen[1]:match("^t:notes:"))
    assert(seen[1]:find(res.changes[1].hlc, 1, true) ~= nil)
    b.sync.apply(res)
    assert(eq("secret", b.title("n1")))
    local newer = res.changes[1].hlc:sub(1, 14) .. ".ffffffff.ffffffffffffffff"
    local spliced = { v = res.v, space = res.space, replica = res.replica,
      seq = res.seq, more = false, tables = res.tables,
      changes = { { t = "notes", rid = res.changes[1].rid,
        hlc = newer, ct = res.changes[1].ct } } }
    local ok = pcall(b.sync.apply, spliced)
    assert(not ok)
    assert(eq("secret", b.title("n1")))
  end)

  test("quiet suppresses capture, and nests inside apply without leaking", function ()
    local a = notes_peer()
    a.add("n1", "seed")
    local before = a.sync.seq()
    a.sync.quiet(function ()
      a.settitle("n1", "projection only")
    end)
    assert(eq(before, a.sync.seq()))
    assert(eq("projection only", a.title("n1")))

    a.settitle("n1", "ordinary write")
    assert(a.sync.seq() > before)

    local ok = pcall(a.sync.quiet, function () error("boom") end)
    assert(not ok)
    local after_err = a.sync.seq()
    a.settitle("n1", "capture still on")
    assert(a.sync.seq() > after_err)

    local nested_seen = nil
    a.sync.quiet(function ()
      a.sync.quiet(function ()
        a.settitle("n1", "inner")
      end)
      local mid = a.sync.seq()
      a.settitle("n1", "outer still quiet")
      nested_seen = a.sync.seq() == mid
    end)
    assert(nested_seen, "inner quiet cleared the outer suppression")
  end)

  test("an unreadable record quarantines instead of wedging the whole batch", function ()
    local function make (mode)
      local db = sql(sqlite.open_memory())
      db.exec("create table notes (id text primary key, title text not null default '')")
      local s = sync.create(db, {
        space = "t",
        on_codec_error = mode,
        tables = { notes = { pk = { "id" }, columns = { "title" } } },
        encode = function (v) return v.id .. "\30" .. v.title end,
        decode = function (s2)
          local id, title = s2:match("^(.-)\30(.*)$")
          return { id = id, title = title }
        end,
        codec = {
          enc = function (plain, ad) return ad .. "|" .. plain end,
          dec = function (ct, ad)
            local got, plain = ct:match("^(.-)|(.*)$")
            if got ~= ad then return nil, "auth_failed" end
            return plain
          end,
        },
      })
      return {
        sync = s,
        add = db.runner("insert into notes (id, title) values (?1, ?2)"),
        count = db.getter("select count(*) from notes"),
        title = db.getter("select title from notes where id = ?1"),
      }
    end

    local src = make("abort")
    src.add("n1", "poison")
    src.add("n2", "healthy")

    local dst = make("quarantine")
    local res = src.sync.respond(dst.sync.request(src.sync.id()))
    for _, c in ipairs(res.changes) do
      if c.rid:find("n1", 1, true) then c.ct = "tampered|garbage" end
    end
    local stats = dst.sync.apply(res)
    assert(eq(1, #stats.unreadable))
    assert(eq("auth_failed", stats.unreadable[1].reason))
    assert(eq(1, stats.applied))
    assert(eq("healthy", dst.title("n2")))
    assert(eq(0, stats.cursor), "cursor must freeze while a record is unreadable")

    local strict = make("abort")
    local res2 = src.sync.respond(strict.sync.request(src.sync.id()))
    for _, c in ipairs(res2.changes) do
      if c.rid:find("n1", 1, true) then c.ct = "tampered|garbage" end
    end
    assert(not pcall(strict.sync.apply, res2))
    assert(eq(0, strict.count()), "abort mode must roll the whole batch back")
  end)

  test("a custom aad hook is used on both sides and is bound per record", function ()
    local seen = {}
    local function make ()
      local db = sql(sqlite.open_memory())
      db.exec("create table notes (id text primary key, title text not null default '')")
      local s = sync.create(db, {
        space = "acct",
        tables = { notes = { pk = { "id" }, columns = { "title" } } },
        aad = function (sp, _, rid, hlc)
          return sp .. ":" .. (rid:match('^%["(.-)"%]$') or rid) .. ":" .. hlc
        end,
        encode = function (v) return v.id .. "\30" .. v.title end,
        decode = function (s2)
          local id, title = s2:match("^(.-)\30(.*)$")
          return { id = id, title = title }
        end,
        codec = {
          enc = function (plain, ad)
            seen[#seen + 1] = ad
            return ad .. "|" .. plain
          end,
          dec = function (ct, ad)
            local got, plain = ct:match("^(.-)|(.*)$")
            if got ~= ad then return nil, "auth_failed" end
            return plain
          end,
        },
      })
      return {
        sync = s,
        add = db.runner("insert into notes (id, title) values (?1, ?2)"),
        title = db.getter("select title from notes where id = ?1"),
      }
    end
    local a, b = make(), make()
    a.add("n1", "secret")
    local res = a.sync.respond(b.sync.request(a.sync.id()))
    assert(seen[1]:match("^acct:n1:"), "aad hook not used: " .. tostring(seen[1]))
    assert(not seen[1]:find("notes", 1, true), "table name should be absent from custom aad")
    assert(not seen[1]:find("[", 1, true), "rid should be unwrapped by the hook")
    b.sync.apply(res)
    assert(eq("secret", b.title("n1")))
  end)

  test("a change from far in the future is quarantined, not applied", function ()
    local a, b = notes_peer(), notes_peer()
    b.add("n1", "fine")
    local res = b.sync.respond(a.sync.request(b.sync.id()))
    res.changes[1].hlc = "99999999999999.00000000.0000000000000000"
    local stats = a.sync.apply(res)
    assert(eq(1, stats.poisoned))
    assert(eq(0, stats.applied))
    assert(eq(0, a.count()))
  end)

  test("gc drops tombstones and forces a stale peer to reset", function ()
    local a, b = notes_peer(), notes_peer()
    a.add("n1", "seed")
    converge(a, b)
    a.drop("n1")
    assert(eq(1, a.tombs()))
    local stale = b.sync.request(a.sync.id())
    a.sync.gc("99999999999999.00000000.0000000000000000")
    assert(eq(0, a.tombs()))
    local res = a.sync.respond(stale)
    assert(eq("reset", res.err))
    b.sync.forget(a.sync.id())
    local fresh = a.sync.respond(b.sync.request(a.sync.id()))
    assert(fresh.err == nil)
  end)

  test("peers and forget expose and clear cursor state", function ()
    local a, b = notes_peer(), notes_peer()
    b.add("n1", "one")
    pull(a, b)
    local list = a.sync.peers()
    assert(eq(1, #list))
    assert(eq(b.sync.id(), list[1].peer))
    assert(list[1].cursor > 0)
    a.sync.forget(b.sync.id())
    assert(eq(0, #a.sync.peers()))
  end)

  test("create is re-runnable and detach removes the machinery", function ()
    local a = notes_peer()
    a.add("n1", "one")
    local s2 = sync.create(a.db, {
      space = "t",
      tables = { notes = { pk = { "id" }, columns = { "title", "body", "done" } } },
    })
    assert(eq(1, a.shadows()))
    assert(eq(a.sync.id(), s2.id()))
    a.add("n2", "two")
    assert(eq(2, a.shadows()))
    s2.detach("notes")
    local left = a.db.getter(
      "select count(*) from sqlite_master where type = 'table' and name = 'notes_sync'")
    assert(eq(0, left()))
    a.add("n3", "three")
    assert(eq(3, a.count()))
  end)

  test("bad config is rejected", function ()
    local db = sql(sqlite.open_memory())
    db.exec("create table notes (id text primary key, title text)")
    local function bad (opts)
      return not pcall(sync.create, db, opts)
    end
    assert(bad({ tables = {} }))
    assert(bad({ tables = { notes = { pk = {}, columns = { "title" } } } }))
    assert(bad({ tables = { notes = { pk = { "id" }, columns = {} } } }))
    assert(bad({ tables = { notes = { pk = { "id" }, columns = { "id" } } } }))
    assert(bad({ tables = { notes = { pk = { "id" }, columns = { "hlc" } } } }))
    assert(bad({ tables = { notes = { pk = { "id" }, columns = { "title" }, granularity = "wat" } } }))
    assert(bad({ tables = { ["drop table"] = { pk = { "id" }, columns = { "title" } } } }))
    assert(bad({
      tables = { notes = { pk = { "id" }, columns = { "title" } } },
      codec = { enc = function () end, dec = function () end },
    }))
  end)

end)
