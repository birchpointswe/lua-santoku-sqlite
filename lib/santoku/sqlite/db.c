#include <lua.h>
#include <lauxlib.h>
#include <sqlite3.h>
#include <string.h>
#include <stdlib.h>

#ifdef __EMSCRIPTEN__
#include <emscripten.h>
#include <emscripten/html5.h>
#endif

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
    return luaL_error(L, "prepare: %s", sqlite3_errmsg(db->handle));
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

#define TK_CA_INT32  0
#define TK_CA_INT64  1
#define TK_CA_DOUBLE 2
#define TK_CA_FLOAT  3

typedef struct { void *ptr; int cnt; int type; } tk_ca_bind;

static void tk_ca_bind_free (void *p) { free(p); }

typedef struct { sqlite3_vtab base; } tk_ca_vtab;

typedef struct {
  sqlite3_vtab_cursor base;
  int row, cnt, type;
  void *ptr;
} tk_ca_cur;

static int tk_ca_connect (sqlite3 *db, void *pAux, int argc,
    const char *const *argv, sqlite3_vtab **ppVtab, char **pzErr) {
  (void)pAux; (void)argc; (void)argv; (void)pzErr;
  sqlite3_declare_vtab(db, "CREATE TABLE x(value, pointer HIDDEN, count HIDDEN, ctype TEXT HIDDEN)");
  tk_ca_vtab *v = sqlite3_malloc(sizeof(*v));
  memset(v, 0, sizeof(*v));
  *ppVtab = &v->base;
  return SQLITE_OK;
}

static int tk_ca_disconnect (sqlite3_vtab *pVtab) {
  sqlite3_free(pVtab);
  return SQLITE_OK;
}

static int tk_ca_best_index (sqlite3_vtab *pVtab, sqlite3_index_info *p) {
  (void)pVtab;
  int ptr_idx = -1, cnt_idx = -1, type_idx = -1;
  for (int i = 0; i < p->nConstraint; i++) {
    if (!p->aConstraint[i].usable) continue;
    if (p->aConstraint[i].op != SQLITE_INDEX_CONSTRAINT_EQ) continue;
    switch (p->aConstraint[i].iColumn) {
      case 1: ptr_idx = i; break;
      case 2: cnt_idx = i; break;
      case 3: type_idx = i; break;
    }
  }
  if (ptr_idx >= 0) {
    p->aConstraintUsage[ptr_idx].argvIndex = 1;
    p->aConstraintUsage[ptr_idx].omit = 1;
    int idx = 1;
    if (cnt_idx >= 0) {
      p->aConstraintUsage[cnt_idx].argvIndex = 2;
      p->aConstraintUsage[cnt_idx].omit = 1;
      idx |= 2;
    }
    if (type_idx >= 0) {
      p->aConstraintUsage[type_idx].argvIndex = cnt_idx >= 0 ? 3 : 2;
      p->aConstraintUsage[type_idx].omit = 1;
      idx |= 4;
    }
    p->idxNum = idx;
    p->estimatedCost = 1.0;
  } else {
    p->estimatedCost = 1e12;
  }
  return SQLITE_OK;
}

static int tk_ca_open (sqlite3_vtab *pVtab, sqlite3_vtab_cursor **ppCur) {
  (void)pVtab;
  tk_ca_cur *c = sqlite3_malloc(sizeof(*c));
  memset(c, 0, sizeof(*c));
  *ppCur = &c->base;
  return SQLITE_OK;
}

static int tk_ca_close (sqlite3_vtab_cursor *cur) {
  sqlite3_free(cur);
  return SQLITE_OK;
}

