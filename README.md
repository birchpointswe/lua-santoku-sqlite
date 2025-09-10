# Santoku SQLite

SQLite database wrapper for Lua with transaction management and prepared statement caching.

## Module Reference

### `santoku.sqlite`

| Function | Arguments | Returns | Description |
|----------|-----------|---------|-------------|
| `sqlite` | `path` | `db` | Opens SQLite database at path |

### Database Object

| Function | Arguments | Returns | Description |
|----------|-----------|---------|-------------|
| `db.exec` | `sql` | `-` | Executes SQL statement without results |
| `db.transaction` | `[tag,] fn, ...` | `...` | Runs function in transaction, auto-commits on success, rolls back on error |
| `db.begin` | `[type]` | `-` | Starts transaction (type: `"deferred"`, `"immediate"`, `"exclusive"`) |
| `db.commit` | `-` | `-` | Commits current transaction |
| `db.rollback` | `-` | `-` | Rolls back current transaction |
| `db.close` | `-` | `-` | Closes database connection |

### Query Functions

| Function | Arguments | Returns | Description |
|----------|-----------|---------|-------------|
| `db.iter` | `sql, [prop]` | `fn, reset` | Returns iterator function and reset function for query |
| `db.all` | `sql, [prop]` | `fn` | Returns function that executes query and returns all results |
| `db.runner` | `sql` | `fn` | Returns function that executes statement without returning results |
| `db.getter` | `sql, [prop]` | `fn` | Returns function that executes query and returns first row |
| `db.inserter` | `sql` | `fn` | Returns function that executes insert and returns last insert rowid |

### Parameter Binding

Functions returned by query methods accept parameters:
- Positional: `fn(val1, val2, ...)`
- Named: `fn({ name1 = val1, name2 = val2 })`

### Result Format (`prop` parameter)

- `nil` or omitted: Returns first column value
- `true`: Returns table with column names as keys
- `false`: Returns nothing (for statements without results)

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