-- Write the golden rendering of the fixture career.
--
--   lua test/capture-stats.lua
--
-- REGENERATING IS A DELIBERATE ACT, for the same reason it is for the screens:
-- this pair is the contract. If test-stats.lua goes red, the fix is usually
-- lib/stats.lua or lib/screens.lua, not this. Regenerate when the Logbook is
-- MEANT to change, and let the diff show what changed.

local HERE = (arg[0]:match("(.*/)") or "./")
package.path = HERE .. "../lib/?.lua;" .. package.path
local stats = require("stats")
local screens = require("screens")

local f = assert(io.open(HERE .. "fixtures/stats/history.jsonl", "r"))
local history = f:read("*a")
f:close()

local text = screens.text(stats.model(history))
local out = assert(io.open(HERE .. "fixtures/stats/expected.txt", "w"))
out:write(text)
out:close()

print(("wrote %d bytes to test/fixtures/stats/expected.txt"):format(#text))
