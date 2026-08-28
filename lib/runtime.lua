-- Where the game keeps the files it needs only while it is running, and the
-- one safe way to write them.
--
-- NOT /tmp, WHICH IS WHY THIS FILE EXISTS. The state document used to live at
-- /tmp/omashift-state.json, a path any local process can predict. Two things
-- were wrong with that, and the marketplace security review named both:
--
--   * the readers had no boundary. Another process could pre-place or replace
--     that file and feed arbitrary or oversized JSON into the overlay AND into
--     the bar, which runs inside somebody else's long-lived shell process.
--   * the writer was worse. write_atomic() staged through a fixed sibling
--     called <path>.tmp, so a symlink pre-created at that predictable name
--     redirected the write and could truncate any file the player owned.
--
-- THE DIRECTORY IS THE FIX. $XDG_RUNTIME_DIR is mode 0700, owned by the user,
-- and on a tmpfs the kernel already isolates per login. A subdirectory of it at
-- 0700 cannot be traversed by another user at all, so there is no one left to
-- win the races above. Everything else here is defense behind that line, not
-- instead of it.
--
-- The environment overrides still work and may point anywhere, because the
-- suite drives every screen through them. What they cannot do is opt out of
-- the safety: write_atomic stages through an unguessable name wherever it is
-- pointed, so an override changes the location and never the guarantee.

local M = {}

local function quote(s)
  return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

-- Our uid without a fork. Linux only, which this project already is: the game
-- talks to Hyprland and cannot run anywhere /proc does not exist.
local function uid()
  local f = io.open("/proc/self/status", "r")
  if not f then return nil end
  local found
  for line in f:lines() do
    found = line:match("^Uid:%s*(%d+)")
    if found then break end
  end
  f:close()
  return found
end

-- stat(1) does not dereference by default, so a symlink reports as one here
-- rather than as whatever it points at. That is the check we want: we are
-- asking what this name IS, not what it leads to.
local function describe(path)
  local p = io.popen(("stat -c '%%F|%%a|%%u' -- %s 2>/dev/null"):format(quote(path)))
  if not p then return nil end
  local line = p:read("*l")
  p:close()
  if not line then return nil end
  local kind, mode, owner = line:match("^([^|]*)|([^|]*)|([^|]*)$")
  return kind and { kind = kind, mode = mode, owner = owner } or nil
end

local runtime_dir

--- The private directory for this session's runtime files, created if needed.
---
--- Refuses rather than falls back to something unsafe. A pre-planted
--- /tmp/omashift-1000 owned by somebody else is exactly the attack this is
--- here to stop, so failing the check has to be fatal to the path, not a
--- warning we write into it anyway.
function M.dir()
  if runtime_dir then return runtime_dir end

  local base = os.getenv("XDG_RUNTIME_DIR")
  local want
  if base and #base > 0 then
    want = base .. "/omashift"
  else
    -- No runtime dir means no login session: ssh, cron, a bare shell. Still
    -- per user, still 0700, still verified below.
    local id = uid()
    if not id then return nil end
    want = "/tmp/omashift-" .. id
  end

  os.execute(("mkdir -p -m 700 -- %s 2>/dev/null"):format(quote(want)))

  local info = describe(want)
  if not info
    or info.kind ~= "directory"
    or info.mode ~= "700"
    or info.owner ~= uid()
  then
    return nil
  end

  runtime_dir = want
  return runtime_dir
end

--- Resolve one runtime file: the override if there is one, else ours.
---
--- Returns nil only when there is no override AND the directory failed its
--- checks, which is the case the callers have to treat as "do not write".
function M.path(env_name, filename)
  local override = os.getenv(env_name)
  if override and #override > 0 then return override end
  local dir = M.dir()
  return dir and (dir .. "/" .. filename) or nil
end

-- An unguessable stem for staged writes, drawn once and then counted from.
--
-- Lua 5.4 has no O_EXCL, and forking mktemp on every repaint is not affordable
-- in a loop that redraws on a countdown tick. Inside a 0700 directory an
-- unguessable name buys the same thing mkstemp buys: nobody else can be there
-- first, because nobody else can get in.
local token = (function()
  local f = io.open("/dev/urandom", "rb")
  if f then
    local bytes = f:read(8)
    f:close()
    if bytes and #bytes == 8 then
      return (bytes:gsub(".", function(c) return ("%02x"):format(c:byte()) end))
    end
  end
  -- Only reachable on a machine with no /dev/urandom, where the directory is
  -- still doing the real work. Time and address are weak, not nothing.
  return ("%x%s"):format(os.time(), tostring({}):match("0x(%x+)") or "0")
end)()

local seq = 0

--- Write text to path, atomically, without ever opening a predictable name.
---
--- rename(2) replaces the destination without following a symlink sitting
--- there, so a planted link at the target is overwritten rather than written
--- through. It is atomic on the same filesystem, which is why the staged file
--- is a sibling: a reader sees the old document or the new one, never half of
--- either. That property is load bearing, and predates this hardening: cycling
--- the course rewrites the file, and a keypress landing mid write used to find
--- no screen at all.
function M.write_atomic(path, text)
  if not path then return false end
  seq = seq + 1
  local tmp = ("%s.%s%d.tmp"):format(path, token, seq)
  local f = io.open(tmp, "w")
  if not f then return false end
  local ok = pcall(function()
    f:write(text)
    f:close()
  end)
  if not ok then
    os.remove(tmp)
    return false
  end
  if not os.rename(tmp, path) then
    os.remove(tmp)
    return false
  end
  return true
end

return M
