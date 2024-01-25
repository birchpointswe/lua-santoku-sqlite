local env = {

  name = "santoku-sqlite",
  version = "0.0.7-1",
  variable_prefix = "TK_SQLITE",
  license = "MIT",
  public = true,

  dependencies = {
    "lua >= 5.1",
    "santoku >= 0.0.162-1",
    "lsqlite3 >= 0.9.5",
  },

  test = {
    dependencies = {
      "santoku-test >= 0.0.8-1",
      "luassert >= 1.9.0-1",
      "luacov >= 0.15.0-1",
    }
  },

}

env.homepage = "https://github.com/treadwelllane/lua-" .. env.name
env.tarball = env.name .. "-" .. env.version .. ".tar.gz"
env.download = env.homepage .. "/releases/download/" .. env.version .. "/" .. env.tarball

return {
  type = "lib",
  env = env,
}

