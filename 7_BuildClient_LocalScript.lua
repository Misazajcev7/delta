-- ============================================================================
-- BuildClient  (LocalScript)  ->  StarterPlayer > StarterPlayerScripts
--
-- Hierarchy (modules are CHILDREN of this LocalScript):
--   BuildClient (LocalScript)
--   ├─ Config       (ModuleScript)
--   ├─ ClientFloor  (ModuleScript)
--   ├─ BuildCamera  (ModuleScript)
--   ├─ BuildMover   (ModuleScript)
--   └─ BuildUI      (ModuleScript)
--
-- This script only wires the modules together.
-- ============================================================================
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(script:WaitForChild("Config"))
local ClientFloor = require(script:WaitForChild("ClientFloor"))
local BuildCamera = require(script:WaitForChild("BuildCamera"))
local BuildMover = require(script:WaitForChild("BuildMover"))
local BuildUI = require(script:WaitForChild("BuildUI"))

local remotes = ReplicatedStorage:WaitForChild("BuildRemotes")
local spawnFunction = remotes:WaitForChild("SpawnModel") :: RemoteFunction
local moveEvent = remotes:WaitForChild("MoveModel") :: RemoteEvent

local inBuildMode = false
local spawning = false
local ui -- assigned below (handlers reference it)

local function enterBuildMode(model: Model)
	inBuildMode = true
	BuildMover.setModel(model, moveEvent)
	ClientFloor.enable()
	BuildCamera.enter(model)
	ui.setStepText(BuildMover.getStep())
	ui.setBuildMode(true)
end

local function exitBuildMode()
	if not inBuildMode then return end
	inBuildMode = false
	BuildMover.flush()   -- make sure the server has the final position
	BuildMover.clear()
	BuildCamera.exit()
	if Config.FLOOR_ONLY_IN_BUILD_MODE then
		ClientFloor.disable()
	end
	ui.setBuildMode(false)
end

local function onSpawn()
	if spawning or inBuildMode then return end
	spawning = true
	ui.setSpawnBusy(true)

	local ok, model = pcall(function()
		return spawnFunction:InvokeServer()
	end)

	spawning = false
	ui.setSpawnBusy(false)

	if ok and typeof(model) == "Instance" and model:IsA("Model") then
		enterBuildMode(model)
	else
		warn("[BuildClient] Spawn failed (check Output on the server for LoadAsset errors).")
	end
end

ui = BuildUI.create({
	onSpawn = onSpawn,
	onMove = function(direction) BuildMover.nudge(direction) end,
	onRotate = function() BuildMover.rotate() end,
	onCycleStep = function() ui.setStepText(BuildMover.cycleStep()) end,
	onClimb = function(sign) ClientFloor.nudgeHeight(sign * Config.CLIMB_STEP) end,
	onDone = exitBuildMode,
})

if not Config.FLOOR_ONLY_IN_BUILD_MODE then
	ClientFloor.enable()
end
