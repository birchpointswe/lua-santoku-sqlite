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
#define TK_ENC_VERSION      2
#define TK_ENC_HDR          128
#define TK_ENC_NONCE        24
#define TK_ENC_TAG          16
#define TK_ENC_OVH          (TK_ENC_NONCE + TK_ENC_TAG)
#define TK_ENC_SALT         16
#define TK_ENC_AAD          (TK_ENC_SALT + 8)
#define TK_ENC_AAD_CTR      (TK_ENC_SALT + 16)
#define TK_ENC_ROOT         16
#define TK_ENC_KEYLEN       32
#define TK_ENC_BLOCK        4096
#define TK_ENC_MAX_VFS      8
#define TK_ENC_NAME_MAX     80
#define TK_ENC_CTR_MARK     UINT64_MAX
#define TK_ENC_DIRTY_BIT    (UINT64_C(1) << 63)

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
  int softfail;
  int counters;
  int hdr_dirty;
  int have_dirty;
  uint64_t epoch;
  unsigned char root[TK_ENC_ROOT];
  uint64_t ngroups;
  uint64_t nflushed;
  uint64_t cgroups;
  uint64_t *ctrs;
  unsigned char *ctags;
  unsigned char *cdirty;
} tk_enc_file;

static uint64_t tk_enc_k (tk_enc_file *f)
{
  return (uint64_t) (f->block / 8);
}

static sqlite3_int64 tk_enc_group_span (tk_enc_file *f)
{
  return (sqlite3_int64) (tk_enc_k(f) + 1) * (sqlite3_int64) (f->block + TK_ENC_OVH);
}

static sqlite3_int64 tk_enc_cframe_off (tk_enc_file *f, uint64_t g)
{
  return (sqlite3_int64) TK_ENC_HDR + (sqlite3_int64) g * tk_enc_group_span(f);
}

static sqlite3_int64 tk_enc_frame_off (tk_enc_file *f, uint64_t idx)
{
  if (!f->counters)
    return (sqlite3_int64) TK_ENC_HDR +
           (sqlite3_int64) idx * (sqlite3_int64) (f->block + TK_ENC_OVH);
  uint64_t k = tk_enc_k(f);
  return tk_enc_cframe_off(f, idx / k) +
         (sqlite3_int64) (1 + idx % k) * (sqlite3_int64) (f->block + TK_ENC_OVH);
}

static sqlite3_int64 tk_enc_phys (tk_enc_file *f, sqlite3_int64 nblocks)
{
  sqlite3_int64 fsz = (sqlite3_int64) (f->block + TK_ENC_OVH);
  if (!f->counters)
    return (sqlite3_int64) TK_ENC_HDR + nblocks * fsz;
  if (nblocks <= 0)
    return TK_ENC_HDR;
  sqlite3_int64 k = (sqlite3_int64) tk_enc_k(f);
  sqlite3_int64 g = (nblocks - 1) / k;
  sqlite3_int64 r = nblocks - g * k;
  return (sqlite3_int64) TK_ENC_HDR + g * tk_enc_group_span(f) + (1 + r) * fsz;
}

static uint64_t tk_enc_have_blocks (tk_enc_file *f, sqlite3_int64 psz)
{
  if (psz <= TK_ENC_HDR)
    return 0;
  sqlite3_int64 usable = psz - TK_ENC_HDR;
  sqlite3_int64 fsz = (sqlite3_int64) (f->block + TK_ENC_OVH);
  if (!f->counters)
    return (uint64_t) (usable / fsz);
  uint64_t k = tk_enc_k(f);
  sqlite3_int64 span = tk_enc_group_span(f);
  uint64_t full = (uint64_t) (usable / span);
  sqlite3_int64 rem = usable % span;
  uint64_t part = rem > fsz ? (uint64_t) ((rem - fsz) / fsz) : 0;
  if (part > k)
    part = k;
  return full * k + part;
}

