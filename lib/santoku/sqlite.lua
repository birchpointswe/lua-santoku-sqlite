local err = require("santoku.error")
local error = err.error
local pcall = err.pcall

local varg = require("santoku.varg")
local vsel = varg.sel
local vtup = varg.tup

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

local function reset (db, stmt)
  local res = stmt:reset()
  if not (res == OK or res == ROW or res == DONE) then
    error(db:errmsg(), db:errcode())
  end
end

local function resetter (db, stmt)
  return function ()
    reset(db, stmt)
  end
end

local function bind (stmt, ...)
  if ... and type(...) == "table" then
    return stmt:bind_names((...))
  else
    return stmt:bind_values(...)
  end
end

local function run (db, stmt, prop, out, ...)
  reset(db, stmt)
  bind(stmt, ...)
  while true do
    local res = stmt:step()
    if res == ROW then -- luacheck: ignore
      if out then
        if type(prop) == "number" then
          out[#out + 1] = stmt:get_value(prop)
        else
          local val = stmt:get_named_values()
          if val and prop ~= nil then
            out[#out + 1] = val[prop]
          else
            out[#out + 1] = val
          end
        end
      end
    elseif res == DONE then
      reset(db, stmt)
      return out
    else
      reset(db, stmt)
      return error(db:errmsg(), db:errcode())
    end
  end
end


local function query (db, stmt, prop, ...)
  reset(db, stmt)
  bind(stmt, ...)
  return function ()
    local res = stmt:step()
    if res == ROW then
      if prop == false then
        return
      elseif type(prop) == "number" then
        return stmt:get_value(prop)
      else
        local val = stmt:get_named_values()
        if val and prop ~= nil then
          return val[prop]
        else
          return val
        end
      end
    elseif res == DONE then
      reset(db, stmt)
      return
    else
      reset(db, stmt)
      return error(db:errmsg(), db:errcode())
    end
  end
end

local function spread_finalize (n, db, stmt, ...)
  if n <= 0 then
    reset(db, stmt)
    return ...
  else
    n = n - 1
    local nval = stmt:get_value(n)
    return spread_finalize(n, db, stmt, nval, ...)
  end
end

local function get_one (db, stmt, prop, ...)
  bind(stmt, ...)
  local res = stmt:step()
  if res == ROW then
    if prop == false then
      reset(db, stmt)
      return
    elseif prop == true then
      local val = stmt:get_named_values()
      reset(db, stmt)
      return val
    elseif type(prop) == "number" then
      local val = stmt:get_value(prop - 1)
      reset(db, stmt)
      return val
    else
      return spread_finalize(stmt:columns(), db, stmt)
    end
  elseif res == DONE then
    reset(db, stmt)
    return
  else
    reset(db, stmt)
    return error(db:errmsg(), db:errcode())
  end
end

local function wrap (...)

  local db = check(nil, ...)

  local function begin (t)
    local res = db:exec(t
      and ("begin " .. t .. ";")
      or ("begin immediate;"))
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

  local function close ()
    db:close_vm()
    local res = db:close()
    if res ~= OK then
      error(db:errmsg(), db:errcode())
    end
  end

  local transaction_active = false

  return {

    db = db,
    close = close,
    begin = begin,
    commit = commit,
    rollback = rollback,

    transaction = function (fn, ...)
      local idx = 1
      local tag = nil
      if type(fn) == "string" then
        tag = fn
        fn = (...)
        idx = 2
      end
      if not transaction_active then
        begin(tag)
        transaction_active = true
        return vtup(function (ok, ...)
          transaction_active = false
          if not ok then
            rollback()
            error(...)
          else
            commit()
            return ...
          end
        end, pcall(fn, vsel(idx, ...)))
      else
        return fn(vsel(idx, ...))
      end
    end,

    exec = function (...)
      local res = db:exec(...)
      if res ~= OK then
        error(db:errmsg(), db:errcode())
      end
    end,

    iter = function (sql, prop)
      local stmt = check(db, db:prepare(sql))
      return function (...)
        return query(db, stmt, prop, ...)
      end, resetter(db, stmt)
    end,

    all = function (sql, prop)
      local stmt = check(db, db:prepare(sql))
      return function (...)
        return run(db, stmt, prop, {}, ...)
      end
    end,

    runner = function (sql)
      local stmt = check(db, db:prepare(sql))
      return function (...)
        return run(db, stmt, nil, nil, ...)
      end
    end,

    getter = function (sql, prop)
      local stmt = check(db, db:prepare(sql))
      return function (...)
        return get_one(db, stmt, prop, ...)
      end
    end,

    inserter = function (sql)
      local stmt = check(db, db:prepare(sql))
      return function (...)
        get_one(db, stmt, false, ...)
        return db:last_insert_rowid()
      end
    end,

  }
end

return wrap
