EMMAKE :=
ifneq (,$(findstring emcc,$(CC)))
EMMAKE := emmake
endif

SQLITE_VERSION := 3490200
SQLITE_YEAR := 2025
SQLITE_URL := https://www.sqlite.org/$(SQLITE_YEAR)/sqlite-amalgamation-$(SQLITE_VERSION).zip
SQLITE_DIR := sqlite-amalgamation-$(SQLITE_VERSION)

# Kept: json, subqueries, CTEs, cast, like/glob, collate, datetime, compound
# select, FTS, pragmas, case expressions, returning, upsert, foreign keys.
# Parser-referenced (can't omit): view, trigger, windowfunc, attach, detach,
# vacuum, reindex, analyze, altertable.

SQLITE_CFLAGS := \
  -Oz -flto -DNDEBUG \
  -DSQLITE_THREADSAFE=0 \
  -DSQLITE_OMIT_LOAD_EXTENSION \
  -DSQLITE_OMIT_SHARED_CACHE \
  -DSQLITE_OMIT_AUTHORIZATION \
  -DSQLITE_OMIT_DEPRECATED \
  -DSQLITE_OMIT_GET_TABLE \
  -DSQLITE_OMIT_PROGRESS_CALLBACK \
  -DSQLITE_OMIT_TRACE \
  -DSQLITE_OMIT_UTF16 \
  -DSQLITE_OMIT_COMPLETE \
  -DSQLITE_OMIT_TCL_VARIABLE \
  -DSQLITE_OMIT_DECLTYPE \
  -DSQLITE_OMIT_AUTOINIT \
  -DSQLITE_OMIT_EXPLAIN \
  -DSQLITE_OMIT_COMPILEOPTION_DIAGS \
  -DSQLITE_OMIT_INTEGRITY_CHECK \
  -DSQLITE_OMIT_SCHEMA_VERSION_PRAGMAS \
  -DSQLITE_OMIT_AUTOINCREMENT \
  -DSQLITE_OMIT_INCRBLOB \
  -DSQLITE_OMIT_GENERATED_COLUMNS \
  -DSQLITE_OMIT_BLOB_LITERAL \
  -DSQLITE_OMIT_INTROSPECTION_PRAGMAS \
  -DSQLITE_OMIT_LOOKASIDE \
  -DSQLITE_DQS=0 \
  -DSQLITE_DEFAULT_MEMSTATUS=0 \
  -DSQLITE_DEFAULT_WAL_SYNCHRONOUS=1 \
  -DSQLITE_LIKE_DOESNT_MATCH_BLOBS \
  -DSQLITE_ENABLE_JSON1 \
  -DSQLITE_ENABLE_MATH_FUNCTIONS \
  -DSQLITE_MAX_EXPR_DEPTH=0

results.mk:
	if ! [ -f sqlite-amalgamation-$(SQLITE_VERSION).zip ]; then \
	  wget $(SQLITE_URL); \
	fi
	if [ -d $(SQLITE_DIR) ]; then rm -rf $(SQLITE_DIR); fi
	unzip sqlite-amalgamation-$(SQLITE_VERSION).zip
	cd $(SQLITE_DIR) && $(CC) -c $(SQLITE_CFLAGS) $(CFLAGS) -o sqlite3.o sqlite3.c
	cd $(SQLITE_DIR) && $(AR) rcs libsqlite3.a sqlite3.o
	cp $(SQLITE_DIR)/sqlite3.h .
	mkdir -p ../../lib/santoku/sqlite
	cp $(SQLITE_DIR)/sqlite3.h ../../lib/santoku/sqlite/
	touch results.mk
