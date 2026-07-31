function love.conf(t)
  local editor = os.getenv("POKEPORT_EDITOR") == "1"
  local developer = os.getenv("POKEPORT_DEV") == "1"
  if arg then
    for _, a in ipairs(arg) do
      if a == "--editor" then editor = true end
      if a == "--developer" then developer = true end
    end
  end
  -- main.lua runs in the same Lua state right after conf.lua; stash the
  -- decision in a global so it doesn't need to reparse `arg`.
  _G.POKEPORT_EDITOR_MODE = editor
  _G.POKEPORT_DEV_MODE = developer

  if editor then
    -- Same identity as the game, deliberately: the editor edits the game's
    -- saves and reads the game's ROM cache, both of which live under this
    -- folder.  A private editor identity would point love.filesystem at an
    -- empty directory in a packaged build, so `--editor` could not find
    -- data/generated at all (SaveIO.defaultPath already assumed this name).
    t.identity = os.getenv("POKEPORT_IDENTITY") or "pokemon-love2d"
    t.window.title = "Pokemon Save Editor"
    t.window.width = 1280
    t.window.height = 800
  else
    t.identity = os.getenv("POKEPORT_IDENTITY") or "pokemon-love2d"
    -- Version.lua has zero requires, so it is loadable this early; fall
    -- back to the plain title if the source is not mounted yet
    local ok, Version = pcall(require, "src.core.Version")
    t.window.title = ok and Version.title()
      or "gen1recomp"
    -- Open at the launcher's design size (the split-screen ROM selector is
    -- laid out for 1024x768). The window is resizable and the 160x144 game
    -- canvas letterboxes into whatever size it ends up, so this only sets the
    -- starting size, not the game's resolution.
    t.window.width = 1024
    t.window.height = 768
    -- Floor for the resizable desktop window.  The launcher's single-column
    -- layout is laid out against ~420 logical px of content, and the game
    -- canvas letterboxes fine below that, so this only stops a drag that would
    -- squeeze the cards past the point where their buttons still read.  Kept
    -- well under the smallest supported desktop display; mobile ignores it
    -- (fullscreen), so the handheld ports are unaffected.
    t.window.minwidth = 480
    t.window.minheight = 360
  end
  t.version = "11.5"
  t.window.vsync = 1
  t.modules.joystick = true
  t.modules.physics = false


  -- love.system is not loaded during love.conf; love._os is set by the
  -- engine before conf runs (LÖVE 11.x / 11.5).
  local osName = love._os
  local mobile = osName == "Android" or osName == "iOS"
  if mobile then
    -- resizable is what unlocks orientation.  SDL's Android backend, given no
    -- SDL_HINT_ORIENTATIONS (LÖVE sets none), calls setRequestedOrientation
    -- at window creation -- FULL_SENSOR when the window is resizable (rotates
    -- freely to portrait or landscape), otherwise locked to the window's w/h
    -- aspect.  So a non-resizable tall window forced portrait; resizable lets
    -- the game follow the device.  The renderer letterboxes the 160x144
    -- viewport into whatever size results, and the on-screen touch controls
    -- re-lay themselves out from the new window size, so both orientations
    -- just work.  FULL_SENSOR ignores the device's rotation lock, so
    -- GameActivity.setOrientationBis remaps it to FULL_USER after SDL has
    -- run: same orientations allowed, but auto-rotate being off now wins.
    -- iOS follows the Info.plist orientations
    -- (see mobile/ios/overlays/love-ios.plist, now portrait + landscape).
    t.window.resizable = true
    -- Starting size is a tall portrait hint; the OS resizes to the real
    -- display and rotations resize again. highdpi is required for Retina iOS
    -- (Android always behaves as highdpi).
    t.window.width = 1080
    t.window.height = 1920
    t.window.fullscreen = true
    t.window.highdpi = true
    -- Android only (irrelevant on iOS): puts the save directory under the
    -- app's external-files folder, which is readable/writable via USB or a
    -- file manager with no runtime permission, so RomImporter can ask the
    -- player to copy their ROM there instead of needing a native file
    -- picker (LOVE 11.5 on Android has none -- see src/import/RomImporter.lua).
    t.externalstorage = osName == "Android"
    -- LOVE 11.x exposes the phone's accelerometer as a 3-axis joystick by
    -- default.  Gravity keeps one axis pinned near +/-1.0 whenever the phone
    -- is held upright, so it streams past-deadzone joystickaxis events that
    -- both hid the touch overlay every instant (it reads as "a controller is
    -- in use") and, via the generic-joystick axis mapping (#459), walked the
    -- player around by tilt.  Nothing in the game reads the accelerometer,
    -- so drop the device entirely (#468).
    t.accelerometerjoystick = false
  else
    t.window.resizable = true
  end

  -- Consoles, last: LOVE Potion (3DS / Switch / Wii U) publishes love._console,
  -- set when the love module initializes and so available here exactly like
  -- love._os above.  This runs after the branch above because that branch's
  -- desktop `else` would otherwise re-enable resizing underneath it.
  if love._console then
    -- LOVE Potion implements the 12.0 API, so the 11.5 declared above trips its
    -- version-mismatch notice.  Ask the running engine for its own version
    -- string rather than hardcoding a second number that would need keeping in
    -- sync with whichever LOVE Potion release the player installed.
    t.version = love._version or t.version
    -- It builds no love.mouse module at all (its source/modules ships touch,
    -- joystick and keyboard, and nothing that points), so do not ask for one.
    t.modules.mouse = false
    -- Consoles own their resolution: the 3DS screens are fixed at 400x240 top
    -- and 320x240 bottom (800x240 in wide mode), while the Switch and Wii U
    -- backends set their size at runtime from the dock / TV state.  The desktop
    -- sizing above is not merely ignored there but actively wrong -- a 480x360
    -- minimum is larger than the whole 3DS screen -- so drop the fields that
    -- only ever described a resizable desktop window.
    t.window.minwidth = nil
    t.window.minheight = nil
    t.window.resizable = false
  end
end