static int tk_enc_aad (tk_enc_file *f, uint64_t idx, unsigned char *out)
{
  memcpy(out, f->salt, TK_ENC_SALT);
  tk_enc_put64(out + TK_ENC_SALT, idx);
  if (!f->counters)
    return TK_ENC_AAD;
  uint64_t ctr = idx < f->ngroups * tk_enc_k(f) ? f->ctrs[idx] : 0;
  tk_enc_put64(out + TK_ENC_SALT + 8, ctr);
  return TK_ENC_AAD_CTR;
}

static void tk_enc_caad (tk_enc_file *f, uint64_t g, unsigned char *out)
{
  memcpy(out, f->salt, TK_ENC_SALT);
  tk_enc_put64(out + TK_ENC_SALT, TK_ENC_CTR_MARK);
  tk_enc_put64(out + TK_ENC_SALT + 8, g);
}

static void tk_enc_root_calc (tk_enc_file *f, unsigned char *out)
{
  crypto_blake2b_ctx ctx;
  crypto_blake2b_keyed_init(&ctx, TK_ENC_ROOT, f->key, TK_ENC_KEYLEN);
  unsigned char n[16];
  tk_enc_put64(n, f->epoch);
  tk_enc_put64(n + 8, f->nflushed);
  crypto_blake2b_update(&ctx, n, 16);
  if (f->nflushed)
    crypto_blake2b_update(&ctx, f->ctags, f->nflushed * TK_ENC_TAG);
  crypto_blake2b_final(&ctx, out);
}

static int tk_enc_ctr_ensure (tk_enc_file *f, uint64_t g)
{
  if (g < f->cgroups) {
    if (g >= f->ngroups)
      f->ngroups = g + 1;
    return SQLITE_OK;
  }
  uint64_t cap = f->cgroups ? f->cgroups : 4;
  while (cap <= g)
    cap *= 2;
  uint64_t k = tk_enc_k(f);
  uint64_t *ctrs = (uint64_t *) sqlite3_realloc64(f->ctrs, cap * k * sizeof(uint64_t));
  if (!ctrs)
    return SQLITE_NOMEM;
  f->ctrs = ctrs;
  unsigned char *ctags = (unsigned char *) sqlite3_realloc64(f->ctags, cap * TK_ENC_TAG);
  if (!ctags)
    return SQLITE_NOMEM;
  f->ctags = ctags;
  unsigned char *cdirty = (unsigned char *) sqlite3_realloc64(f->cdirty, cap);
  if (!cdirty)
    return SQLITE_NOMEM;
  f->cdirty = cdirty;
  memset(f->ctrs + f->cgroups * k, 0, (cap - f->cgroups) * k * sizeof(uint64_t));
  memset(f->ctags + f->cgroups * TK_ENC_TAG, 0, (cap - f->cgroups) * TK_ENC_TAG);
  memset(f->cdirty + f->cgroups, 0, cap - f->cgroups);
  f->cgroups = cap;
  if (g >= f->ngroups)
    f->ngroups = g + 1;
  return SQLITE_OK;
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
  tk_enc_put64(h + 40, f->epoch | (f->hdr_dirty ? TK_ENC_DIRTY_BIT : 0));
  memcpy(h + 48, f->root, TK_ENC_ROOT);
  tk_enc_put64(h + 64, f->nflushed);
  int rc = f->p->pMethods->xWrite(f->p, h, TK_ENC_HDR, 0);
  if (rc == SQLITE_OK)
    f->hashdr = 1;
  return rc;
}

