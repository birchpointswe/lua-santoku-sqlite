local err = require("santoku.error")
local error = err.error
local pcall = err.pcall

local varg = require("santoku.varg")
local vlen = varg.len
local vtup = varg.tup

local iter = require("santoku.iter")
local last = iter.last
local collect = iter.collect

local validate = require("santoku.validate")
local isprimitive = validate.isprimitive
local hasindex = validate.hasindex

local OK, ROW, DONE = 0, 100, 101

local function check (db, res, code, msg)
  if not res then
    if not msg and db then
      msg = db:errmsg()
    end
    if not code and db then
      code = db:errcode()
    end
    error(msg, code)
  else
    return res
  end
end

local function bind (stmt, ...)
  if vlen(...) == 0 then
    return stmt
  end
  local t = ...
  if not isprimitive(t) and hasindex(t) then
    return stmt:bind_names(t)
  else
    return stmt:bind_values(...)
  end
end

local function query (db, stmt, ...)
  stmt:reset()
  bind(stmt, ...)
  return function ()
    local res = stmt:step()
    if res == ROW then
      return stmt:get_named_values()
    elseif res == DONE then
      return
    else
      return error(db:errmsg(), db:errcode())
    end
  end
end

local function get_one (db, stmt, ...)
  stmt:reset()
  bind(stmt, ...)
  local res = stmt:step()
  if res == ROW then
    local val = stmt:get_named_values()
    return val
  elseif res == DONE then
    return
  else
    return error(db:errmsg(), db:errcode())
  end
end

local function get_val (db, stmt, prop, ...)
  local val = get_one(db, stmt, ...)
  if val then
    return val[prop]
  end
end

local function wrap (...)

  local db = check(nil, ...)

  local function begin ()
    local res = db:exec("begin;")
    if res ~= OK then
      error(db:errmsg(), db:errcode())
    end
  end

  local function commit ()
    local res = db:exec("commit;")
    if res ~= OK then
      error(db:errmsg(), db:errcode())
    end
  end

  local function rollback ()
    local res = db:exec("rollback;")
    if res ~= OK then
      error(db:errmsg(), db:errcode())
    end
  end

  return {

    db = db,
    begin = begin,
    commit = commit,
    rollback = rollback,

    transaction = function (fn, ...)
      begin()
      return vtup(function (ok, ...)
        if not ok then
          rollback()
          error(...)
        else
          commit()
          return ...
        end
      end, pcall(fn, ...))
    end,

    exec = function (...)
      local res = db:exec(...)
      if res ~= OK then
        error(db:errmsg(), db:errcode())
      end
    end,

    iter = function (sql)
      local stmt = check(db, db:prepare(sql))
      return function (...)
        return query(db, stmt, ...)
      end
    end,

    all = function (sql)
      local stmt = check(db, db:prepare(sql))
      return function (...)
        return collect(query(db, stmt, ...))
      end
    end,

    runner = function (sql)
      local stmt = check(db, db:prepare(sql))
      return function (...)
        return last(query(db, stmt, ...))
      end
    end,

    getter = function (sql, prop)
      local stmt = check(db, db:prepare(sql))
      if prop then
        return function (...)
          return get_val(db, stmt, prop, ...)
        end
      else
        return function (...)
          return get_one(db, stmt, ...)
        end
      end
    end,

    inserter = function (sql)
      local stmt = check(db, db:prepare(sql))
      return function (...)
        get_one(db, stmt, ...)
        return db:last_insert_rowid()
      end
    end,

  }
end

return wrap
