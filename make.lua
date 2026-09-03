local fs = require("santoku.fs")
local vendor = require("santoku.make.vendor")

local vendored = {
  {
    file = "deps/sqlite3/sqlite-amalgamation-3490200.zip",
    url = "https://www.sqlite.org/2025/sqlite-amalgamation-3490200.zip",
    sha256 = "921fc725517a694df7df38a2a3dfede6684024b5788d9de464187c612afb5918",
  },
}

local include = {}
for i = 1, #vendored do
  include[i] = vendored[i].file
end

local env = {
  name = "santoku-sqlite",
  version = "3.2.1-1",
  variable_prefix = "TK_SQLITE",
  license = "MIT",
  public = true,
  rules = {
    include = include,
  },
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
    "santoku-monocypher >= 2.0.1, < 3.0.0",
  },
  test = {
    dependencies = {
      "santoku-matrix >= 2.0.0, < 3.0.0",
    },
  },
  configure = function (submake, envs)
    for i = 1, #vendored do
      local v = vendored[i]
      local dest = fs.join(envs.root.build_dir, v.file)
      submake.target({ dest }, { "make.lua" }, function ()
        vendor.fetch(v, dest)
      end)
    end
  end,
}

env.homepage = "https://github.com/birchpointswe/lua-" .. env.name
env.tarball = env.name .. "-" .. env.version .. ".tar.gz"
env.download = env.homepage .. "/releases/download/" .. env.version .. "/" .. env.tarball

return {
  env = env,
}
