-- ============================================================================
-- BuildMover  (ModuleScript, child of BuildClient)
-- Movement logic only (no UI). Moves the model locally for instant feedback
-- and sends the newest CFrame to the server at a throttled rate.
-- Directions are CAMERA-RELATIVE and snapped to world axes, so "Forward"
-- always means "away from the camera" however you've orbited.
-- ============================================================================
local Players = game:GetService("Players")
local Config = require(script.Parent.Config)

local BuildMover = {}

local player = Players.LocalPlayer
local model: Model? = nil
local moveRemote: RemoteEvent? = nil
local stepIndex = Config.DEFAULT_STEP_INDEX
local lastSend = 0
local sendQueued = false

local function snapToAxis(v: Vector3): Vector3
	local x, z = v.X, v.Z
	if math.abs(x) < 1e-3 and math.abs(z) < 1e-3 then
		return Vector3.new(0, 0, -1)
	end
	if math.abs(x) > math.abs(z) then
		return Vector3.new(math.sign(x), 0, 0)
	end
	return Vector3.new(0, 0, math.sign(z))
end

local function directionVector(name: string): Vector3?
	local cam = workspace.CurrentCamera
	if not cam then return nil end
	local forward = snapToAxis(cam.CFrame.LookVector)
	local right = forward:Cross(Vector3.yAxis)
	if name == "Forward" then return forward end
	if name == "Back" then return -forward end
	if name == "Right" then return right end
	if name == "Left" then return -right end
	if name == "Up" then return Vector3.yAxis end
	if name == "Down" then return -Vector3.yAxis end
	return nil
end

local function sendNow()
	if model and model.Parent and moveRemote then
		lastSend = os.clock()
		moveRemote:FireServer(model, model:GetPivot())
	end
end

-- Coalesces many nudges into at most one remote call per SEND_INTERVAL.
local function queueSend()
	if sendQueued then return end
	sendQueued = true
	task.delay(math.max(0, Config.SEND_INTERVAL - (os.clock() - lastSend)), function()
		sendQueued = false
		sendNow()
	end)
end

local function applyPivot(newPivot: CFrame): boolean
	local m = model
	if not m or not m.Parent then return false end
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		if (newPivot.Position - root.Position).Magnitude > Config.MAX_BUILD_RADIUS then
			return false -- too far from the player
		end
	end
	m:PivotTo(newPivot)
	queueSend()
	return true
end

function BuildMover.setModel(newModel: Model, remote: RemoteEvent)
	model = newModel
	moveRemote = remote
end

-- Sends the final position immediately (call before leaving build mode).
function BuildMover.flush()
	sendNow()
end

function BuildMover.clear()
	model = nil
end

function BuildMover.getStep(): number
	return Config.STEP_SIZES[stepIndex]
end

function BuildMover.cycleStep(): number
	stepIndex = stepIndex % #Config.STEP_SIZES + 1
	return Config.STEP_SIZES[stepIndex]
end

function BuildMover.nudge(directionName: string)
	local m = model
	local dir = directionVector(directionName)
	if not m or not dir then return end
	applyPivot(m:GetPivot() + dir * BuildMover.getStep())
end

function BuildMover.rotate()
	local m = model
	if not m then return end
	applyPivot(m:GetPivot() * CFrame.Angles(0, math.rad(Config.ROTATE_DEGREES), 0))
end

return BuildMover
