local env = {
  name = "santoku-sqlite",
  version = "2.0.0-1",
  variable_prefix = "TK_SQLITE",
  license = "MIT",
  public = true,
  cflags = {
    "-I$(PWD)/deps/sqlite3/",
    "-I$(shell luarocks show santoku-monocypher --rock-dir)/include/",
  },
  ldflags = {
    "$(PWD)/deps/sqlite3/sqlite-amalgamation-3490200/libsqlite3.a",
    "-lm",
  },
  dependencies = {
    "lua == 5.1",
    "santoku >= 2.0.0, < 3.0.0",
    "santoku-monocypher >= 2.0.0, < 3.0.0",
  },
  test = {
    dependencies = {
      "santoku-matrix >= 2.0.0, < 3.0.0",
    },
  },
}

env.homepage = "https://github.com/birchpointswe/lua-" .. env.name
env.tarball = env.name .. "-" .. env.version .. ".tar.gz"
env.download = env.homepage .. "/releases/download/" .. env.version .. "/" .. env.tarball

return {
  env = env,
}