static int tk_ca_filter (sqlite3_vtab_cursor *cur, int idxNum,
    const char *idxStr, int argc, sqlite3_value **argv) {
  (void)idxStr;
  tk_ca_cur *c = (tk_ca_cur *)cur;
  c->row = 0;
  c->ptr = NULL;
  c->cnt = 0;
  c->type = TK_CA_INT32;
  if (idxNum & 1) {
    tk_ca_bind *b = (tk_ca_bind *)sqlite3_value_pointer(argv[0], "carray");
    if (b) {
      c->ptr = b->ptr;
      c->cnt = b->cnt;
      c->type = b->type;
    }
    int ai = 1;
    if ((idxNum & 2) && ai < argc) {
      c->cnt = sqlite3_value_int(argv[ai]);
      ai++;
    }
    if ((idxNum & 4) && ai < argc) {
      const char *t = (const char *)sqlite3_value_text(argv[ai]);
      if (t) {
        if (strcmp(t, "int64") == 0) c->type = TK_CA_INT64;
        else if (strcmp(t, "double") == 0) c->type = TK_CA_DOUBLE;
        else if (strcmp(t, "float") == 0) c->type = TK_CA_FLOAT;
        else c->type = TK_CA_INT32;
      }
    }
  }
  return SQLITE_OK;
}

static int tk_ca_next (sqlite3_vtab_cursor *cur) {
  ((tk_ca_cur *)cur)->row++;
  return SQLITE_OK;
}

static int tk_ca_eof (sqlite3_vtab_cursor *cur) {
  tk_ca_cur *c = (tk_ca_cur *)cur;
  return c->row >= c->cnt;
}

static int tk_ca_column (sqlite3_vtab_cursor *cur, sqlite3_context *ctx, int i) {
  tk_ca_cur *c = (tk_ca_cur *)cur;
  if (i == 0 && c->ptr) {
    switch (c->type) {
      case TK_CA_INT32:
        sqlite3_result_int(ctx, ((int32_t *)c->ptr)[c->row]); break;
      case TK_CA_INT64:
        sqlite3_result_int64(ctx, ((int64_t *)c->ptr)[c->row]); break;
      case TK_CA_DOUBLE:
        sqlite3_result_double(ctx, ((double *)c->ptr)[c->row]); break;
      case TK_CA_FLOAT:
        sqlite3_result_double(ctx, (double)((float *)c->ptr)[c->row]); break;
    }
  }
  return SQLITE_OK;
}

static int tk_ca_rowid (sqlite3_vtab_cursor *cur, sqlite3_int64 *pRowid) {
  *pRowid = ((tk_ca_cur *)cur)->row + 1;
  return SQLITE_OK;
}

static sqlite3_module tk_carray_module = {
  0, tk_ca_connect, tk_ca_connect, tk_ca_best_index,
  tk_ca_disconnect, tk_ca_disconnect,
  tk_ca_open, tk_ca_close, tk_ca_filter, tk_ca_next, tk_ca_eof,
  tk_ca_column, tk_ca_rowid,
  NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL
};

static int detect_vec (lua_State *L, int idx, void **ptr, int *cnt, int *type) {
  if (!lua_getmetatable(L, idx)) return 0;
  struct { const char *name; int type; } vecs[] = {
    {"tk_ivec_t", TK_CA_INT64}, {"tk_svec_t", TK_CA_INT32},
    {"tk_fvec_t", TK_CA_FLOAT}, {"tk_dvec_t", TK_CA_DOUBLE},
  };
  for (int i = 0; i < 4; i++) {
    luaL_getmetatable(L, vecs[i].name);
    if (lua_rawequal(L, -1, -2)) {
      lua_pop(L, 2);
      struct { size_t n, m; void *a; } *v = lua_touserdata(L, idx);
      *ptr = v->a;
      *cnt = (int)v->n;
      *type = vecs[i].type;
      return 1;
    }
    lua_pop(L, 1);
  }
  lua_pop(L, 1);
  return 0;
}

