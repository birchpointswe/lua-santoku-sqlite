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
  assert(type(opts) == "table", "search.create: opts table required")
  local name = opts.name
  assert(valid_name(name), "search.create: opts.name must be a valid identifier")
  local partition = opts.partition and true or false
  local weighted = opts.weighted
  if weighted == nil then weighted = true end
  local rawdb = db.db

  local pcol = partition and "part text not null, " or ""
  local ppk = partition and "part, " or ""
  local idcols = partition and "part, id, " or "id, "
  local idsel = partition and "?1, ?2" or "?1"
  local tok_p = partition and 3 or 2

  local ddl =
    "create table if not exists " .. name .. "_tf (" .. pcol .. "id, token integer not null" ..
    (weighted and ", tf real not null" or "") .. ");" ..
    "create index if not exists " .. name .. "_tf_tok on " .. name .. "_tf (" .. ppk .. "token);" ..
    "create index if not exists " .. name .. "_tf_id on " .. name .. "_tf (" .. ppk .. "id);"
  if weighted then
    ddl = ddl ..
      "create table if not exists " .. name .. "_doc (" .. pcol ..
      "id, norm real not null, primary key (" .. ppk .. "id));"
  end
  db.exec(ddl)

  local insert_tf
  if weighted then
    insert_tf = rawdb:prepare(
      "insert into " .. name .. "_tf (" .. idcols .. "token, tf) " ..
      "select " .. idsel .. ", t.value, w.value " ..
      "from carray(?" .. tok_p .. ") t join carray(?" .. (tok_p + 1) .. ") w on t.rowid = w.rowid")
  else
    insert_tf = rawdb:prepare(
      "insert into " .. name .. "_tf (" .. idcols .. "token) " ..
      "select " .. idsel .. ", t.value from carray(?" .. tok_p .. ") t")
  end

  local insert_doc
  if weighted then
    insert_doc = rawdb:prepare(
      "insert into " .. name .. "_doc (" .. idcols .. "norm) " ..
      "select " .. idsel .. ", sqrt(sum(w.value * w.value)) from carray(?" .. tok_p .. ") w")
  end

  local s_limit_p = partition and 2 or 1
  local s_qtok_p = partition and 3 or 2
  local s_qval_p = s_qtok_p + 1
  local search_sql
  if weighted then
    search_sql =
      "select s.id as id, sum(s.tf * q.tf) / " ..
      "(d.norm * (select sqrt(sum(value * value)) from carray(?" .. s_qval_p .. "))) as score " ..
      "from " .. name .. "_tf s " ..
      "join (select t.value as token, w.value as tf from carray(?" .. s_qtok_p .. ") t " ..
      "join carray(?" .. s_qval_p .. ") w on t.rowid = w.rowid) q on s.token = q.token " ..
      "join " .. name .. "_doc d on " .. (partition and "d.part = s.part and " or "") .. "d.id = s.id " ..
      (partition and "where s.part = ?1 " or "") ..
      "group by s.id order by score desc limit ?" .. s_limit_p
  else
    search_sql =
      "select s.id as id, count(*) as score " ..
      "from " .. name .. "_tf s " ..
      "join (select value as token from carray(?" .. s_qtok_p .. ")) q on s.token = q.token " ..
      (partition and "where s.part = ?1 " or "") ..
      "group by s.id order by score desc limit ?" .. s_limit_p
  end
  local search_stmt = rawdb:prepare(search_sql)

  local del_tf, del_doc, clear_tf, clear_doc
  if partition then
    del_tf = db.runner("delete from " .. name .. "_tf where part = ?1 and id = ?2")
    clear_tf = db.runner("delete from " .. name .. "_tf where part = ?1")
    if weighted then
      del_doc = db.runner("delete from " .. name .. "_doc where part = ?1 and id = ?2")
      clear_doc = db.runner("delete from " .. name .. "_doc where part = ?1")
    end
  else
    del_tf = db.runner("delete from " .. name .. "_tf where id = ?1")
    clear_tf = db.runner("delete from " .. name .. "_tf")
    if weighted then
      del_doc = db.runner("delete from " .. name .. "_doc where id = ?1")
      clear_doc = db.runner("delete from " .. name .. "_doc")
    end
  end

  local function del_one (part, id)
    if partition then del_tf(part, id) else del_tf(id) end
    if weighted then
      if partition then del_doc(part, id) else del_doc(id) end
    end
  end

  local function add (...)
    local part, ids, csr
    if partition then part, ids, csr = ... else ids, csr = ... end
    assert(type(ids) == "table", "search.add: ids must be a list")
    local offs = csr:offsets()
    local toks = csr:neighbors()
    local vals = weighted and csr:values() or nil
    if weighted and not vals then
      return error("search.add: weighted index requires a CSR with values")
    end
    local ndocs = offs:size() - 1
    if #ids ~= ndocs then
      return error("search.add: ids length (" .. #ids ..
        ") does not match CSR rows (" .. ndocs .. ")")
    end
    for i = 0, ndocs - 1 do
      local lo = offs:get(i)
      local len = offs:get(i + 1) - lo
      if len <= 0 then
        return error("search.add: empty token row at id index " .. (i + 1))
      end
      local id = ids[i + 1]
      del_one(part, id)
      insert_tf:reset()
      if partition then insert_tf:bind_values(part, id) else insert_tf:bind_values(id) end
      insert_tf:bind_carray(tok_p, toks, lo, len)
      if weighted then insert_tf:bind_carray(tok_p + 1, vals, lo, len) end
      drive(rawdb, insert_tf)
      if weighted then
        insert_doc:reset()
        if partition then insert_doc:bind_values(part, id) else insert_doc:bind_values(id) end
        insert_doc:bind_carray(tok_p, vals, lo, len)
        drive(rawdb, insert_doc)
      end
    end
  end

  local function remove (...)
    local part, ids
    if partition then part, ids = ... else ids = ... end
    assert(type(ids) == "table", "search.remove: ids must be a list")
    for i = 1, #ids do
      del_one(part, ids[i])
    end
  end

  local function clear (part)
    if partition then
      clear_tf(part)
      if weighted then clear_doc(part) end
    else
      clear_tf()
      if weighted then clear_doc() end
    end
  end

  local function search (...)
    local part, csr, limit
    if partition then part, csr, limit = ... else csr, limit = ... end
    limit = limit or 50
    local offs = csr:offsets()
    local toks = csr:neighbors()
    local vals = weighted and csr:values() or nil
    if weighted and not vals then
      return error("search.search: weighted index requires a CSR with values")
    end
    local lo = offs:get(0)
    local len = offs:get(1) - lo
    if len <= 0 then return {} end
    search_stmt:reset()
    if partition then search_stmt:bind_values(part, limit) else search_stmt:bind_values(limit) end
    search_stmt:bind_carray(s_qtok_p, toks, lo, len)
    if weighted then search_stmt:bind_carray(s_qval_p, vals, lo, len) end
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
