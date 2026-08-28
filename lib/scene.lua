-- Resolving a course's backdrop to a file that exists on THIS machine.
--
--   scene.resolve(core.scene_for("track-day")) -> { image = "/…jpg", scrim, theme }
--
-- WHY THIS IS ITS OWN FILE
--
-- Three producers need it now, not one. The engine publishes a scene with every
-- in-play screen; the Cabinet and the Logbook publish their own, because a
-- trophy case is not something a stage produces. It lived as a local inside
-- engine.lua, so those two got no backdrop at all and fell through to the drawn
-- sky, which is how the game came to flash a sunrise at you on the way in.
--
-- NOTHING IS SHIPPED. The backgrounds are stock Omarchy assets read from where
-- Omarchy already put them, user themes first so an override wins. A theme this
-- machine does not have resolves to nil and the caller falls back to Sky.qml,
-- which is drawn rather than loaded and works anywhere.
--
-- This is the one file in lib/ that touches the filesystem, and it touches it
-- for exactly one thing: does this path exist. core.lua stays pure.

local M = {}

M.THEME_DIRS = {
  (os.getenv("XDG_CONFIG_HOME") or ((os.getenv("HOME") or "") .. "/.config")) .. "/omarchy/themes",
  "/usr/share/omarchy/themes",
}

-- `override_scrim` replaces the scene's own dimming. Reading screens pass 0:
-- the Cabinet and the Logbook already dim the whole surface themselves, tuned
-- for text over a picture, and stacking a second scrim under that took the
-- backdrop to a tenth of its brightness and left a black rectangle.
function M.resolve(scene, override_scrim)
  if type(scene) ~= "table" or not scene.theme or not scene.file then return nil end
  for _, dir in ipairs(M.THEME_DIRS) do
    local path = ("%s/%s/backgrounds/%s"):format(dir, scene.theme, scene.file)
    local f = io.open(path, "r")
    if f then
      f:close()
      return {
        image = path,
        scrim = override_scrim or scene.scrim,
        theme = scene.theme,
      }
    end
  end
  return nil
end

return M
