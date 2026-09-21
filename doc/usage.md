# santoku-sqlite usage

Worked examples by scenario. Each section names its anchor test; read the test for the
exhaustive surface. Vec and csr types are [santoku-matrix](../../lua-santoku-matrix/README.md);
`assert`/`pcall`/`error` are [santoku](../../lua-santoku/README.md) (`santoku.error`).

## Open and wrap

```lua
local sqlite = require("santoku.sqlite.db")     -- C core
local sql    = require("santoku.sqlite")        -- wrapper

local db = sql(sqlite.open_memory())            -- in-memory, dropped on close
-- local db = sql(sqlite.open("/path/to/file.db"))
-- local db = sql(sqlite.open_v2("/path/to/file.db", nil))   -- readwrite|create, optional vfs name
```

`sqlite.open*` return the connection userdata, or `nil` on failure. `sql(conn)` wraps it.
The raw connection remains at `db.db`.

Anchor: `test/spec/santoku/sqlite.lua` ("persists to a file across open and close").

## exec versus the factories

`db.exec(sql)` runs SQL with no binding, including multi-statement scripts:

```lua
db.exec([[
  create table numbers (n integer);
  create index numbers_n on numbers (n);
]])
```

For anything parameterised, build a closure once and reuse it:

```lua
local addn = db.runner("insert into numbers (n) values (?)")
for i = 1, 100 do addn(i) end
```

## Reading rows: prop and the factories

`prop` controls each returned row:

- omitted / `nil`: first column value
- `true`: a `{ column = value }` table
- `false`: nothing (run for side effects)

```lua
local getstate = db.getter("select state from cities where name = ?")        -- "New York"
local getcity  = db.getter("select * from cities where name = ?", true)      -- { name=, state= }

for row in db.iter("select * from cities", true)() do ... end                -- streaming
local rows = db.all("select * from cities", true)()                          -- list in memory
```

Note the double call on `iter`/`all`: the factory returns a closure, you call it with the
bind arguments, and that returns the iterator (`iter`) or the materialised list (`all`).

