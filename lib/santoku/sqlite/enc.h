#ifndef TK_SQLITE_ENC_H
#define TK_SQLITE_ENC_H








































#include <sqlite3.h>

#include <stdint.h>
#include <stddef.h>
#include <string.h>
#include <stdlib.h>

#include <santoku/monocypher.h>

#ifdef __EMSCRIPTEN__
#include <emscripten.h>
#endif

#define TK_ENC_MAGIC        "TKSQENC1"
#define TK_ENC_MAGIC_LEN    8
#define TK_ENC_VERSION      1
#define TK_ENC_HDR          64
#define TK_ENC_NONCE        24
#define TK_ENC_TAG          16
#define TK_ENC_OVH          (TK_ENC_NONCE + TK_ENC_TAG)
#define TK_ENC_SALT         16
#define TK_ENC_AAD          (TK_ENC_SALT + 8)
#define TK_ENC_KEYLEN       32
#define TK_ENC_BLOCK        4096
#define TK_ENC_MAX_VFS      8
#define TK_ENC_NAME_MAX     80





#ifdef __EMSCRIPTEN__
EM_JS(void, tk_enc_js_random, (unsigned char *buf, int n), {
  var a = new Uint8Array(n);
  (globalThis.crypto || globalThis.msCrypto).getRandomValues(a);
  HEAPU8.set(a, buf);
});
#endif

static void tk_enc_random (void *buf, size_t n)
{
#ifdef __EMSCRIPTEN__
  tk_enc_js_random((unsigned char *) buf, (int) n);
#else
  arc4random_buf(buf, n);
#endif
}



static void tk_enc_put32 (unsigned char *p, uint32_t v)
{
  p[0] = (unsigned char) (v & 0xff);
  p[1] = (unsigned char) ((v >> 8) & 0xff);
  p[2] = (unsigned char) ((v >> 16) & 0xff);
  p[3] = (unsigned char) ((v >> 24) & 0xff);
}

static uint32_t tk_enc_get32 (const unsigned char *p)
{
  return (uint32_t) p[0] | ((uint32_t) p[1] << 8) |
         ((uint32_t) p[2] << 16) | ((uint32_t) p[3] << 24);
}

static void tk_enc_put64 (unsigned char *p, uint64_t v)
{
  for (int i = 0; i < 8; i ++)
    p[i] = (unsigned char) ((v >> (8 * i)) & 0xff);
}

static uint64_t tk_enc_get64 (const unsigned char *p)
{
  uint64_t v = 0;
  for (int i = 0; i < 8; i ++)
    v |= ((uint64_t) p[i]) << (8 * i);
  return v;
}









typedef struct tk_enc_key_s {
  struct tk_enc_key_s *next;
  char *path;
  unsigned char key[TK_ENC_KEYLEN];
  int refs;
} tk_enc_key_t;





static tk_enc_key_t *tk_enc_keys = NULL;

static int tk_enc_key_register (const char *path, const unsigned char *key)
{
  for (tk_enc_key_t *e = tk_enc_keys; e; e = e->next) {
    if (!strcmp(e->path, path)) {




      if (memcmp(e->key, key, TK_ENC_KEYLEN))
        return SQLITE_MISUSE;
      e->refs ++;
      return SQLITE_OK;
    }
  }
  tk_enc_key_t *e = (tk_enc_key_t *) sqlite3_malloc((int) sizeof(*e));
  if (!e)
    return SQLITE_NOMEM;
  size_t n = strlen(path) + 1;
  e->path = (char *) sqlite3_malloc((int) n);
  if (!e->path) {
    sqlite3_free(e);
    return SQLITE_NOMEM;
  }
  memcpy(e->path, path, n);
  memcpy(e->key, key, TK_ENC_KEYLEN);
  e->refs = 1;
  e->next = tk_enc_keys;
  tk_enc_keys = e;
  return SQLITE_OK;
}

static void tk_enc_key_unregister (const char *path)
{
  tk_enc_key_t **pp = &tk_enc_keys;
  while (*pp) {
    tk_enc_key_t *e = *pp;
    if (!strcmp(e->path, path)) {
      if (-- e->refs <= 0) {
        *pp = e->next;
        crypto_wipe(e->key, TK_ENC_KEYLEN);
        sqlite3_free(e->path);
        sqlite3_free(e);
      }
      break;
    }
    pp = &e->next;
  }
}

