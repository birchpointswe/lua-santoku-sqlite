#include <lua.h>
#include <lauxlib.h>
#include <sqlite3.h>
#include <string.h>
#include <stdlib.h>

#define TK_SQLITE_DB_MT "santoku_sqlite_db"
#define TK_SQLITE_STMT_MT "santoku_sqlite_stmt"

typedef struct tk_sqlite_stmt tk_sqlite_stmt;

typedef struct {
  sqlite3 *handle;
  tk_sqlite_stmt *stmts;
} tk_sqlite_db;

struct tk_sqlite_stmt {
  sqlite3_stmt *handle;
  tk_sqlite_db *db;
  tk_sqlite_stmt *prev;
  tk_sqlite_stmt *next;
};

static void stmt_unlink (tk_sqlite_stmt *s) {
  if (s->prev)
    s->prev->next = s->next;
  else if (s->db)
    s->db->stmts = s->next;
  if (s->next)
    s->next->prev = s->prev;
  s->prev = s->next = NULL;
}

static void stmt_link (tk_sqlite_db *db, tk_sqlite_stmt *s) {
  s->db = db;
  s->prev = NULL;
  s->next = db->stmts;
  if (db->stmts)
    db->stmts->prev = s;
  db->stmts = s;
}

static tk_sqlite_db *check_db (lua_State *L, int idx) {
  return (tk_sqlite_db *) luaL_checkudata(L, idx, TK_SQLITE_DB_MT);
}

static tk_sqlite_stmt *check_stmt (lua_State *L, int idx) {
  return (tk_sqlite_stmt *) luaL_checkudata(L, idx, TK_SQLITE_STMT_MT);
}

static int db_exec (lua_State *L) {
  tk_sqlite_db *db = check_db(L, 1);
  const char *sql = luaL_checkstring(L, 2);
  int rc = sqlite3_exec(db->handle, sql, NULL, NULL, NULL);
  lua_pushinteger(L, rc);
  return 1;
}

static int db_prepare (lua_State *L) {
  tk_sqlite_db *db = check_db(L, 1);
  size_t len;
  const char *sql = luaL_checklstring(L, 2, &len);
  sqlite3_stmt *raw = NULL;
  int rc = sqlite3_prepare_v2(db->handle, sql, (int) len, &raw, NULL);
  if (rc != SQLITE_OK || !raw) {
    lua_pushnil(L);
    return 1;
  }
  tk_sqlite_stmt *s = (tk_sqlite_stmt *) lua_newuserdata(L, sizeof(tk_sqlite_stmt));
  memset(s, 0, sizeof(tk_sqlite_stmt));
  s->handle = raw;
  stmt_link(db, s);
  luaL_getmetatable(L, TK_SQLITE_STMT_MT);
  lua_setmetatable(L, -2);
  return 1;
}

static int db_errmsg (lua_State *L) {
  tk_sqlite_db *db = check_db(L, 1);
  lua_pushstring(L, sqlite3_errmsg(db->handle));
  return 1;
}

static int db_errcode (lua_State *L) {
  tk_sqlite_db *db = check_db(L, 1);
  lua_pushinteger(L, sqlite3_errcode(db->handle));
  return 1;
}

static int db_close (lua_State *L) {
  tk_sqlite_db *db = check_db(L, 1);
  int rc = SQLITE_OK;
  if (db->handle) {
    rc = sqlite3_close(db->handle);
    if (rc == SQLITE_OK)
      db->handle = NULL;
  }
  lua_pushinteger(L, rc);
  return 1;
}

static int db_close_vm (lua_State *L) {
  tk_sqlite_db *db = check_db(L, 1);
  while (db->stmts) {
    tk_sqlite_stmt *s = db->stmts;
    if (s->handle) {
      sqlite3_finalize(s->handle);
      s->handle = NULL;
    }
    stmt_unlink(s);
  }
  return 0;
}

static int db_last_insert_rowid (lua_State *L) {
  tk_sqlite_db *db = check_db(L, 1);
  lua_pushnumber(L, (lua_Number) sqlite3_last_insert_rowid(db->handle));
  return 1;
}

