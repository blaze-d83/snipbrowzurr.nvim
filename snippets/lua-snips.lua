local ls = require("luasnip")
local parse = ls.parser.parse_snippet

return {
  lua = {
    parse("fn", "local ${1:name} = function(${2:args})\n  ${0}\nend"),
    parse("req", "local ${1:mod} = require('${1}')"),
    parse("hdr", "-- ${1:Description} -- ${2:date}")
  }
}