static int tk_enc_ctr_load (tk_enc_file *f, int disk_dirty)
{
  sqlite3_int64 psz = 0;
  int rc = f->p->pMethods->xFileSize(f->p, &psz);
  if (rc != SQLITE_OK)
    return rc;
  sqlite3_int64 fsz = (sqlite3_int64) (f->block + TK_ENC_OVH);
  sqlite3_int64 span = tk_enc_group_span(f);
  uint64_t k = tk_enc_k(f);
  uint64_t ng = psz > TK_ENC_HDR
    ? (uint64_t) ((psz - TK_ENC_HDR + span - 1) / span)
    : 0;
  if (ng) {
    rc = tk_enc_ctr_ensure(f, ng - 1);
    if (rc != SQLITE_OK)
      return rc;
  }
  f->ngroups = ng;
  if (f->nflushed > ng) {
    if (!disk_dirty)
      return SQLITE_NOTADB;
    f->nflushed = ng;
    f->hdr_dirty = 1;
    f->have_dirty = 1;
  }
  unsigned char *frame = NULL;
  if (ng) {
    frame = (unsigned char *) sqlite3_malloc64((sqlite3_uint64) fsz);
    if (!frame)
      return SQLITE_NOMEM;
  }
  for (uint64_t g = 0; g < ng; g ++) {
    int bad = 0;
    if (g >= f->nflushed) {
      bad = 1;
    } else {
      sqlite3_int64 off = tk_enc_cframe_off(f, g);
      if (off + fsz > psz) {
        bad = 1;
      } else {
        rc = f->p->pMethods->xRead(f->p, frame, (int) fsz, off);
        if (rc != SQLITE_OK) {
          sqlite3_free(frame);
          return rc;
        }
        unsigned char ad[TK_ENC_AAD_CTR];
        tk_enc_caad(f, g, ad);
        unsigned char *blk = frame + TK_ENC_NONCE;
        bad = crypto_aead_unlock(blk, frame + TK_ENC_NONCE + f->block, f->key, frame,
          ad, TK_ENC_AAD_CTR, blk, f->block) ? 1 : 0;
        if (!bad) {
          for (uint64_t i = 0; i < k; i ++)
            f->ctrs[g * k + i] = tk_enc_get64(blk + i * 8);
          memcpy(f->ctags + g * TK_ENC_TAG, frame + TK_ENC_NONCE + f->block, TK_ENC_TAG);
          f->cdirty[g] = 0;
        }
      }
      if (bad && !disk_dirty) {
        sqlite3_free(frame);
        return SQLITE_NOTADB;
      }
    }
    if (bad) {
      memset(f->ctrs + g * k, 0, k * sizeof(uint64_t));
      memset(f->ctags + g * TK_ENC_TAG, 0, TK_ENC_TAG);
      f->cdirty[g] = 1;
      f->have_dirty = 1;
    }
  }
  sqlite3_free(frame);
  unsigned char root[TK_ENC_ROOT];
  tk_enc_root_calc(f, root);
  if (memcmp(root, f->root, TK_ENC_ROOT)) {
    if (!disk_dirty)
      return SQLITE_NOTADB;
    memcpy(f->root, root, TK_ENC_ROOT);
    f->hdr_dirty = 1;
    f->have_dirty = 1;
  }
  return SQLITE_OK;
}

static int tk_enc_hdr_refresh (tk_enc_file *f)
{
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
  if (blk < 512 || blk > 65536 || (blk & (blk - 1)))
    return SQLITE_NOTADB;
  f->block = blk;
  f->lsize = (sqlite3_int64) tk_enc_get64(h + 16);
  memcpy(f->salt, h + 24, TK_ENC_SALT);
  int had = f->hashdr;
  f->hashdr = 1;
  if (!f->counters || f->have_dirty)
    return SQLITE_OK;
  uint64_t ep = tk_enc_get64(h + 40);
  int dirty = (ep & TK_ENC_DIRTY_BIT) != 0;
  ep &= ~TK_ENC_DIRTY_BIT;
  if (had && ep == f->epoch && !dirty)
    return SQLITE_OK;
  f->epoch = ep;
  memcpy(f->root, h + 48, TK_ENC_ROOT);
  f->nflushed = tk_enc_get64(h + 64);
  return tk_enc_ctr_load(f, dirty);
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
  unsigned char ad[TK_ENC_AAD_CTR];
  int adlen = tk_enc_aad(f, idx, ad);
  int bad = crypto_aead_unlock(out,
    frame + TK_ENC_NONCE + f->block, f->key, frame,
    ad, adlen, frame + TK_ENC_NONCE, f->block);
  if (bad && f->counters && !f->have_dirty) {
    uint64_t ep = f->epoch;
    if (tk_enc_hdr_refresh(f) == SQLITE_OK && f->epoch != ep) {
      adlen = tk_enc_aad(f, idx, ad);
      bad = crypto_aead_unlock(out,
        frame + TK_ENC_NONCE + f->block, f->key, frame,
        ad, adlen, frame + TK_ENC_NONCE, f->block);
    }
  }
  sqlite3_free(frame);

  if (bad) {
    if (f->softfail) {
      memset(out, 0, f->block);
      return SQLITE_OK;
    }
    return SQLITE_IOERR_READ;
  }
  return SQLITE_OK;
}

