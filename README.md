# santoku-sqlite

A SQLite binding for Lua: a small C core (`santoku.sqlite.db`) over the SQLite C API,
a Lua wrapper (`santoku.sqlite`) that turns prepared statements into reusable query
closures with transaction control, and two extras built on top: a carray virtual table
that binds santoku-matrix vectors as zero-copy SQL inputs, and a TF/cosine document
search index (`santoku.sqlite.search`).

This README is a usage guide, not an API reference. **The tests are the spec**: each
section names the test that exercises its full surface. Read those for the exhaustive
behaviour; read this (and [`doc/usage.md`](doc/usage.md)) for the shape and conventions.

Vector and CSR types (`ivec`/`svec`/`fvec`/`dvec`/`csr`) are **santoku-matrix** types;
this doc uses them for the carray and search paths but does not re-explain them, see the
[matrix README](../lua-santoku-matrix/README.md). Errors, `assert`, and `pcall` come from
base **santoku** (`santoku.error`), see the [santoku README](../lua-santoku/README.md).

## Layers

- `santoku.sqlite.db` (C): the raw binding. `open`/`open_memory`/`open_v2` return a
  connection userdata; `:prepare`, `:exec`, `:step`, `:bind_*`, `:get_*` map onto the
  SQLite C calls. You can use this directly (see the carray test), but most code goes
  through the wrapper.
- `santoku.sqlite` (Lua): `local sql = require("santoku.sqlite")`. Call `sql(conn)` to
  wrap a connection; you get `exec`, the query-closure factories (`runner`/`getter`/
  `iter`/`all`/`inserter`), and transaction control (`transaction`/`begin`/`commit`/
  `rollback`/`close`). This is the front door.
- `santoku.sqlite.search` (Lua): a per-token inverted index over a wrapped connection,
  fed and queried with `csr` rows. Optional weighting (cosine over TF) and partitioning.
- carray: not a module. It is a SQLite virtual table the C core registers on every
  connection. Pass a vec where a statement parameter is expected and it becomes a
  zero-copy table-valued input: `select value from carray(?)`.

## Conventions

- **Wrap once.** `sql(conn)` returns a table of closures bound to that connection. The
  raw connection stays reachable as `db.db` for the few things the wrapper does not cover
  (used by `search` and the carray test).
- **Statements are cached in the closure.** Each factory call (`db.runner(sql)`,
  `db.getter(sql)`, ...) prepares once and returns a closure that resets and re-binds on
  every call. Reuse the closure; do not re-create it per row.
- **Errors raise.** The wrapper checks return codes and raises through `santoku.error`
  (message plus SQLite errcode), so wrap calls in `pcall` if you want to recover. The C
  layer returns raw integer codes (`OK`/`ROW`/`DONE`); the wrapper interprets them.
- **`prop` selects the row shape.** `nil`/omitted gives the first column value; `true`
  gives a `{ column = value }` table; `false` discards results (for statements run only
  for their side effects).
- **Binding is positional or named.** Pass values for `?1`/`?` positionally, or pass a
  single table for `:name` parameters. Numbers, strings (with embedded zeros), booleans,
  and `nil` (SQL null) all bind; a vec userdata binds as a carray.

## The core path: open, exec, query

```lua
local sqlite = require("santoku.sqlite.db")
local sql    = require("santoku.sqlite")

local db = sql(sqlite.open_memory())          -- or sqlite.open(path) / sqlite.open_v2(path, vfs)

db.exec([[ create table cities (name text, state text) ]])

local addcity = db.runner("insert into cities (name, state) values (?, ?)")
addcity("Tampa", "Florida")
addcity("Albany", "New York")

local getcity = db.getter("select * from cities where name = ?", true)   -- prop=true -> row table
getcity("Tampa")                              -- { name = "Tampa", state = "Florida" }

local getstate = db.getter("select state from cities where name = ?")    -- prop nil -> first column
getstate("Albany")                            -- "New York"

for row in db.iter("select * from cities", true)() do                    -- streaming iterator
  -- row.name, row.state
end

local all = db.all("select * from cities", true)()                       -- list of row tables

db.close()
```

