-- Loading ~/.config/omashift/courses.lua and merging it over the built-ins.
--
--   courses_file.merge(core, path) -> added, problems
--
-- WHY THIS IS ITS OWN FILE
--
-- Three callers need it, and for a while only two of them did it. The engine
-- merged, `omashift --courses` merged, and `omashift --cycle-course` did not --
-- it asked `core.course_names()` in a fresh Lua state that had never read the
-- file. So a course written in courses.lua was LISTED by `--courses` and by the
-- menu, and `C` cycled straight past it: the one course the escape hatch exists
-- to add was the one course you could not select. Cockpit sat unreachable
-- between Blind Spots and Service Park for three days.
--
-- The comment above that cycling code already said the rule -- "a course added
-- in courses.lua has to appear on the menu without this script learning its
-- name" -- and the code satisfied the letter of it, since it hardcoded no
-- names. It just never loaded the file. Stating an invariant is not keeping it;
-- one implementation is.
--
-- `core` is passed in rather than required, because the callers reach it by
-- different routes (require, dofile, and a package.path set from argv) and this
-- file has no business having an opinion about which.
--
-- WRAPPED IN pcall AT EVERY STEP. A syntax error in a hand-edited config file
-- must cost the player their custom courses, not their game.
--
-- Like lib/scene.lua, this touches the filesystem so that core.lua does not.

local M = {}

-- Absent is not a problem: most people never write one. It returns no
-- complaints for that case, so a caller can print every problem it gets back
-- without first checking whether the file was there.
function M.merge(core, path)
  if type(path) ~= "string" or path == "" then return 0, {} end
  local f = io.open(path, "r")
  if not f then return 0, {} end
  f:close()

  local ok, defs = pcall(dofile, path)
  if not ok or type(defs) ~= "table" then
    return 0, { "courses file failed to load: " .. tostring(defs) }
  end
  return core.merge_courses(defs)
end

-- Where the file lives, by the same XDG rule every other path in the game uses.
-- Here rather than in each caller, so three of them cannot disagree about it.
function M.path()
  local config = os.getenv("XDG_CONFIG_HOME")
  if not config or config == "" then
    config = (os.getenv("HOME") or "") .. "/.config"
  end
  return config .. "/omashift/courses.lua"
end

return M