Anchor: `test/spec/santoku/sqlite.lua` ("should wrap various functions", "should handle
multiple iterators", "should handle with clauses").

## Binding: positional and named

```lua
local add = db.runner("insert into cities (name, state) values (:name, :state)")
add({ name = "Tampa", state = "Florida" })                  -- named: single table

local get = db.getter("select state from cities where name = :name")
get({ name = "Tampa" })                                     -- "Florida"
```

`nil` binds SQL null; text with embedded zero bytes round-trips intact:

```lua
db.runner("insert into t (a, b) values (?, ?)")(nil, "x\0y")
local row = db.getter("select a, b from t", true)()         -- row.a == nil, row.b == "x\0y"
```

Anchor: `test/spec/santoku/sqlite.lua` ("binds named parameters", "round-trips null and
text with embedded zeros").

## Inserts that need the rowid

```lua
local addn = db.inserter("insert into numbers (n) values (?)")
local id = addn(42)                                          -- last_insert_rowid()
```

Anchor: `test/spec/santoku/sqlite.lua` ("should handle multiple iterators").

## Transactions

```lua
db.transaction(function (a, b, c)
  -- a, b, c are the trailing args; commits on return, rolls back + re-raises on error
  for i = 1, 100 do addn(i) end
end, 1, 2, 3)

db.transaction("deferred", function () ... end)             -- leading string selects the mode
```

Nested calls reuse the outer transaction:

```lua
db.transaction(function ()
  db.transaction(function () ... end)                       -- inner just runs the function
end)
```

Manual control when you need it:

```lua
db.begin("immediate")
-- ... statements ...
db.commit()                                                 -- or db.rollback()
```

Anchor: `test/spec/santoku/sqlite.lua` ("nested transaction", the transaction cases) and
the seeded manual-transaction case.

## Errors

The wrapper raises on SQL errors; recover with `pcall`:

```lua
local err = require("santoku.error")
local ok = err.pcall(function () db.exec("not valid sql") end)   -- false
```

Anchor: `test/spec/santoku/sqlite.lua` ("propagates sql errors").

## carray: vectors as table-valued inputs

A vec passed as a parameter is read as rows of a `value` column straight from its backing
store. Order is `rowid` (1-based insertion order):

```lua
local ivec = require("santoku.ivec")
local q = db.all("select value from carray(?) order by rowid", true)
q(ivec.create({ 10, 20, 30 }))                  -- { {value=10}, {value=20}, {value=30} }
```

For a slice, drop to the raw statement and use `bind_carray(pidx, vec[, start, count])`:

```lua
local stmt = db.db:prepare("select value from carray(?1) order by rowid")
stmt:reset()
stmt:bind_carray(1, ivec.create({ 1, 2, 3, 4, 5 }), 1, 3)   -- binds elements [1,4) -> 2,3,4
```

`bind_carray` raises on an out-of-range slice. Element type follows the vec: `ivec`
int64, `svec` int32, `fvec` float, `dvec` double.

Anchor: `test/spec/santoku/sqlite/carray.lua`.

## fts: full-text search over your own tokens

`fts.create(db, opts)` builds a contentless FTS5 index plus a `<name>_map` table that
maps your text ids to the integer rowids FTS5 requires. Documents are `csr` rows: ids
are token ids, values are term frequencies.

Tokenization stays in santoku. A C tokenizer registered as `santoku` receives token ids
packed by `stmt:bind_tokens` and emits them directly, so `regions`, `terminals`, `tags`
and `focus` all still decide what a token is. FTS5 never sees your text.

Ranking is `santoku_bm25()`, a BM25 implementation registered into FTS5 from C. It takes
its document statistics from the index and its per-term query weights from you. Scores sort
ascending, lower being better.

The two sides of the API read their `values` differently, and the difference is worth
holding onto:

- `add` treats values as **term frequencies**. They are materialised as repeated tokens,
  which is what an inverted index stores, so pass counts and do **not** pre-weight with
  `csr:idf()` or `csr:bm25()`. BM25 derives idf and length normalisation itself.
- `search` treats values as **query weights**, passed through as floats. Leave them at the
  query's term counts for ordinary use, or raise one to boost a term. Nothing is rounded.

```lua
local fts = require("santoku.sqlite.fts")
local ivec, fvec, csr = require("santoku.ivec"), require("santoku.fvec"), require("santoku.csr")

local idx = fts.create(db, { name = "docs" })

idx.add(
  { "a", "b", "c" },
  csr.create({
    offsets   = ivec.create({ 0, 3, 6, 8 }),
    neighbors = ivec.create({ 1, 2, 3, 2, 3, 4, 5, 6 }),
    values    = fvec.create({ 1, 1, 1, 1, 1, 1, 1, 1 }),
  }))

local q = csr.create({
  offsets   = ivec.create({ 0, 2 }),
  neighbors = ivec.create({ 2, 3 }),
  values    = fvec.create({ 1, 1 }),
})

for _, hit in ipairs(idx.search(q, 10)) do
  print(hit.id, hit.score)
end

idx.remove({ "a" })
idx.clear()
```

`opts` takes `name`, an optional `schema`, and an optional `detail` of `full`, `column`
or `none`. Query terms are OR-ed: the MATCH expression is built in C by `stmt:bind_match`
and the weights bound alongside it by `stmt:bind_weights`, so no caller writes FTS5 query
syntax. Re-adding an id replaces it, and deletes work because the table is created with
`contentless_delete=1`.

Anchor: `test/spec/santoku/sqlite/fts.lua`.

## Ad-hoc SQL: query, complete, authorizer

The factories assume SQL known at startup, prepared once and reused. For SQL that
arrives at runtime, `db.query` prepares fresh per call and returns materialized rows
plus column names:

```lua
local rows, cols = db.query("select a, b from t order by a")
-- cols == { "a", "b" }, rows == { { 1, "x" }, { 2, "y" } }
local rows2 = db.query("select b from t where a = ?", 2)
```

`sqlite.complete(str)` reports whether a string is one or more complete statements,
for splitting editor input (semicolons inside trigger bodies do not fool it):

```lua
sqlite.complete("select 1;")                      -- true
sqlite.complete("select 1")                       -- false
```

`db.authorizer(spec)` installs a declarative policy enforced in C during prepare.
No Lua runs in the callback: the spec is read once at registration and copied into
C-owned memory. `db.authorizer(nil)` uninstalls.

```lua
db.authorizer({
  deny = { sqlite.ATTACH, sqlite.DETACH },
  pragmas = { "table_info", "table_xinfo", "integrity_check" },
})
```

- `deny`: array of action codes (`sqlite.ATTACH`, `sqlite.CREATE_TABLE`,
  `sqlite.READ`, ...) refused outright. Optional; codes must be integers in
  `[1, 63]`.
- `pragmas`: array of pragma names allowed under `SQLITE_PRAGMA`, compared
  case-insensitively. Optional, and absent means the empty allowlist, so every
  pragma is denied.
- Any other key, a non-array value, a non-integer or out-of-range code, or a
  non-string pragma name raises.

The policy is fail-closed. An action code outside `[0, 63]`, a pragma whose name
sqlite does not supply, and a pragma not on the allowlist all deny. A registration
that raises leaves the connection denying every action until a valid spec or `nil`
is installed, so a rejected policy can never read as permissive. The installed
policy is owned by the connection and freed on re-registration, `db.authorizer(nil)`,
`db.close`, and garbage collection; it is independent of the coroutine that
registered it.

`db.progress(n, budget)` installs a VDBE step budget enforced in C with no Lua
callback: the handler ticks every `n` VDBE ops and interrupts the running statement
(it errors with "interrupted") once `budget` ticks have elapsed. Calling it again
re-arms and zeroes the tick count; `db.progress(nil)` uninstalls. The count is
per connection and spans statements, so re-arm before each unit of work you want
budgeted:

```lua
db.progress(1000, 10000)
```

Anchor: `test/spec/santoku/sqlite/db.lua` ("complete detects statement boundaries",
"query returns rows and column names for ad-hoc sql", "authorizer policy denies codes
and gates pragmas", "authorizer policy rejects malformed specs and denies after",
"progress budget interrupts a runaway query", "authorizer policy survives the coroutine
that installed it", "closed handles and finalized statements raise").

## Gotchas

- The factories return a closure; `iter`/`all` need a second call to bind and run. Reuse
  the factory result; do not re-prepare per row.
- A prepared closure holds one statement. Driving the same `iter` closure to interleave
  two live cursors over the same SQL resets the shared statement; create two closures (or
  use `all`) if you need concurrent traversals.
- `search.add` expects `#ids` to equal the csr row count and every row to be non-empty;
  mismatches raise.
- carray reads the vec by reference for the duration of the step; do not free or resize
  the vec while a statement bound to it is running.
- `db.close` finalizes all cached statements first, then closes the connection. Closures
  created from a closed connection will fail.