static int tk_enc_key_find (const char *path, unsigned char *out)
{
  for (tk_enc_key_t *e = tk_enc_keys; e; e = e->next) {
    if (!strcmp(e->path, path)) {
      memcpy(out, e->key, TK_ENC_KEYLEN);
      return 1;
    }
  }
  return 0;
}



typedef struct {
  sqlite3_file base;
  sqlite3_file *p;
  unsigned char key[TK_ENC_KEYLEN];
  unsigned char salt[TK_ENC_SALT];
  uint32_t block;
  sqlite3_int64 lsize;
  int hashdr;
} tk_enc_file;

static sqlite3_int64 tk_enc_frame_off (tk_enc_file *f, uint64_t idx)
{
  return (sqlite3_int64) TK_ENC_HDR +
         (sqlite3_int64) idx * (sqlite3_int64) (f->block + TK_ENC_OVH);
}

static void tk_enc_aad (tk_enc_file *f, uint64_t idx, unsigned char *out)
{
  memcpy(out, f->salt, TK_ENC_SALT);
  tk_enc_put64(out + TK_ENC_SALT, idx);
}

static int tk_enc_hdr_flush (tk_enc_file *f)
{
  unsigned char h[TK_ENC_HDR];
  memset(h, 0, sizeof(h));
  memcpy(h, TK_ENC_MAGIC, TK_ENC_MAGIC_LEN);
  tk_enc_put32(h + 8, TK_ENC_VERSION);
  tk_enc_put32(h + 12, f->block);
  tk_enc_put64(h + 16, (uint64_t) f->lsize);
  memcpy(h + 24, f->salt, TK_ENC_SALT);
  int rc = f->p->pMethods->xWrite(f->p, h, TK_ENC_HDR, 0);
  if (rc == SQLITE_OK)
    f->hashdr = 1;
  return rc;
}




static int tk_enc_block_read (tk_enc_file *f, uint64_t idx, unsigned char *out)
{
  sqlite3_int64 psz = 0;
  int rc = f->p->pMethods->xFileSize(f->p, &psz);
  if (rc != SQLITE_OK)
    return rc;
  sqlite3_int64 off = tk_enc_frame_off(f, idx);
  sqlite3_int64 need = (sqlite3_int64) (f->block + TK_ENC_OVH);
  if (off + need > psz) {
    memset(out, 0, f->block);
    return SQLITE_OK;
  }
  unsigned char *frame = (unsigned char *) sqlite3_malloc((int) need);
  if (!frame)
    return SQLITE_NOMEM;
  rc = f->p->pMethods->xRead(f->p, frame, (int) need, off);
  if (rc != SQLITE_OK) {
    sqlite3_free(frame);
    return rc;
  }
  unsigned char ad[TK_ENC_AAD];
  tk_enc_aad(f, idx, ad);
  int bad = crypto_aead_unlock(out,
    frame + TK_ENC_NONCE + f->block, f->key, frame,
    ad, TK_ENC_AAD, frame + TK_ENC_NONCE, f->block);
  sqlite3_free(frame);


  if (bad)
    return SQLITE_IOERR_READ;
  return SQLITE_OK;
}

static int tk_enc_block_write (tk_enc_file *f, uint64_t idx, const unsigned char *in)
{
  sqlite3_int64 need = (sqlite3_int64) (f->block + TK_ENC_OVH);
  unsigned char *frame = (unsigned char *) sqlite3_malloc((int) need);
  if (!frame)
    return SQLITE_NOMEM;
  tk_enc_random(frame, TK_ENC_NONCE);
  unsigned char ad[TK_ENC_AAD];
  tk_enc_aad(f, idx, ad);
  crypto_aead_lock(frame + TK_ENC_NONCE, frame + TK_ENC_NONCE + f->block,
    f->key, frame, ad, TK_ENC_AAD, in, f->block);
  int rc = f->p->pMethods->xWrite(f->p, frame, (int) need, tk_enc_frame_off(f, idx));
  sqlite3_free(frame);
  return rc;
}

static int tk_enc_io_close (sqlite3_file *pf)
{
  tk_enc_file *f = (tk_enc_file *) pf;
  int rc = SQLITE_OK;
  if (f->p->pMethods)
    rc = f->p->pMethods->xClose(f->p);
  crypto_wipe(f->key, TK_ENC_KEYLEN);
  return rc;
}

