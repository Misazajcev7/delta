-- ============================================================================
-- Config  (ModuleScript, child of BuildClient LocalScript)
-- All tweakable numbers live here.
-- ============================================================================
local Config = {}

-- ---------- Moving ----------
Config.STEP_SIZES = { 0.5, 1, 2, 4 }   -- studs per nudge (Step button cycles)
Config.DEFAULT_STEP_INDEX = 2
Config.CLIMB_STEP = 4                   -- studs the player platform rises/lowers
Config.ROTATE_DEGREES = 90
Config.HOLD_DELAY = 0.35                -- hold a button this long before repeating
Config.HOLD_INTERVAL = 0.07             -- repeat rate while holding
Config.SEND_INTERVAL = 0.1              -- max network updates per second = 1/this
Config.MAX_BUILD_RADIUS = 300           -- must match the server

-- ---------- Client floor ----------
Config.FLOOR_ONLY_IN_BUILD_MODE = true  -- false = platform always active
Config.FLOOR_SIZE = 16
Config.FLOOR_THICKNESS = 1
Config.FLOOR_TRANSPARENCY = 1           -- 1 = invisible
Config.FLOOR_OUTLINE = false            -- true = faint SelectionBox (debugging)
Config.FLOOR_LEAD_TIME = 0.15           -- floor leads the player's velocity a bit

-- ---------- Camera ----------
Config.CAMERA_YAW = 35                  -- degrees
Config.CAMERA_PITCH = 32
Config.CAMERA_MIN_PITCH = 10
Config.CAMERA_MAX_PITCH = 80
Config.CAMERA_MIN_DIST = 12
Config.CAMERA_MAX_DIST = 150
Config.CAMERA_DIST_MULT = 1.8           -- start distance = model size * this
Config.CAMERA_SMOOTHNESS = 9            -- higher = snappier
Config.CAMERA_SCREEN_SHIFT = 0.12       -- pushes the model up, away from the bottom controls
Config.CAMERA_ROTATE_SPEED = 0.008      -- radians per pixel dragged
Config.CAMERA_EXIT_TIME = 0.5

-- ---------- UI ----------
Config.COLORS = {
	Panel = Color3.fromRGB(28, 30, 38),
	Button = Color3.fromRGB(58, 62, 78),
	Accent = Color3.fromRGB(70, 130, 255),
	Good = Color3.fromRGB(60, 180, 110),
	Warn = Color3.fromRGB(230, 150, 50),
	Text = Color3.fromRGB(255, 255, 255),
}

return Config
