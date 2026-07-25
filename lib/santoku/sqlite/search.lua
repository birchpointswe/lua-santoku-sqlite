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
  local pname
  if opts.partition == true then
    pname = "part"
  elseif type(opts.partition) == "string" then
    pname = opts.partition
  end
  if pname ~= nil then
    assert(valid_name(pname), "search.create: partition column must be a valid identifier")
    assert(pname ~= "id" and pname ~= "token" and pname ~= "tf" and pname ~= "norm",
      "search.create: partition column name conflicts with a reserved column")
  end
  local partition = pname ~= nil
  local weighted = opts.weighted
  if weighted == nil then weighted = true end
  local rawdb = db.db






  local schema = opts.schema
  if schema ~= nil then
    assert(valid_name(schema), "search.create: opts.schema must be a valid identifier")
  end
  local tbl = schema and (schema .. "." .. name) or name

  local pcol = partition and (pname .. " text not null, ") or ""
  local ppk = partition and (pname .. ", ") or ""
  local idcols = partition and (pname .. ", id, ") or "id, "
  local idsel = partition and "?1, ?2" or "?1"
  local tok_p = partition and 3 or 2

  local ddl =
    "create table if not exists " .. tbl .. "_tf (" .. pcol .. "id, token integer not null" ..
    (weighted and ", tf real not null" or "") .. ");" ..
    "create index if not exists " .. tbl .. "_tf_tok on " .. name .. "_tf (" .. ppk .. "token);" ..
    "create index if not exists " .. tbl .. "_tf_id on " .. name .. "_tf (" .. ppk .. "id);"
  if weighted then
    ddl = ddl ..
      "create table if not exists " .. tbl .. "_doc (" .. pcol ..
      "id, norm real not null, primary key (" .. ppk .. "id));"
  end
  db.exec(ddl)

  local insert_tf, insert_tf_counted, insert_doc, insert_doc_counted
  if weighted then
    insert_tf = rawdb:prepare(
      "insert into " .. tbl .. "_tf (" .. idcols .. "token, tf) " ..
      "select " .. idsel .. ", t.value, w.value " ..
      "from carray(?" .. tok_p .. ") t join carray(?" .. (tok_p + 1) .. ") w on t.rowid = w.rowid")
    insert_tf_counted = rawdb:prepare(
      "insert into " .. tbl .. "_tf (" .. idcols .. "token, tf) " ..
      "select " .. idsel .. ", t.value, count(*) " ..
      "from carray(?" .. tok_p .. ") t group by t.value")
    insert_doc = rawdb:prepare(
      "insert into " .. tbl .. "_doc (" .. idcols .. "norm) " ..
      "select " .. idsel .. ", sqrt(sum(w.value * w.value)) from carray(?" .. tok_p .. ") w")
    insert_doc_counted = rawdb:prepare(
      "insert into " .. tbl .. "_doc (" .. idcols .. "norm) " ..
      "select " .. idsel .. ", sqrt(sum(c * c)) " ..
      "from (select count(*) c from carray(?" .. tok_p .. ") t group by t.value)")
  else
    insert_tf = rawdb:prepare(
      "insert into " .. tbl .. "_tf (" .. idcols .. "token) " ..
      "select " .. idsel .. ", t.value from carray(?" .. tok_p .. ") t")
  end

  local s_limit_p = partition and 2 or 1
  local s_qtok_p = partition and 3 or 2
  local s_qval_p = s_qtok_p + 1
  local docjoin = "join " .. tbl .. "_doc d on " ..
    (partition and ("d." .. pname .. " = s." .. pname .. " and ") or "") .. "d.id = s.id "
  local pwhere = partition and ("where s." .. pname .. " = ?1 ") or ""
  local search_stmt, search_stmt_counted
  if weighted then
    search_stmt = rawdb:prepare(
      "select s.id as id, sum(s.tf * q.tf) / " ..
      "(d.norm * (select sqrt(sum(value * value)) from carray(?" .. s_qval_p .. "))) as score " ..
      "from " .. tbl .. "_tf s " ..
      "join (select t.value as token, w.value as tf from carray(?" .. s_qtok_p .. ") t " ..
      "join carray(?" .. s_qval_p .. ") w on t.rowid = w.rowid) q on s.token = q.token " ..
      docjoin .. pwhere ..
      "group by s.id order by score desc limit ?" .. s_limit_p)
    search_stmt_counted = rawdb:prepare(
      "select s.id as id, sum(s.tf * q.tf) / " ..
      "(d.norm * (select sqrt(sum(c * c)) from " ..
      "(select count(*) c from carray(?" .. s_qtok_p .. ") t group by t.value))) as score " ..
      "from " .. tbl .. "_tf s " ..
      "join (select t.value as token, count(*) as tf from carray(?" .. s_qtok_p .. ") t " ..
      "group by t.value) q on s.token = q.token " ..
      docjoin .. pwhere ..
      "group by s.id order by score desc limit ?" .. s_limit_p)
  else
    search_stmt = rawdb:prepare(
      "select s.id as id, count(*) as score " ..
      "from " .. tbl .. "_tf s " ..
      "join (select value as token from carray(?" .. s_qtok_p .. ")) q on s.token = q.token " ..
      pwhere ..
      "group by s.id order by score desc limit ?" .. s_limit_p)
  end

  local del_tf, del_doc, clear_tf, clear_doc
  if partition then
    del_tf = db.runner("delete from " .. tbl .. "_tf where " .. pname .. " = ?1 and id = ?2")
    clear_tf = db.runner("delete from " .. tbl .. "_tf where " .. pname .. " = ?1")
    if weighted then
      del_doc = db.runner("delete from " .. tbl .. "_doc where " .. pname .. " = ?1 and id = ?2")
      clear_doc = db.runner("delete from " .. tbl .. "_doc where " .. pname .. " = ?1")
    end
  else
    del_tf = db.runner("delete from " .. tbl .. "_tf where id = ?1")
    clear_tf = db.runner("delete from " .. tbl .. "_tf")
    if weighted then
      del_doc = db.runner("delete from " .. tbl .. "_doc where id = ?1")
      clear_doc = db.runner("delete from " .. tbl .. "_doc")
    end
  end

  local function del_one (part, id)
    if partition then del_tf(part, id) else del_tf(id) end
    if weighted then
      if partition then del_doc(part, id) else del_doc(id) end
    end
  end

  local function bind_id (stmt, part, id)
    if partition then stmt:bind_values(part, id) else stmt:bind_values(id) end
  end

  local function add (...)
    local part, ids, csr
    if partition then part, ids, csr = ... else ids, csr = ... end
    assert(type(ids) == "table", "search.add: ids must be a list")
    local offs = csr:offsets()
    local toks = csr:neighbors()
    local vals = weighted and csr:values() or nil
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
      if not weighted then
        insert_tf:reset()
        bind_id(insert_tf, part, id)
        insert_tf:bind_carray(tok_p, toks, lo, len)
        drive(rawdb, insert_tf)
      elseif vals then
        insert_tf:reset()
        bind_id(insert_tf, part, id)
        insert_tf:bind_carray(tok_p, toks, lo, len)
        insert_tf:bind_carray(tok_p + 1, vals, lo, len)
        drive(rawdb, insert_tf)
        insert_doc:reset()
        bind_id(insert_doc, part, id)
        insert_doc:bind_carray(tok_p, vals, lo, len)
        drive(rawdb, insert_doc)
      else
        insert_tf_counted:reset()
        bind_id(insert_tf_counted, part, id)
        insert_tf_counted:bind_carray(tok_p, toks, lo, len)
        drive(rawdb, insert_tf_counted)
        insert_doc_counted:reset()
        bind_id(insert_doc_counted, part, id)
        insert_doc_counted:bind_carray(tok_p, toks, lo, len)
        drive(rawdb, insert_doc_counted)
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
    local lo = offs:get(0)
    local len = offs:get(1) - lo
    if len <= 0 then return {} end
    local stmt = (weighted and not vals) and search_stmt_counted or search_stmt
    stmt:reset()
    if partition then stmt:bind_values(part, limit) else stmt:bind_values(limit) end
    stmt:bind_carray(s_qtok_p, toks, lo, len)
    if weighted and vals then stmt:bind_carray(s_qval_p, vals, lo, len) end
    local out = {}
    while true do
      local res = stmt:step()
      if res == ROW then
        out[#out + 1] = stmt:get_named_values()
      elseif res == DONE then
        stmt:reset()
        break
      else
        local msg, code = rawdb:errmsg(), rawdb:errcode()
        stmt:reset()
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