static int tk_enc_io_read (sqlite3_file *pf, void *buf, int amt, sqlite3_int64 off)
{
  tk_enc_file *f = (tk_enc_file *) pf;
  unsigned char *dst = (unsigned char *) buf;
  if (!f->hashdr || off >= f->lsize) {
    memset(dst, 0, (size_t) amt);
    return SQLITE_IOERR_SHORT_READ;
  }
  int want = amt;
  int shortread = 0;
  if (f->lsize - off < (sqlite3_int64) amt) {
    want = (int) (f->lsize - off);
    shortread = 1;
  }
  unsigned char *blk = (unsigned char *) sqlite3_malloc((int) f->block);
  if (!blk)
    return SQLITE_NOMEM;
  int rc = SQLITE_OK;
  sqlite3_int64 pos = off;
  int left = want;
  while (left > 0) {
    uint64_t idx = (uint64_t) (pos / f->block);
    uint32_t o = (uint32_t) (pos % f->block);
    uint32_t n = f->block - o;
    if ((int) n > left)
      n = (uint32_t) left;
    rc = tk_enc_block_read(f, idx, blk);
    if (rc != SQLITE_OK)
      break;
    memcpy(dst, blk + o, n);
    dst += n;
    pos += n;
    left -= (int) n;
  }
  crypto_wipe(blk, f->block);
  sqlite3_free(blk);
  if (rc != SQLITE_OK)
    return rc;
  if (shortread) {
    memset((unsigned char *) buf + want, 0, (size_t) (amt - want));
    return SQLITE_IOERR_SHORT_READ;
  }
  return SQLITE_OK;
}

static int tk_enc_io_write (sqlite3_file *pf, const void *buf, int amt, sqlite3_int64 off)
{
  tk_enc_file *f = (tk_enc_file *) pf;
  int rc = SQLITE_OK;
  if (!f->hashdr) {
    rc = tk_enc_hdr_flush(f);
    if (rc != SQLITE_OK)
      return rc;
  }
  unsigned char *blk = (unsigned char *) sqlite3_malloc((int) f->block);
  if (!blk)
    return SQLITE_NOMEM;




  if (off > f->lsize) {
    sqlite3_int64 psz = 0;
    rc = f->p->pMethods->xFileSize(f->p, &psz);
    if (rc != SQLITE_OK) {
      sqlite3_free(blk);
      return rc;
    }
    uint64_t have = psz > TK_ENC_HDR
      ? (uint64_t) ((psz - TK_ENC_HDR) / (sqlite3_int64) (f->block + TK_ENC_OVH))
      : 0;
    uint64_t first = (uint64_t) (off / f->block);
    for (uint64_t i = have; i < first; i ++) {
      memset(blk, 0, f->block);
      rc = tk_enc_block_write(f, i, blk);
      if (rc != SQLITE_OK) {
        crypto_wipe(blk, f->block);
        sqlite3_free(blk);
        return rc;
      }
    }
  }
  const unsigned char *src = (const unsigned char *) buf;
  sqlite3_int64 pos = off;
  int left = amt;
  while (left > 0) {
    uint64_t idx = (uint64_t) (pos / f->block);
    uint32_t o = (uint32_t) (pos % f->block);
    uint32_t n = f->block - o;
    if ((int) n > left)
      n = (uint32_t) left;
    if (n == f->block) {
      memcpy(blk, src, f->block);
    } else {
      rc = tk_enc_block_read(f, idx, blk);
      if (rc != SQLITE_OK)
        break;
      memcpy(blk + o, src, n);
    }
    rc = tk_enc_block_write(f, idx, blk);
    if (rc != SQLITE_OK)
      break;
    src += n;
    pos += n;
    left -= (int) n;
  }
  crypto_wipe(blk, f->block);
  sqlite3_free(blk);
  if (rc != SQLITE_OK)
    return rc;
  if (off + amt > f->lsize) {
    f->lsize = off + amt;
    rc = tk_enc_hdr_flush(f);
  }
  return rc;
}