static int tk_enc_block_write (tk_enc_file *f, uint64_t idx, const unsigned char *in)
{
  sqlite3_int64 need = (sqlite3_int64) (f->block + TK_ENC_OVH);
  if (f->counters) {
    int rc0 = tk_enc_ctr_ensure(f, idx / tk_enc_k(f));
    if (rc0 != SQLITE_OK)
      return rc0;
    f->ctrs[idx] ++;
    f->cdirty[idx / tk_enc_k(f)] = 1;
    f->have_dirty = 1;
  }
  unsigned char *frame = (unsigned char *) sqlite3_malloc((int) need);
  if (!frame)
    return SQLITE_NOMEM;
  tk_enc_random(frame, TK_ENC_NONCE);
  unsigned char ad[TK_ENC_AAD_CTR];
  int adlen = tk_enc_aad(f, idx, ad);
  crypto_aead_lock(frame + TK_ENC_NONCE, frame + TK_ENC_NONCE + f->block,
    f->key, frame, ad, adlen, in, f->block);
  int rc = f->p->pMethods->xWrite(f->p, frame, (int) need, tk_enc_frame_off(f, idx));
  sqlite3_free(frame);
  return rc;
}

static int tk_enc_ctr_flush (tk_enc_file *f, int flags)
{
  if (!f->have_dirty || !f->hashdr)
    return SQLITE_OK;
  f->hdr_dirty = 1;
  int rc = tk_enc_hdr_flush(f);
  if (rc != SQLITE_OK)
    return rc;
  rc = f->p->pMethods->xSync(f->p, flags);
  if (rc != SQLITE_OK)
    return rc;
  sqlite3_int64 fsz = (sqlite3_int64) (f->block + TK_ENC_OVH);
  unsigned char *frame = (unsigned char *) sqlite3_malloc64((sqlite3_uint64) fsz);
  if (!frame)
    return SQLITE_NOMEM;
  uint64_t k = tk_enc_k(f);
  for (uint64_t g = 0; g < f->ngroups; g ++) {
    if (!f->cdirty[g])
      continue;
    tk_enc_random(frame, TK_ENC_NONCE);
    unsigned char *blk = frame + TK_ENC_NONCE;
    for (uint64_t i = 0; i < k; i ++)
      tk_enc_put64(blk + i * 8, f->ctrs[g * k + i]);
    unsigned char ad[TK_ENC_AAD_CTR];
    tk_enc_caad(f, g, ad);
    crypto_aead_lock(blk, frame + TK_ENC_NONCE + f->block, f->key, frame,
      ad, TK_ENC_AAD_CTR, blk, f->block);
    rc = f->p->pMethods->xWrite(f->p, frame, (int) fsz, tk_enc_cframe_off(f, g));
    if (rc != SQLITE_OK) {
      sqlite3_free(frame);
      return rc;
    }
    memcpy(f->ctags + g * TK_ENC_TAG, frame + TK_ENC_NONCE + f->block, TK_ENC_TAG);
    f->cdirty[g] = 0;
  }
  sqlite3_free(frame);
  rc = f->p->pMethods->xSync(f->p, flags);
  if (rc != SQLITE_OK)
    return rc;
  f->epoch ++;
  f->nflushed = f->ngroups;
  tk_enc_root_calc(f, f->root);
  f->hdr_dirty = 0;
  f->have_dirty = 0;
  return tk_enc_hdr_flush(f);
}

static void tk_enc_ctr_free (tk_enc_file *f)
{
  sqlite3_free(f->ctrs);
  sqlite3_free(f->ctags);
  sqlite3_free(f->cdirty);
  f->ctrs = NULL;
  f->ctags = NULL;
  f->cdirty = NULL;
  f->ngroups = 0;
  f->cgroups = 0;
}

