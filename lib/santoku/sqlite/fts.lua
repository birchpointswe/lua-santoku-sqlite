local err = require("santoku.error")
local error = err.error
local assert = err.assert

local ROW, DONE = 100, 101

local function valid_name (s)
  return type(s) == "string" and s:match("^[%a_][%w_]*$") ~= nil
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
    "body, content='', contentless_delete=1, tokenize='santoku', detail=" ..
    detail .. ");")

  local get_rid = db.getter("select rid as rid from " .. tbl .. "_map where id = ?1", "rid")
  local put_id = db.inserter("insert into " .. tbl .. "_map (id) values (?1)")
  local del_map = db.runner("delete from " .. tbl .. "_map where id = ?1")
  local clear_map = db.runner("delete from " .. tbl .. "_map")
  local clear_ft = db.runner("delete from " .. tbl .. "_ft")
  local del_ft = db.runner("delete from " .. tbl .. "_ft where rowid = ?1")
  local ins_ft = rawdb:prepare(
    "insert into " .. tbl .. "_ft (rowid, body) values (?1, ?2)")
  local search_stmt = rawdb:prepare(
    "select m.id as id, santoku_bm25(" .. name .. "_ft, ?3) as score, " ..
    "santoku_bm25_max(" .. name .. "_ft, ?3) as maxw " ..
    "from " .. tbl .. "_ft join " .. tbl .. "_map m on m.rid = " .. name .. "_ft.rowid " ..
    "where " .. name .. "_ft match ?2 order by score limit ?1")

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
      local lo = offs:get(i)
      local len = offs:get(i + 1) - lo
      if len <= 0 then
        return error("fts.add: empty token row at id index " .. (i + 1))
      end
      local id = ids[i + 1]
      del_one(id)
      local rid = rid_for(id)
      ins_ft:reset()
      ins_ft:bind_values(rid)
      ins_ft:bind_tokens(2, nbrs, vals, lo, len)
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
    local offs = csr:offsets()
    local nbrs = csr:neighbors()
    local vals = csr:values()
    local lo = offs:get(0)
    local len = offs:get(1) - lo
    if len <= 0 then
      return {}
    end
    search_stmt:reset()
    search_stmt:bind_values(limit or 50)
    if search_stmt:bind_match(2, nbrs, lo, len) == nil then
      search_stmt:reset()
      return {}
    end
    if vals then
      search_stmt:bind_weights(3, vals, lo, len)
    end
    local out = {}
    while true do
      local res = search_stmt:step()
      if res == ROW then
        local row = search_stmt:get_named_values()
        local c = row.maxw > 0 and -row.score / row.maxw or 0
        row.coverage = c > 1 and 1 or c
        row.maxw = nil
        out[#out + 1] = row
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