Anchor test: `test/spec/santoku/sqlite.lua`.

## Encrypted databases

`sqlite.open_encrypted(path, key, [parent_vfs])` opens a database whose every
byte on disk is encrypted — pages, rollback journal and transient files alike.
`key` must be exactly 32 raw bytes (`santoku-monocypher`'s `key:bytes()` /
`key:derive(label):bytes()` produce one). `parent_vfs` names the VFS to sit on
top of, defaulting to the platform default; pass `"opfs-coop"` in the browser.

```lua
local sqlite = require("santoku.sqlite.db")
local sql    = require("santoku.sqlite")

local raw = sqlite.open_encrypted("notes.db", key)   -- key = 32 raw bytes
local db  = sql(raw)
db.exec([[ create table notes (id integer primary key, body text) ]])
db.runner("insert into notes (id, body) values (?, ?)")(1, "secret")
raw:close_vm()                                       -- finalize cached statements
raw:close()                                          -- releases the key
```

On disk the file starts with a `TKSQENC1` container header (magic, version,
block size, logical size, per-file salt) followed by one frame per block:
`nonce(24) || ciphertext || tag(16)`. Because the shim remaps offsets and
reports the logical size itself, no reserved-bytes pragma is needed and the
journal is covered too — the SQLite header, schema and row data never appear in
cleartext. Each block is sealed with XChaCha20-Poly1305 under a fresh random
nonce on every write, with the file salt and block index as associated data, so
blocks cannot be reordered, replayed or moved between files, and a wrong key or
tampered page fails the read rather than returning garbage.

### Cross-database reads

`ATTACH` works across databases with *different* keys, which is how you query
several encrypted databases at once. SQLite opens an attached file itself, so
its key must be registered up front with `key_set(path, key, [parent_vfs])`
(released with `key_clear`; registrations are refcounted and `open_encrypted`
counts as one).

Attached databases inherit the **connection's** VFS, so the connection has to be
on the encrypting VFS already — a plain connection cannot read an encrypted
attach. `enc_vfs([parent_vfs])` returns the shim's name for exactly this, which
lets the merging connection keep an in-memory `main` and persist nothing:

```lua
sqlite.key_set("a.db", key_a)
sqlite.key_set("b.db", key_b)

local raw = sqlite.open_v2(":memory:", sqlite.enc_vfs())  -- main is in-memory
local db  = sql(raw)
db.exec("attach database 'a.db' as s1")
db.exec("attach database 'b.db' as s2")
db.getter("select count(*) as n from (select id from s1.notes union all select id from s2.notes)", "n")()
```

Keep such a connection read-only: a transaction spanning two attached databases
makes SQLite create a super-journal, which the shim cannot key (it would get an
ephemeral key, so crash *recovery* would fail). Writing to one database per
transaction avoids super-journals entirely.

`search.create(db, { name = ..., schema = "s1" })` puts a search index in an
attached schema so it can participate in these cross-database queries.

Notes and limits:

- WAL is not available through the shim (its io-methods are iVersion 1); keep
  the database in a rollback journal mode.
- `SQLITE_MAX_ATTACHED` is the stock 10, so at most ten databases at once.
- Reopening a path that is still open with a *different* key is refused
  (`"database already open with a different key"`) rather than silently reusing
  the registered one.
- The key is released when the connection closes; call `close_vm()` first so
  `close()` is not blocked by cached statements.
- Requires `santoku-monocypher` (its crypto core is header-only), so the project
  keeps a single crypto implementation.

Anchor test: `test/spec/santoku/sqlite/enc.lua`.

## Query-closure factories

All factories prepare the SQL once and return a closure. The closure binds its arguments
(positional or a single named table), runs the statement, and resets it.

