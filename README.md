<p align="center">
  <img src="https://santoku.dev/logo-santoku-sqlite.png" height="64" alt="santoku-sqlite">
</p>

# santoku-sqlite

SQLite for Lua, with the amalgamation vendored in. Prepared statements are exposed as
ordinary Lua functions, transactions take a Lua function, and the package adds a
page-level encryption layer, a trigram search index, and trigger-driven peer-to-peer
sync on top of the raw bindings.

## Install

```sh
luarocks install santoku-sqlite
```

## Example

```lua
local sqlite = require("santoku.sqlite.db")
local sql = require("santoku.sqlite")

local db = sql(sqlite.open_memory())

db.exec("create table cities (name text, state text)")

local add = db.runner("insert into cities (name, state) values (?, ?)")
local get = db.getter("select state from cities where name = ?")

add("Tampa", "Florida")

print(get("Tampa"))
```

`runner`, `getter`, `iter`, `all`, and `inserter` each prepare the statement once and hand
back a function; passing `true` asks for whole rows as tables instead of single values.

## Documentation

Runnable examples and the full API: [santoku.dev](https://santoku.dev/#santoku-sqlite).

For agents and LLM tooling: [llms.txt](https://santoku.dev/llms.txt) for the index,
[llms-full.txt](https://santoku.dev/llms-full.txt) for every documented example.

## Tests

The tests are the spec. For the exhaustive surface, read them:
[`test/spec/santoku/sqlite/db.lua`](test/spec/santoku/sqlite/db.lua),
[`test/spec/santoku/sqlite/enc.lua`](test/spec/santoku/sqlite/enc.lua),
[`test/spec/santoku/sqlite/search.lua`](test/spec/santoku/sqlite/search.lua),
[`test/spec/santoku/sqlite/sync.lua`](test/spec/santoku/sqlite/sync.lua), and
[`test/spec/santoku/sqlite/carray.lua`](test/spec/santoku/sqlite/carray.lua).

## License

MIT, see [LICENSE](LICENSE).

## More examples

```lua
local test = require("santoku.test")

local err = require("santoku.error")
local assert = err.assert

local validate = require("santoku.validate")
local eq = validate.isequal

local tbl = require("santoku.table")
local teq = tbl.equals

local arr = require("santoku.array")
local icollect = arr.icollect

local sqlite = require("santoku.sqlite.db")
local sql = require("santoku.sqlite")

local function cities ()
  local db = sql(sqlite.open_memory())
  db.exec("create table cities (name text, state text)")
  local add = db.runner("insert into cities (name, state) values (:name, :state)")
  add({ name = "Tampa", state = "Florida" })
  add({ name = "Miami", state = "Florida" })
  add({ name = "Albany", state = "New York" })
  return db
end

test("a prepared statement becomes a plain lua function", function ()
  local db = cities()
  local getcity = db.getter("select * from cities where name = ?", true)
  assert(teq({ name = "Tampa", state = "Florida" }, getcity("Tampa")))
  local getstate = db.getter("select state from cities where name = :name")
  assert(eq("New York", getstate({ name = "Albany" })))
end)

test("read a whole result set, or stream it row by row", function ()
  local db = cities()
  local all = db.all("select name from cities where state = ? order by name", true)
  assert(teq({ { name = "Miami" }, { name = "Tampa" } }, all("Florida")))
  local iter = db.iter("select name from cities order by name", true)
  assert(eq(3, #icollect(iter())))
end)

test("transactions take a lua function, and roll back cleanly", function ()
  local db = cities()
  local count = db.getter("select count(*) from cities")
  local add = db.inserter("insert into cities (name, state) values (?, ?)")
  db.transaction(function ()
    add("Buffalo", "New York")
  end)
  assert(eq(4, count()))
  db.begin()
  add("Nowhere", "Nowhere")
  db.rollback()
  assert(eq(4, count()))
  db.close()
end)
```