static int tk_enc_io_close (sqlite3_file *pf)
{
  tk_enc_file *f = (tk_enc_file *) pf;
  int rc = SQLITE_OK;
  if (f->p->pMethods)
    rc = f->p->pMethods->xClose(f->p);
  tk_enc_ctr_free(f);
  crypto_wipe(f->key, TK_ENC_KEYLEN);
  return rc;
}

static int tk_enc_io_read (sqlite3_file *pf, void *buf, int amt, sqlite3_int64 off)
{
  tk_enc_file *f = (tk_enc_file *) pf;
  unsigned char *dst = (unsigned char *) buf;
  if (!f->hashdr || off + amt > f->lsize) {
    int rc0 = tk_enc_hdr_refresh(f);
    if (rc0 != SQLITE_OK)
      return rc0;
  }
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
  int rc = tk_enc_hdr_refresh(f);
  if (rc != SQLITE_OK)
    return rc;
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
    uint64_t have = tk_enc_have_blocks(f, psz);
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
  int rc = SQLITE_OK;
  if (!f->hashdr) {
    rc = tk_enc_hdr_refresh(f);
    if (rc != SQLITE_OK)
      return rc;
  }
  if (!f->hashdr && size == 0)
    return SQLITE_OK;
  if (!f->hashdr) {
    rc = tk_enc_hdr_flush(f);
    if (rc != SQLITE_OK)
      return rc;
  }
  sqlite3_int64 nblocks = (size + (sqlite3_int64) f->block - 1) / (sqlite3_int64) f->block;
  if (f->counters) {
    uint64_t k = tk_enc_k(f);
    uint64_t ng = nblocks > 0 ? (uint64_t) ((nblocks + (sqlite3_int64) k - 1) / (sqlite3_int64) k) : 0;
    if (ng < f->nflushed) {
      f->hdr_dirty = 1;
      f->have_dirty = 1;
      rc = tk_enc_hdr_flush(f);
      if (rc != SQLITE_OK)
        return rc;
      rc = f->p->pMethods->xSync(f->p, SQLITE_SYNC_NORMAL);
      if (rc != SQLITE_OK)
        return rc;
    }
    rc = f->p->pMethods->xTruncate(f->p, tk_enc_phys(f, nblocks));
    if (rc != SQLITE_OK)
      return rc;
    if (ng < f->ngroups) {
      memset(f->cdirty + ng, 0, f->ngroups - ng);
      f->ngroups = ng;
    }
    if (ng < f->nflushed)
      f->nflushed = ng;
    tk_enc_root_calc(f, f->root);
    f->lsize = size;
    return tk_enc_hdr_flush(f);
  }
  rc = f->p->pMethods->xTruncate(f->p, tk_enc_phys(f, nblocks));
  if (rc != SQLITE_OK)
    return rc;
  f->lsize = size;
  return tk_enc_hdr_flush(f);
}

static int tk_enc_io_sync (sqlite3_file *pf, int flags)
{
  tk_enc_file *f = (tk_enc_file *) pf;
  if (f->counters) {
    int rc = tk_enc_ctr_flush(f, flags);
    if (rc != SQLITE_OK)
      return rc;
  }
  return f->p->pMethods->xSync(f->p, flags);
}

static int tk_enc_io_filesize (sqlite3_file *pf, sqlite3_int64 *pSize)
{
  tk_enc_file *f = (tk_enc_file *) pf;
  int rc = tk_enc_hdr_refresh(f);
  if (rc != SQLITE_OK)
    return rc;
  *pSize = f->hashdr ? f->lsize : 0;
  return SQLITE_OK;
}

static int tk_enc_io_lock (sqlite3_file *pf, int l)
{
  tk_enc_file *f = (tk_enc_file *) pf;
  return f->p->pMethods->xLock(f->p, l);
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
    sqlite3_int64 phys = tk_enc_phys(f, nb);
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
  return (int) f->block;
}