static int tk_enc_io_truncate (sqlite3_file *pf, sqlite3_int64 size)
{
  tk_enc_file *f = (tk_enc_file *) pf;
  if (!f->hashdr && size == 0)
    return SQLITE_OK;
  int rc = SQLITE_OK;
  if (!f->hashdr) {
    rc = tk_enc_hdr_flush(f);
    if (rc != SQLITE_OK)
      return rc;
  }
  sqlite3_int64 nblocks = (size + (sqlite3_int64) f->block - 1) / (sqlite3_int64) f->block;
  rc = f->p->pMethods->xTruncate(f->p,
    (sqlite3_int64) TK_ENC_HDR + nblocks * (sqlite3_int64) (f->block + TK_ENC_OVH));
  if (rc != SQLITE_OK)
    return rc;
  f->lsize = size;
  return tk_enc_hdr_flush(f);
}

static int tk_enc_io_sync (sqlite3_file *pf, int flags)
{
  tk_enc_file *f = (tk_enc_file *) pf;
  return f->p->pMethods->xSync(f->p, flags);
}

static int tk_enc_io_filesize (sqlite3_file *pf, sqlite3_int64 *pSize)
{
  tk_enc_file *f = (tk_enc_file *) pf;
  *pSize = f->hashdr ? f->lsize : 0;
  return SQLITE_OK;
}






static int tk_enc_hdr_refresh (tk_enc_file *f)
{
  if (!f->hashdr)
    return SQLITE_OK;
  sqlite3_int64 psz = 0;
  int rc = f->p->pMethods->xFileSize(f->p, &psz);
  if (rc != SQLITE_OK)
    return rc;
  if (psz < TK_ENC_HDR)
    return SQLITE_OK;
  unsigned char h[TK_ENC_HDR];
  rc = f->p->pMethods->xRead(f->p, h, TK_ENC_HDR, 0);
  if (rc != SQLITE_OK)
    return rc;
  if (memcmp(h, TK_ENC_MAGIC, TK_ENC_MAGIC_LEN) ||
      tk_enc_get32(h + 8) != TK_ENC_VERSION)
    return SQLITE_NOTADB;
  uint32_t blk = tk_enc_get32(h + 12);
  if (blk < 512 || blk > (1 << 20))
    return SQLITE_NOTADB;
  f->block = blk;
  f->lsize = (sqlite3_int64) tk_enc_get64(h + 16);
  memcpy(f->salt, h + 24, TK_ENC_SALT);
  return SQLITE_OK;
}

static int tk_enc_io_lock (sqlite3_file *pf, int l)
{
  tk_enc_file *f = (tk_enc_file *) pf;
  int rc = f->p->pMethods->xLock(f->p, l);
  if (rc != SQLITE_OK)
    return rc;


  if (l > SQLITE_LOCK_NONE)
    return tk_enc_hdr_refresh(f);
  return SQLITE_OK;
}

static int tk_enc_io_unlock (sqlite3_file *pf, int l)
{
  tk_enc_file *f = (tk_enc_file *) pf;
  return f->p->pMethods->xUnlock(f->p, l);
}

static int tk_enc_io_check_reserved (sqlite3_file *pf, int *r)
{
  tk_enc_file *f = (tk_enc_file *) pf;
  return f->p->pMethods->xCheckReservedLock(f->p, r);
}

static int tk_enc_io_file_control (sqlite3_file *pf, int op, void *arg)
{
  tk_enc_file *f = (tk_enc_file *) pf;
  if (op == SQLITE_FCNTL_SIZE_HINT) {

    sqlite3_int64 sz = *(sqlite3_int64 *) arg;
    sqlite3_int64 nb = (sz + (sqlite3_int64) f->block - 1) / (sqlite3_int64) f->block;
    sqlite3_int64 phys = (sqlite3_int64) TK_ENC_HDR +
      nb * (sqlite3_int64) (f->block + TK_ENC_OVH);
    return f->p->pMethods->xFileControl(f->p, op, &phys);
  }
  if (op == SQLITE_FCNTL_VFSNAME) {
    *(char **) arg = sqlite3_mprintf("tkenc");
    return SQLITE_OK;
  }
  return f->p->pMethods->xFileControl(f->p, op, arg);
}

static int tk_enc_io_sector_size (sqlite3_file *pf)
{
  tk_enc_file *f = (tk_enc_file *) pf;
  return f->p->pMethods->xSectorSize(f->p);
}

