local env = {
  name = "santoku-sqlite",
  version = "0.0.40-1",
  variable_prefix = "TK_SQLITE",
  license = "MIT",
  public = true,
  cflags = {
    "-I$(PWD)/deps/sqlite3/",
  },
  ldflags = {
    "$(PWD)/deps/sqlite3/sqlite-amalgamation-3490200/libsqlite3.a",
    "-lm",
  },
  dependencies = {
    "lua >= 5.1",
    "santoku >= 0.0.324-1",
  },
}

env.homepage = "https://github.com/treadwelllane/lua-" .. env.name
env.tarball = env.name .. "-" .. env.version .. ".tar.gz"
env.download = env.homepage .. "/releases/download/" .. env.version .. "/" .. env.tarball

return {
  env = env,
}