static int stmt_bind_carray (lua_State *L) {
  tk_sqlite_stmt *s = check_stmt(L, 1);
  int pidx = (int)luaL_checkinteger(L, 2);
  void *data; int cnt, type;
  if (!detect_vec(L, 3, &data, &cnt, &type))
    return luaL_error(L, "bind_carray: expected ivec, svec, fvec, or dvec");
  tk_ca_bind *b = malloc(sizeof(*b));
  b->ptr = data;
  b->cnt = cnt;
  b->type = type;
  sqlite3_bind_pointer(s->handle, pidx, b, "carray", tk_ca_bind_free);
  lua_pushinteger(L, SQLITE_OK);
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
  { "bind_carray", stmt_bind_carray },
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
  sqlite3_create_module(raw, "carray", &tk_carray_module, NULL);
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

#ifdef __EMSCRIPTEN__

#define SAH_PATH_MAX 512
#define SAH_VFS_NAME "opfs-sahpool"

EM_JS(void, tk_sah_setup, (), {
  if (Module._sahPool) return;
  Module._sahPool = {
    files: [],
    pathMap: {},
    capacity: 0,
    dirHandle: null,
    opaqueHandle: null,
  };
  globalThis.__tk_sah_pool_init = async function (dir, capacity) {
    var pool = Module._sahPool;
    var root = await navigator.storage.getDirectory();
    pool.dirHandle = await root.getDirectoryHandle(dir, { create: true });
    pool.opaqueHandle = await pool.dirHandle.getDirectoryHandle(".opaque", { create: true });
    var existing = [];
    for await (var entry of pool.opaqueHandle.values()) {
      if (entry.kind === "file") existing.push(entry.name);
    }
    existing.sort();
    for (var i = 0; i < existing.length; i++) {
      var fh = await pool.opaqueHandle.getFileHandle(existing[i]);
      var sah = await fh.createSyncAccessHandle();
      var hdr = new Uint8Array(4096);
      sah.read(hdr, { at: 0 });
      var path = "";
      for (var j = 0; j < 512; j++) {
        if (hdr[j] === 0) break;
        path += String.fromCharCode(hdr[j]);
      }
      var flags = hdr[512] | (hdr[513] << 8) |
                  (hdr[514] << 16) | (hdr[515] << 24);
      var slot = { sah: sah, path: path, flags: flags, fid: i };
      pool.files.push(slot);
      if (path.length > 0)
        pool.pathMap[path] = i;
    }
    for (var k = pool.files.length; k < capacity; k++) {
      var name = String(k).padStart(8, "0");
      var fh = await pool.opaqueHandle.getFileHandle(name, { create: true });
      var sah = await fh.createSyncAccessHandle();
      var slot = { sah: sah, path: "", flags: 0, fid: k };
      pool.files.push(slot);
    }
    pool.capacity = pool.files.length;
  };
});

EM_JS(int, tk_sah_xopen, (const char *cpath, int flags), {
  var pool = Module._sahPool;
  var path = UTF8ToString(cpath);
  if (path in pool.pathMap)
    return pool.pathMap[path];
  for (var i = 0; i < pool.files.length; i++) {
    if (pool.files[i].path.length === 0) {
      var slot = pool.files[i];
      slot.path = path;
      slot.flags = flags;
      pool.pathMap[path] = i;
      var hdr = new Uint8Array(4096);
      for (var j = 0; j < path.length && j < 512; j++)
        hdr[j] = path.charCodeAt(j);
      hdr[512] = flags & 0xff;
      hdr[513] = (flags >> 8) & 0xff;
      hdr[514] = (flags >> 16) & 0xff;
      hdr[515] = (flags >> 24) & 0xff;
      slot.sah.write(hdr, { at: 0 });
      slot.sah.flush();
      return i;
    }
  }
  return -1;
});

EM_JS(void, tk_sah_xclose, (int fid), {
});

EM_JS(int, tk_sah_xread, (int fid, unsigned char *buf, int n, double off), {
  var pool = Module._sahPool;
  var sah = pool.files[fid].sah;
  var tmp = new Uint8Array(n);
  var nread = sah.read(tmp, { at: 4096 + off });
  HEAPU8.set(tmp.subarray(0, nread), buf);
  if (nread < n) {
    HEAPU8.fill(0, buf + nread, buf + n);
    return 522;
  }
  return 0;
});

EM_JS(int, tk_sah_xwrite, (const unsigned char *buf, int n, double off, int fid), {
  var pool = Module._sahPool;
  var sah = pool.files[fid].sah;
  var data = HEAPU8.slice(buf, buf + n);
  sah.write(data, { at: 4096 + off });
  return 0;
});

EM_JS(double, tk_sah_xfilesize, (int fid), {
  var pool = Module._sahPool;
  var sah = pool.files[fid].sah;
  var sz = sah.getSize();
  return sz > 4096 ? sz - 4096 : 0;
});

EM_JS(int, tk_sah_xtruncate, (int fid, double sz), {
  var pool = Module._sahPool;
  var sah = pool.files[fid].sah;
  sah.truncate(4096 + sz);
  return 0;
});

EM_JS(void, tk_sah_xsync, (int fid), {
  var pool = Module._sahPool;
  pool.files[fid].sah.flush();
});

EM_JS(int, tk_sah_xaccess, (const char *cpath), {
  var pool = Module._sahPool;
  var path = UTF8ToString(cpath);
  return (path in pool.pathMap) ? 1 : 0;
});

EM_JS(void, tk_sah_xdelete, (const char *cpath), {
  var pool = Module._sahPool;
  var path = UTF8ToString(cpath);
  if (!(path in pool.pathMap)) return;
  var fid = pool.pathMap[path];
  var slot = pool.files[fid];
  var hdr = new Uint8Array(4096);
  slot.sah.write(hdr, { at: 0 });
  slot.sah.truncate(4096);
  slot.sah.flush();
  slot.path = "";
  slot.flags = 0;
  delete pool.pathMap[path];
});

typedef struct {
  sqlite3_file base;
  int fid;
} tk_sah_file;

static int sah_io_close (sqlite3_file *pFile) {
  tk_sah_file *f = (tk_sah_file *) pFile;
  tk_sah_xclose(f->fid);
  return SQLITE_OK;
}

static int sah_io_read (sqlite3_file *pFile, void *buf, int iAmt, sqlite3_int64 iOfst) {
  tk_sah_file *f = (tk_sah_file *) pFile;
  return tk_sah_xread(f->fid, (unsigned char *) buf, iAmt, (double) iOfst);
}

static int sah_io_write (sqlite3_file *pFile, const void *buf, int iAmt, sqlite3_int64 iOfst) {
  tk_sah_file *f = (tk_sah_file *) pFile;
  return tk_sah_xwrite((const unsigned char *) buf, iAmt, (double) iOfst, f->fid);
}

static int sah_io_truncate (sqlite3_file *pFile, sqlite3_int64 sz) {
  tk_sah_file *f = (tk_sah_file *) pFile;
  return tk_sah_xtruncate(f->fid, (double) sz);
}

static int sah_io_sync (sqlite3_file *pFile, int flags) {
  (void) flags;
  tk_sah_file *f = (tk_sah_file *) pFile;
  tk_sah_xsync(f->fid);
  return SQLITE_OK;
}

static int sah_io_filesize (sqlite3_file *pFile, sqlite3_int64 *pSize) {
  tk_sah_file *f = (tk_sah_file *) pFile;
  *pSize = (sqlite3_int64) tk_sah_xfilesize(f->fid);
  return SQLITE_OK;
}

static int sah_io_lock (sqlite3_file *p, int l) { (void) p; (void) l; return SQLITE_OK; }
static int sah_io_unlock (sqlite3_file *p, int l) { (void) p; (void) l; return SQLITE_OK; }
static int sah_io_check_reserved (sqlite3_file *p, int *r) { (void) p; *r = 0; return SQLITE_OK; }
static int sah_io_file_control (sqlite3_file *p, int o, void *a) { (void) p; (void) o; (void) a; return SQLITE_NOTFOUND; }
static int sah_io_sector_size (sqlite3_file *p) { (void) p; return 4096; }
static int sah_io_device_char (sqlite3_file *p) { (void) p; return SQLITE_IOCAP_UNDELETABLE_WHEN_OPEN; }

static const sqlite3_io_methods sah_io = {
  1,
  sah_io_close,
  sah_io_read,
  sah_io_write,
  sah_io_truncate,
  sah_io_sync,
  sah_io_filesize,
  sah_io_lock,
  sah_io_unlock,
  sah_io_check_reserved,
  sah_io_file_control,
  sah_io_sector_size,
  sah_io_device_char,
  NULL, NULL, NULL, NULL, NULL, NULL
};

static int sah_vfs_open (sqlite3_vfs *pVfs, const char *zName, sqlite3_file *pFile, int flags, int *pOutFlags) {
  (void) pVfs;
  tk_sah_file *f = (tk_sah_file *) pFile;
  memset(f, 0, sizeof(*f));
  f->base.pMethods = &sah_io;
  const char *path = zName ? zName : ":memory:";
  f->fid = tk_sah_xopen(path, flags);
  if (f->fid < 0) {
    f->base.pMethods = NULL;
    return SQLITE_CANTOPEN;
  }
  if (pOutFlags)
    *pOutFlags = flags;
  return SQLITE_OK;
}

static int sah_vfs_delete (sqlite3_vfs *pVfs, const char *zName, int syncDir) {
  (void) pVfs; (void) syncDir;
  tk_sah_xdelete(zName);
  return SQLITE_OK;
}

static int sah_vfs_access (sqlite3_vfs *pVfs, const char *zName, int flags, int *pResOut) {
  (void) pVfs; (void) flags;
  *pResOut = tk_sah_xaccess(zName);
  return SQLITE_OK;
}

static int sah_vfs_fullpathname (sqlite3_vfs *pVfs, const char *zName, int nOut, char *zOut) {
  (void) pVfs;
  strncpy(zOut, zName, (size_t) nOut);
  zOut[nOut - 1] = '\0';
  return SQLITE_OK;
}

static int sah_vfs_randomness (sqlite3_vfs *pVfs, int nBuf, char *zBuf) {
  (void) pVfs;
  for (int i = 0; i < nBuf; i++)
    zBuf[i] = (char) (emscripten_random() * 256);
  return nBuf;
}

static int sah_vfs_sleep (sqlite3_vfs *pVfs, int microseconds) {
  (void) pVfs;
  (void) microseconds;
  return 0;
}

static int sah_vfs_current_time (sqlite3_vfs *pVfs, double *pTime) {
  (void) pVfs;
  *pTime = emscripten_date_now() / 86400000.0 + 2440587.5;
  return SQLITE_OK;
}

static sqlite3_vfs sah_vfs = {
  1,
  sizeof(tk_sah_file),
  SAH_PATH_MAX,
  NULL,
  SAH_VFS_NAME,
  NULL,
  sah_vfs_open,
  sah_vfs_delete,
  sah_vfs_access,
  sah_vfs_fullpathname,
  NULL, NULL, NULL, NULL,
  sah_vfs_randomness,
  sah_vfs_sleep,
  sah_vfs_current_time,
  NULL,
  NULL,
  NULL,
  NULL,
  NULL
};

#endif

int luaopen_santoku_sqlite_db (lua_State *L) {
  create_mt(L, TK_SQLITE_DB_MT, db_methods, db_gc);
  create_mt(L, TK_SQLITE_STMT_MT, stmt_methods, stmt_gc);
#ifdef __EMSCRIPTEN__
  tk_sah_setup();
  sqlite3_vfs_register(&sah_vfs, 0);
#endif
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