static int tk_enc_io_device_char (sqlite3_file *pf)
{
  tk_enc_file *f = (tk_enc_file *) pf;
  int d = f->p->pMethods->xDeviceCharacteristics(f->p);


  d &= ~(SQLITE_IOCAP_ATOMIC | SQLITE_IOCAP_ATOMIC512 | SQLITE_IOCAP_ATOMIC1K |
         SQLITE_IOCAP_ATOMIC2K | SQLITE_IOCAP_ATOMIC4K | SQLITE_IOCAP_ATOMIC8K |
         SQLITE_IOCAP_ATOMIC16K | SQLITE_IOCAP_ATOMIC32K | SQLITE_IOCAP_ATOMIC64K);
  return d;
}

static const sqlite3_io_methods tk_enc_io = {
  1,
  tk_enc_io_close,
  tk_enc_io_read,
  tk_enc_io_write,
  tk_enc_io_truncate,
  tk_enc_io_sync,
  tk_enc_io_filesize,
  tk_enc_io_lock,
  tk_enc_io_unlock,
  tk_enc_io_check_reserved,
  tk_enc_io_file_control,
  tk_enc_io_sector_size,
  tk_enc_io_device_char,
  NULL, NULL, NULL, NULL, NULL, NULL
};



typedef struct {
  sqlite3_vfs base;
  sqlite3_vfs *parent;
  char name[TK_ENC_NAME_MAX];
} tk_enc_vfs_t;

static tk_enc_vfs_t *tk_enc_vfs_tab[TK_ENC_MAX_VFS];
static int tk_enc_vfs_n = 0;

static int tk_enc_vfs_open (sqlite3_vfs *pVfs, const char *zName,
                            sqlite3_file *pFile, int flags, int *pOutFlags)
{
  sqlite3_vfs *par = ((tk_enc_vfs_t *) pVfs)->parent;
  tk_enc_file *f = (tk_enc_file *) pFile;
  memset(f, 0, sizeof(*f));
  f->base.pMethods = NULL;
  f->p = (sqlite3_file *) ((char *) f + sizeof(tk_enc_file));



  const char *dbf = zName;
  int derived = SQLITE_OPEN_MAIN_JOURNAL;
#ifdef SQLITE_OPEN_SUPER_JOURNAL
  derived |= SQLITE_OPEN_SUPER_JOURNAL;
#endif
#ifdef SQLITE_OPEN_WAL
  derived |= SQLITE_OPEN_WAL;
#endif
  if (zName && (flags & derived)) {
    const char *d = sqlite3_filename_database(zName);
    if (d && *d)
      dbf = d;
  }

  int havekey = dbf ? tk_enc_key_find(dbf, f->key) : 0;
  if (!havekey) {
    if (flags & SQLITE_OPEN_MAIN_DB)

      return SQLITE_CANTOPEN;


    tk_enc_random(f->key, TK_ENC_KEYLEN);
  }

  int rc = par->xOpen(par, zName, f->p, flags, pOutFlags);
  if (rc != SQLITE_OK) {
    crypto_wipe(f->key, TK_ENC_KEYLEN);
    return rc;
  }

  f->block = TK_ENC_BLOCK;
  sqlite3_int64 psz = 0;
  rc = f->p->pMethods->xFileSize(f->p, &psz);
  if (rc != SQLITE_OK) {
    f->p->pMethods->xClose(f->p);
    crypto_wipe(f->key, TK_ENC_KEYLEN);
    return rc;
  }

  if (psz == 0) {
    tk_enc_random(f->salt, TK_ENC_SALT);
    f->lsize = 0;
    f->hashdr = 0;
  } else {
    unsigned char h[TK_ENC_HDR];
    if (psz < TK_ENC_HDR ||
        f->p->pMethods->xRead(f->p, h, TK_ENC_HDR, 0) != SQLITE_OK ||
        memcmp(h, TK_ENC_MAGIC, TK_ENC_MAGIC_LEN) ||
        tk_enc_get32(h + 8) != TK_ENC_VERSION) {
      f->p->pMethods->xClose(f->p);
      crypto_wipe(f->key, TK_ENC_KEYLEN);
      return SQLITE_NOTADB;
    }
    f->block = tk_enc_get32(h + 12);
    if (f->block < 512 || f->block > (1 << 20)) {
      f->p->pMethods->xClose(f->p);
      crypto_wipe(f->key, TK_ENC_KEYLEN);
      return SQLITE_NOTADB;
    }
    f->lsize = (sqlite3_int64) tk_enc_get64(h + 16);
    memcpy(f->salt, h + 24, TK_ENC_SALT);
    f->hashdr = 1;
  }

  f->base.pMethods = &tk_enc_io;
  return SQLITE_OK;
}