static int tk_enc_io_device_char (sqlite3_file *pf)
{
  tk_enc_file *f = (tk_enc_file *) pf;
  int d = f->p->pMethods->xDeviceCharacteristics(f->p);

  d &= ~(SQLITE_IOCAP_ATOMIC | SQLITE_IOCAP_ATOMIC512 | SQLITE_IOCAP_ATOMIC1K |
         SQLITE_IOCAP_ATOMIC2K | SQLITE_IOCAP_ATOMIC4K | SQLITE_IOCAP_ATOMIC8K |
         SQLITE_IOCAP_ATOMIC16K | SQLITE_IOCAP_ATOMIC32K | SQLITE_IOCAP_ATOMIC64K |
         SQLITE_IOCAP_SAFE_APPEND | SQLITE_IOCAP_POWERSAFE_OVERWRITE);
#ifdef SQLITE_IOCAP_BATCH_ATOMIC
  d &= ~SQLITE_IOCAP_BATCH_ATOMIC;
#endif
  return d;
}

static int tk_enc_io_shm_map (sqlite3_file *pf, int ipg, int pgsz, int ext, void volatile **pp)
{
  tk_enc_file *f = (tk_enc_file *) pf;
  return f->p->pMethods->xShmMap(f->p, ipg, pgsz, ext, pp);
}

static int tk_enc_io_shm_lock (sqlite3_file *pf, int ofst, int n, int flags)
{
  tk_enc_file *f = (tk_enc_file *) pf;
  return f->p->pMethods->xShmLock(f->p, ofst, n, flags);
}

static void tk_enc_io_shm_barrier (sqlite3_file *pf)
{
  tk_enc_file *f = (tk_enc_file *) pf;
  f->p->pMethods->xShmBarrier(f->p);
}

static int tk_enc_io_shm_unmap (sqlite3_file *pf, int del)
{
  tk_enc_file *f = (tk_enc_file *) pf;
  return f->p->pMethods->xShmUnmap(f->p, del);
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

static const sqlite3_io_methods tk_enc_io_v2 = {
  2,
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
  tk_enc_io_shm_map,
  tk_enc_io_shm_lock,
  tk_enc_io_shm_barrier,
  tk_enc_io_shm_unmap,
  NULL, NULL
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

  int softf = SQLITE_OPEN_MAIN_JOURNAL;
#ifdef SQLITE_OPEN_WAL
  softf |= SQLITE_OPEN_WAL;
#endif
  f->softfail = (flags & softf) != 0;
  f->counters = (flags & SQLITE_OPEN_MAIN_DB) != 0;

  int keyed = SQLITE_OPEN_MAIN_DB | SQLITE_OPEN_MAIN_JOURNAL;
#ifdef SQLITE_OPEN_WAL
  keyed |= SQLITE_OPEN_WAL;
#endif
  int havekey = dbf ? tk_enc_key_find(dbf, f->key) : 0;
  if (!havekey) {
    if (flags & keyed)

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
    if (f->counters)
      tk_enc_root_calc(f, f->root);
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
    if (f->block < 512 || f->block > 65536 || (f->block & (f->block - 1))) {
      f->p->pMethods->xClose(f->p);
      crypto_wipe(f->key, TK_ENC_KEYLEN);
      return SQLITE_NOTADB;
    }
    f->lsize = (sqlite3_int64) tk_enc_get64(h + 16);
    memcpy(f->salt, h + 24, TK_ENC_SALT);
    f->hashdr = 1;
    if (f->counters) {
      uint64_t ep = tk_enc_get64(h + 40);
      int dirty = (ep & TK_ENC_DIRTY_BIT) != 0;
      f->epoch = ep & ~TK_ENC_DIRTY_BIT;
      memcpy(f->root, h + 48, TK_ENC_ROOT);
      f->nflushed = tk_enc_get64(h + 64);
      rc = tk_enc_ctr_load(f, dirty);
      if (rc != SQLITE_OK) {
        f->p->pMethods->xClose(f->p);
        tk_enc_ctr_free(f);
        crypto_wipe(f->key, TK_ENC_KEYLEN);
        return rc;
      }
    }
  }

  f->base.pMethods =
    (f->p->pMethods->iVersion >= 2 && f->p->pMethods->xShmMap)
      ? &tk_enc_io_v2 : &tk_enc_io;
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