| Factory | Closure returns | Use |
|---------|-----------------|-----|
| `db.runner(sql)` | `-` | DDL and writes run for side effects only |
| `db.getter(sql[, prop])` | first row (shape by `prop`) | single-row reads |
| `db.iter(sql[, prop])` | a stepping iterator function | streaming `for` loops |
| `db.all(sql[, prop])` | a list of all rows | small result sets in memory |
| `db.inserter(sql)` | `last_insert_rowid()` | inserts that need the new rowid |

`db.exec(sql)` runs SQL directly with no prepared statement or binding (multi-statement
DDL scripts). See `doc/usage.md` for the per-factory examples and the `prop` matrix.

## Transactions

`db.transaction(fn, ...)` runs `fn` inside `begin immediate` / `commit`, rolling back and
re-raising if `fn` errors. A leading string selects the mode: `db.transaction("deferred",
fn, ...)`. Nested calls reuse the outer transaction (the inner call just runs `fn`), so
helpers that each open a transaction compose without error. Every factory closure already
wraps its body in `transaction`, so prepared statements are created inside one.

`db.begin([mode])`, `db.commit()`, `db.rollback()` are the manual primitives if you need
explicit control. Anchor: the transaction and nested-transaction cases in
`test/spec/santoku/sqlite.lua`.

## carray: bind a vector as a table-valued input

The C core registers a `carray` virtual table on every connection. Anywhere a parameter
is expected, pass a santoku-matrix vec and it is exposed as rows of a single `value`
column, read directly from the vec's backing store (no copy). Element type follows the
vec: `ivec` to int64, `svec` to int32, `fvec` to float, `dvec` to double.

```lua
local ivec = require("santoku.ivec")
local q = db.all("select value from carray(?) order by rowid", true)
q(ivec.create({ 10, 20, 30 }))                -- { {value=10}, {value=20}, {value=30} }
```

For partial binds use the raw statement method `stmt:bind_carray(pidx, vec[, start, count])`,
which binds a `[start, start+count)` slice and raises on an out-of-range slice. Anchor
test: `test/spec/santoku/sqlite/carray.lua`.

## search: TF / cosine document index

`santoku.sqlite.search` builds an inverted index in two tables (`<name>_tf`, `<name>_doc`)
on a wrapped connection. Documents and queries are `csr` rows: column ids are token ids,
values are term weights. Tokens and weights cross into SQL through carray, so indexing a
batch is one statement per document, not one per token.

```lua
local search = require("santoku.sqlite.search")
local csr    = require("santoku.csr")

local idx = search.create(db, { name = "docs" })     -- weighted (cosine) by default
idx.add({ "a", "b", "c" }, csr_of_three_rows)        -- ids list + one csr row per id
local hits = idx.search(query_csr, 10)               -- { { id = ..., score = ... }, ... }
idx.remove({ "a" })
idx.clear()
```

`search.create(db, opts)` options: `name` (table prefix, must be a valid identifier),
`weighted` (default `true`; `false` ranks by match count and needs no values),
`partition` (default `false`; when `true`, every call takes a leading partition string and
namespaces are isolated). The returned table has `add`, `remove`, `clear`, `search`. With
`partition = true` the signatures gain a leading partition: `idx.add(part, ids, csr)`,
`idx.search(part, csr, limit)`, `idx.clear(part)`. Anchor test:
`test/spec/santoku/sqlite/search.lua`.

## Building / testing

This repo uses the `toku` build harness. The C core links a bundled SQLite amalgamation
(see `make.lua`). Tests live in `test/spec/santoku/`; run them through `toku` so the
native module is compiled and on the path. Runtime dependency: base `santoku`. The tests
additionally depend on `santoku-matrix` for the vec/csr types used by carray and search.

## License

MIT License

Copyright 2025 Birch Point SWE

Permission is hereby granted, free of charge, to any person obtaining a copy of
this software and associated documentation files (the "Software"), to deal in
the Software without restriction, including without limitation the rights to
use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of
the Software, and to permit persons to whom the Software is furnished to do so,
subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS
FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER
IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