static int db_gc (lua_State *L) {
  tk_sqlite_db *db = check_db(L, 1);
  if (db->handle) {
    while (db->stmts) {
      tk_sqlite_stmt *s = db->stmts;
      if (s->handle) {
        sqlite3_finalize(s->handle);
        s->handle = NULL;
      }
      stmt_unlink(s);
    }
    sqlite3_close_v2(db->handle);
    db->handle = NULL;
  }
  return 0;
}

static int stmt_step (lua_State *L) {
  tk_sqlite_stmt *s = check_stmt(L, 1);
  lua_pushinteger(L, sqlite3_step(s->handle));
  return 1;
}

static int stmt_reset (lua_State *L) {
  tk_sqlite_stmt *s = check_stmt(L, 1);
  int rc = sqlite3_reset(s->handle);
  sqlite3_clear_bindings(s->handle);
  lua_pushinteger(L, rc);
  return 1;
}

static void bind_one (lua_State *L, sqlite3_stmt *h, int pidx, int vidx) {
  switch (lua_type(L, vidx)) {
    case LUA_TNIL:
      sqlite3_bind_null(h, pidx);
      break;
    case LUA_TBOOLEAN:
      sqlite3_bind_int(h, pidx, lua_toboolean(L, vidx));
      break;
    case LUA_TNUMBER:
      sqlite3_bind_double(h, pidx, lua_tonumber(L, vidx));
      break;
    case LUA_TSTRING: {
      size_t len;
      const char *str = lua_tolstring(L, vidx, &len);
      sqlite3_bind_text(h, pidx, str, (int) len, SQLITE_TRANSIENT);
      break;
    }
    default:
      sqlite3_bind_null(h, pidx);
      break;
  }
}

static int stmt_bind_values (lua_State *L) {
  tk_sqlite_stmt *s = check_stmt(L, 1);
  int n = lua_gettop(L) - 1;
  for (int i = 1; i <= n; i++)
    bind_one(L, s->handle, i, i + 1);
  lua_pushinteger(L, SQLITE_OK);
  return 1;
}

static int stmt_bind_names (lua_State *L) {
  tk_sqlite_stmt *s = check_stmt(L, 1);
  luaL_checktype(L, 2, LUA_TTABLE);
  lua_pushnil(L);
  while (lua_next(L, 2)) {
    if (lua_type(L, -2) == LUA_TSTRING) {
      const char *key = lua_tostring(L, -2);
      char buf[256];
      buf[0] = ':';
      strncpy(buf + 1, key, sizeof(buf) - 2);
      buf[sizeof(buf) - 1] = '\0';
      int pidx = sqlite3_bind_parameter_index(s->handle, buf);
      if (pidx > 0)
        bind_one(L, s->handle, pidx, lua_gettop(L));
    }
    lua_pop(L, 1);
  }
  lua_pushinteger(L, SQLITE_OK);
  return 1;
}

static void push_column (lua_State *L, sqlite3_stmt *h, int col) {
  switch (sqlite3_column_type(h, col)) {
    case SQLITE_INTEGER:
      lua_pushnumber(L, (lua_Number) sqlite3_column_int64(h, col));
      break;
    case SQLITE_FLOAT:
      lua_pushnumber(L, sqlite3_column_double(h, col));
      break;
    case SQLITE_TEXT:
      lua_pushlstring(L, (const char *) sqlite3_column_text(h, col), (size_t) sqlite3_column_bytes(h, col));
      break;
    case SQLITE_BLOB:
      lua_pushlstring(L, (const char *) sqlite3_column_blob(h, col), (size_t) sqlite3_column_bytes(h, col));
      break;
    default:
      lua_pushnil(L);
      break;
  }
}

static int stmt_get_value (lua_State *L) {
  tk_sqlite_stmt *s = check_stmt(L, 1);
  int col = (int) luaL_checkinteger(L, 2);
  push_column(L, s->handle, col);
  return 1;
}

static int stmt_get_named_values (lua_State *L) {
  tk_sqlite_stmt *s = check_stmt(L, 1);
  int ncols = sqlite3_column_count(s->handle);
  lua_createtable(L, 0, ncols);
  for (int i = 0; i < ncols; i++) {
    const char *name = sqlite3_column_name(s->handle, i);
    push_column(L, s->handle, i);
    lua_setfield(L, -2, name);
  }
  return 1;
}

