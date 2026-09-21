local err = require("santoku.error")
local arr = require("santoku.array")
local str = require("santoku.string")
local error = err.error
local assert = err.assert

local ROW, DONE = 100, 101

local B36 = "0123456789abcdefghijklmnopqrstuvwxyz"

local function valid_name (s)
  return type(s) == "string" and s:match("^[%a_][%w_]*$") ~= nil
end

local function b36 (n)
  if n == 0 then
    return "t0"
  end
  local s = ""
  while n > 0 do
    local r = n % 36
    s = str.sub(B36, r + 1, r + 1) .. s
    n = (n - r) / 36
  end
  return "t" .. s
end

local function encode_row (offs, nbrs, vals, i)
  local lo, hi = offs:get(i), offs:get(i + 1)
  if hi <= lo then
    return nil
  end
  local out, n = {}, 0
  for j = lo, hi - 1 do
    local t = b36(nbrs:get(j))
    local reps = vals and vals:get(j) or 1
    if reps < 1 then reps = 1 end
    for _ = 1, reps do
      n = n + 1
      out[n] = t
    end
  end
  return arr.concat(out, " ")
end

local function encode_match (offs, nbrs, i)
  local lo, hi = offs:get(i), offs:get(i + 1)
  if hi <= lo then
    return nil
  end
  local seen, out, n = {}, {}, 0
  for j = lo, hi - 1 do
    local t = b36(nbrs:get(j))
    if not seen[t] then
      seen[t] = true
      n = n + 1
      out[n] = "\"" .. t .. "\""
    end
  end
  return arr.concat(out, " OR ")
end

local function drive (rawdb, stmt)
  while true do
    local res = stmt:step()
    if res == DONE then
      stmt:reset()
      return
    elseif res ~= ROW then
      local msg, code = rawdb:errmsg(), rawdb:errcode()
      stmt:reset()
      return error(msg, code)
    end
  end
end

local function create (db, opts)
  assert(type(opts) == "table", "fts.create: opts table required")
  local name = opts.name
  assert(valid_name(name), "fts.create: opts.name must be a valid identifier")
  local schema = opts.schema
  if schema ~= nil then
    assert(valid_name(schema), "fts.create: opts.schema must be a valid identifier")
  end
  local detail = opts.detail or "full"
  assert(detail == "full" or detail == "column" or detail == "none",
    "fts.create: opts.detail must be full, column or none")
  local tbl = schema and (schema .. "." .. name) or name
  local rawdb = db.db

  db.exec(
    "create table if not exists " .. tbl .. "_map (rid integer primary key, id text unique);" ..
    "create virtual table if not exists " .. tbl .. "_ft using fts5(" ..
    "body, tokenize=unicode61, detail=" .. detail .. ");")

  local get_rid = db.getter("select rid as rid from " .. tbl .. "_map where id = ?1", "rid")
  local put_id = db.inserter("insert into " .. tbl .. "_map (id) values (?1)")
  local del_map = db.runner("delete from " .. tbl .. "_map where id = ?1")
  local clear_map = db.runner("delete from " .. tbl .. "_map")
  local clear_ft = db.runner("delete from " .. tbl .. "_ft")
  local del_ft = db.runner("delete from " .. tbl .. "_ft where rowid = ?1")
  local ins_ft = rawdb:prepare(
    "insert into " .. tbl .. "_ft (rowid, body) values (?1, ?2)")
  local search_stmt = rawdb:prepare(
    "select m.id as id, bm25(" .. name .. "_ft) as score " ..
    "from " .. tbl .. "_ft join " .. tbl .. "_map m on m.rid = " .. name .. "_ft.rowid " ..
    "where " .. name .. "_ft match ?1 order by score limit ?2")

  local function rid_for (id)
    local rid = get_rid(id)
    if rid == nil then
      rid = put_id(id)
    end
    return rid
  end

  local function del_one (id)
    local rid = get_rid(id)
    if rid ~= nil then
      del_ft(rid)
      del_map(id)
    end
  end

  local function add (ids, csr)
    assert(type(ids) == "table", "fts.add: ids must be a list")
    local offs = csr:offsets()
    local nbrs = csr:neighbors()
    local vals = csr:values()
    local ndocs = offs:size() - 1
    if #ids ~= ndocs then
      return error("fts.add: ids length (" .. #ids ..
        ") does not match CSR rows (" .. ndocs .. ")")
    end
    for i = 0, ndocs - 1 do
      local body = encode_row(offs, nbrs, vals, i)
      if body == nil then
        return error("fts.add: empty token row at id index " .. (i + 1))
      end
      local id = ids[i + 1]
      del_one(id)
      local rid = rid_for(id)
      ins_ft:reset()
      ins_ft:bind_values(rid, body)
      drive(rawdb, ins_ft)
    end
  end

  local function remove (ids)
    assert(type(ids) == "table", "fts.remove: ids must be a list")
    for i = 1, #ids do
      del_one(ids[i])
    end
  end

  local function clear ()
    clear_ft()
    clear_map()
  end

  local function search (csr, limit)
    limit = limit or 50
    local m = encode_match(csr:offsets(), csr:neighbors(), 0)
    if m == nil then
      return {}
    end
    search_stmt:reset()
    search_stmt:bind_values(m, limit)
    local out = {}
    while true do
      local res = search_stmt:step()
      if res == ROW then
        out[#out + 1] = search_stmt:get_named_values()
      elseif res == DONE then
        search_stmt:reset()
        break
      else
        local msg, code = rawdb:errmsg(), rawdb:errcode()
        search_stmt:reset()
        return error(msg, code)
      end
    end
    return out
  end

  return {
    add = add,
    remove = remove,
    clear = clear,
    search = search,
  }
end

return { create = create }