static int tk_enc_vfs_delete (sqlite3_vfs *pVfs, const char *zName, int syncDir)
{
  sqlite3_vfs *par = ((tk_enc_vfs_t *) pVfs)->parent;
  return par->xDelete(par, zName, syncDir);
}

static int tk_enc_vfs_access (sqlite3_vfs *pVfs, const char *zName, int flags, int *pResOut)
{
  sqlite3_vfs *par = ((tk_enc_vfs_t *) pVfs)->parent;
  return par->xAccess(par, zName, flags, pResOut);
}

static int tk_enc_vfs_fullpathname (sqlite3_vfs *pVfs, const char *zName, int nOut, char *zOut)
{
  sqlite3_vfs *par = ((tk_enc_vfs_t *) pVfs)->parent;
  return par->xFullPathname(par, zName, nOut, zOut);
}

static int tk_enc_vfs_randomness (sqlite3_vfs *pVfs, int nByte, char *zOut)
{
  sqlite3_vfs *par = ((tk_enc_vfs_t *) pVfs)->parent;
  return par->xRandomness(par, nByte, zOut);
}

static int tk_enc_vfs_sleep (sqlite3_vfs *pVfs, int micro)
{
  sqlite3_vfs *par = ((tk_enc_vfs_t *) pVfs)->parent;
  return par->xSleep(par, micro);
}

static int tk_enc_vfs_currenttime (sqlite3_vfs *pVfs, double *pTime)
{
  sqlite3_vfs *par = ((tk_enc_vfs_t *) pVfs)->parent;
  return par->xCurrentTime(par, pTime);
}

static int tk_enc_vfs_getlasterror (sqlite3_vfs *pVfs, int n, char *z)
{
  sqlite3_vfs *par = ((tk_enc_vfs_t *) pVfs)->parent;
  if (par->xGetLastError)
    return par->xGetLastError(par, n, z);
  return SQLITE_OK;
}



static const char *tk_enc_vfs_ensure (const char *parent_name)
{
  sqlite3_vfs *par = sqlite3_vfs_find(parent_name);
  if (!par)
    return NULL;
  for (int i = 0; i < tk_enc_vfs_n; i ++)
    if (tk_enc_vfs_tab[i]->parent == par)
      return tk_enc_vfs_tab[i]->name;
  if (tk_enc_vfs_n >= TK_ENC_MAX_VFS)
    return NULL;
  tk_enc_vfs_t *v = (tk_enc_vfs_t *) sqlite3_malloc((int) sizeof(*v));
  if (!v)
    return NULL;
  memset(v, 0, sizeof(*v));
  v->parent = par;
  snprintf(v->name, sizeof(v->name), "tkenc-%s", par->zName ? par->zName : "default");
  v->base.iVersion = 1;
  v->base.szOsFile = (int) sizeof(tk_enc_file) + par->szOsFile;
  v->base.mxPathname = par->mxPathname;
  v->base.zName = v->name;
  v->base.pAppData = NULL;
  v->base.xOpen = tk_enc_vfs_open;
  v->base.xDelete = tk_enc_vfs_delete;
  v->base.xAccess = tk_enc_vfs_access;
  v->base.xFullPathname = tk_enc_vfs_fullpathname;
  v->base.xDlOpen = NULL;
  v->base.xDlError = NULL;
  v->base.xDlSym = NULL;
  v->base.xDlClose = NULL;
  v->base.xRandomness = tk_enc_vfs_randomness;
  v->base.xSleep = tk_enc_vfs_sleep;
  v->base.xCurrentTime = tk_enc_vfs_currenttime;
  v->base.xGetLastError = tk_enc_vfs_getlasterror;
  if (sqlite3_vfs_register(&v->base, 0) != SQLITE_OK) {
    sqlite3_free(v);
    return NULL;
  }
  tk_enc_vfs_tab[tk_enc_vfs_n ++] = v;
  return v->name;
}

#endif