static int stmt_columns (lua_State *L) {
  tk_sqlite_stmt *s = check_stmt(L, 1);
  lua_pushinteger(L, sqlite3_column_count(s->handle));
  return 1;
}

static int stmt_gc (lua_State *L) {
  tk_sqlite_stmt *s = check_stmt(L, 1);
  if (s->handle) {
    sqlite3_finalize(s->handle);
    s->handle = NULL;
  }
  stmt_unlink(s);
  return 0;
}

static luaL_Reg db_methods[] = {
  { "exec", db_exec },
  { "prepare", db_prepare },
  { "errmsg", db_errmsg },
  { "errcode", db_errcode },
  { "close", db_close },
  { "close_vm", db_close_vm },
  { "last_insert_rowid", db_last_insert_rowid },
  { NULL, NULL }
};

static luaL_Reg stmt_methods[] = {
  { "step", stmt_step },
  { "reset", stmt_reset },
  { "bind_values", stmt_bind_values },
  { "bind_names", stmt_bind_names },
  { "get_value", stmt_get_value },
  { "get_named_values", stmt_get_named_values },
  { "columns", stmt_columns },
  { NULL, NULL }
};

static void create_mt (lua_State *L, const char *name, luaL_Reg *methods, lua_CFunction gc) {
  luaL_newmetatable(L, name);
  lua_pushstring(L, name);
  lua_setfield(L, -2, "__name");
  lua_pushcfunction(L, gc);
  lua_setfield(L, -2, "__gc");
  lua_newtable(L);
  for (; methods->name; methods++) {
    lua_pushcfunction(L, methods->func);
    lua_setfield(L, -2, methods->name);
  }
  lua_setfield(L, -2, "__index");
  lua_pop(L, 1);
}

static int push_db (lua_State *L, sqlite3 *raw) {
  tk_sqlite_db *db = (tk_sqlite_db *) lua_newuserdata(L, sizeof(tk_sqlite_db));
  db->handle = raw;
  db->stmts = NULL;
  luaL_getmetatable(L, TK_SQLITE_DB_MT);
  lua_setmetatable(L, -2);
  return 1;
}

static int tk_open (lua_State *L) {
  const char *path = luaL_checkstring(L, 1);
  sqlite3_initialize();
  sqlite3 *raw = NULL;
  int rc = sqlite3_open(path, &raw);
  if (rc != SQLITE_OK) {
    if (raw) sqlite3_close(raw);
    lua_pushnil(L);
    return 1;
  }
  return push_db(L, raw);
}

static int tk_open_memory (lua_State *L) {
  sqlite3_initialize();
  sqlite3 *raw = NULL;
  int rc = sqlite3_open(":memory:", &raw);
  if (rc != SQLITE_OK) {
    if (raw) sqlite3_close(raw);
    lua_pushnil(L);
    return 1;
  }
  return push_db(L, raw);
}

static int tk_open_v2 (lua_State *L) {
  const char *path = luaL_checkstring(L, 1);
  const char *vfs = luaL_optstring(L, 2, NULL);
  sqlite3_initialize();
  sqlite3 *raw = NULL;
  int rc = sqlite3_open_v2(path, &raw,
    SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, vfs);
  if (rc != SQLITE_OK) {
    if (raw) sqlite3_close(raw);
    lua_pushnil(L);
    return 1;
  }
  return push_db(L, raw);
}

int luaopen_santoku_sqlite_db (lua_State *L) {
  create_mt(L, TK_SQLITE_DB_MT, db_methods, db_gc);
  create_mt(L, TK_SQLITE_STMT_MT, stmt_methods, stmt_gc);
  lua_newtable(L);
  lua_pushcfunction(L, tk_open);
  lua_setfield(L, -2, "open");
  lua_pushcfunction(L, tk_open_memory);
  lua_setfield(L, -2, "open_memory");
  lua_pushcfunction(L, tk_open_v2);
  lua_setfield(L, -2, "open_v2");
  lua_pushinteger(L, SQLITE_OK);
  lua_setfield(L, -2, "OK");
  lua_pushinteger(L, SQLITE_ERROR);
  lua_setfield(L, -2, "ERROR");
  lua_pushinteger(L, SQLITE_ROW);
  lua_setfield(L, -2, "ROW");
  lua_pushinteger(L, SQLITE_DONE);
  lua_setfield(L, -2, "DONE");
  return 1;
}
