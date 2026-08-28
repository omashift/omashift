-- luacheck configuration.
--
--   luacheck lib test
--
-- WHAT NEEDS DECLARING, AND WHY
--
-- This code runs in two places that are not a plain Lua interpreter, and both
-- of them hand it globals it did not create. Without saying so here, luacheck
-- reports hundreds of undefined-variable warnings, all of them wrong, and a
-- linter that is wrong hundreds of times is one nobody runs twice.
--
-- What it is FOR is the opposite case: a variable this code thinks is a local
-- but is not. In Lua, using a local above the line that declares it silently
-- reads a nil GLOBAL instead. No error, no warning, just wrong behavior, and
-- it has happened four times in this project: `kmh` and `round` in stats.lua,
-- `idle_generation` in engine.lua, and `safe_match` in core.lua, which cost a
-- live debugging session. Every one of them is a global read that luacheck
-- flags immediately.

std = "lua54"

-- Hyprland's Lua API, injected into the config environment by the compositor.
-- Read only: nothing here assigns to it.
read_globals = { "hl" }

-- The engine deliberately publishes its handlers on _G, so that reloading it
-- swaps the logic without redefining the submap. See the binding-leak note in
-- the design log for why that matters.
globals = { "_G" }

-- Prose comments are wrapped by hand at 80. Code is not, and a length rule
-- would argue with the formatting rather than find anything.
max_line_length = false

files["test/"] = {
  -- The suites build fixtures and assertions at the top level on purpose;
  -- they are scripts, not modules.
  ignore = {
    "212",          -- unused argument, common in stub callbacks
    -- SHADOWING, and only in the suites. What is left after fixing everything
    -- real is a dozen loop variables named `r` or `a` standing over a
    -- top-level helper of the same name, in scripts a thousand lines long.
    -- That is not a defect and never becomes one.
    --
    -- The cases that DID matter were fixed rather than silenced, and they were
    -- the ones where a local FUNCTION shadowed another of the same name: two
    -- different `line` builders, where anything between them calling `line`
    -- silently gets whichever is nearer. Those are renamed. This rule stays ON
    -- for lib/, where a shadow can change what the game does.
    "421", "423", "431", "432", "433",
  },
}
