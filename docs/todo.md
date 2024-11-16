# Now

- Require the user use db.transaction(...) for everything, error if no
  transaction. This will help find accidental bugs.

- Helper for automatically computing column names for inserts and updates
- Gracefully handle nested transactions

- Allow prop for all and iter
- Instead of get_named_values, return an iterator over columns
- Instead of returning a new table every time, pass a table in

- Support sqlite "in" cluase with json_each
- Support iter:clone()/recompile

- Throw error when iter invoked twice on same prepared statement (user should
  call clone)

- Abstract database interface to work with luasql dbs (refer to the
  santoku.web.sqlite compatibility layer)
