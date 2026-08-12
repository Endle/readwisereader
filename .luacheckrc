-- KOReader runs LuaJIT, so Lua 5.1 semantics apply.
std = "luajit"

-- The plugin `require`s KOReader modules that only exist inside KOReader.
-- luacheck does not follow requires, so nothing extra is needed for those --
-- but the plugin must not rely on any global, which is what std enforces.

max_line_length = false

-- Existing debt, deliberately not gated on. The value of this lint run is
-- catching undefined variables (real crashes on device); the categories below
-- are cosmetic and would bury that signal in ~200 warnings. Burn them down and
-- delete the corresponding line to start enforcing it.
ignore = {
    "6..",  -- trailing / whitespace-only lines (~207 occurrences)
    "211",  -- unused local variable
    "212",  -- unused argument (methods that ignore self)
    "213",  -- unused loop variable
    "311",  -- value assigned to a variable is never read
    "4..",  -- variable shadowing
}
