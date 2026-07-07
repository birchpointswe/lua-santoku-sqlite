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

## search: TF / cosine index

`search.create(db, opts)` builds tables `<name>_tf` and (when weighted) `<name>_doc`.
Documents are `csr` rows: ids are token ids, values are term weights.

### Weighted (cosine), the default

```lua
local search = require("santoku.sqlite.search")
local ivec, fvec, csr = require("santoku.ivec"), require("santoku.fvec"), require("santoku.csr")

local idx = search.create(db, { name = "docs" })

-- three docs in one batch: a={1,2,3}, b={2,3,4}, c={5,6}
idx.add(
  { "a", "b", "c" },
  csr.create({
    offsets   = ivec.create({ 0, 3, 6, 8 }),
    neighbors = ivec.create({ 1, 2, 3, 2, 3, 4, 5, 6 }),
    values    = fvec.create({ 1, 1, 1, 1, 1, 1, 1, 1 }),
  }))

-- query tokens {2,3}: matches a and b, score = cosine
local hits = idx.search(
  csr.create({ offsets = ivec.create({0,2}), neighbors = ivec.create({2,3}), values = fvec.create({1,1}) }),
  10)                                           -- { { id = "a", score = ... }, ... }
```

`add` replaces a doc's prior rows (re-adding an id with new tokens reindexes it). `remove`
takes an id list; `clear` empties the index. A weighted index requires a csr with values;
an empty token row in a batch raises (and inside `db.transaction` the whole batch rolls
back).

### Presence-only

```lua
local idx = search.create(db, { name = "pres", weighted = false })   -- ranks by match count
idx.add({ "a", "b" }, csr.create({ offsets = ivec.create({0,3,5}), neighbors = ivec.create({1,2,3,1,4}) }))
-- query {1,2,3}: a matches 3, b matches 1
```

### Partitioned

```lua
local idx = search.create(db, { name = "p", partition = true })
idx.add("u1", { "doc1" }, q_csr)                -- every call takes a leading partition
idx.search("u1", q_csr, 10)
idx.clear("u1")                                 -- isolated from u2
```

Anchor: `test/spec/santoku/sqlite/search.lua` (all five scenarios above plus the
transaction-rollback case).

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
