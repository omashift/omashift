-- Write the golden (model, text) pair for every screen.
--
--   lua test/capture-screens.lua
--
-- The screens themselves live in test/screen-tour.lua, shared with
-- test/test-screens.lua so a screen cannot be captured one way and asserted
-- another.
--
-- REGENERATING IS A DELIBERATE ACT. These pairs are the contract: this model
-- must format to exactly this text. If a change to lib/screens.lua makes
-- test-screens.lua fail, the fix is almost always the formatter, not the
-- golden. Rerunning this to make a red test go green throws away the only
-- evidence that the refactor preserved behavior. Regenerate when a screen is
-- MEANT to change, and let the diff show it.

local HERE = (arg[0]:match("(.*/)") or "./")
package.path = HERE .. "../lib/?.lua;" .. package.path
local tour = dofile(HERE .. "screen-tour.lua")

local OUT = HERE .. "fixtures/screens"
os.execute(("mkdir -p %q"):format(OUT))

print("capturing screens:")

for _, step in ipairs(tour.steps) do
  local box = tour.run(step)
  local text, model = box:text(), box:model()
  assert(text and #text > 0, step.name .. ": nothing was rendered")
  assert(model and #model > 0, step.name .. ": nothing was published")

  local f = assert(io.open(("%s/%s.txt"):format(OUT, step.name), "w"))
  f:write(text); f:close()
  f = assert(io.open(("%s/%s.json"):format(OUT, step.name), "w"))
  f:write(model); f:close()

  print(("  %-18s %4d bytes text  %4d bytes model"):format(step.name, #text, #model))
  box:remove()
end

print()
print("wrote " .. #tour.steps .. " pairs to " .. OUT)
