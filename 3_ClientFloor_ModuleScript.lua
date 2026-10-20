-- ============================================================================
-- ClientFloor  (ModuleScript, child of BuildClient)
-- A collidable, invisible plate that exists ONLY on the local client and
-- follows the local player's feet (Heartbeat).
--
-- How the height is decided (no drifting):
--   * A short ray goes down from the root part. If it hits REAL ground
--     (character + our plate are ignored), the plate's top is set to that
--     height, so it stays flush with terrain / parts / the built model.
--   * If nothing is hit (jumping or walked off an edge), the plate keeps its
--     last height -> the player keeps walking on thin air.
-- ============================================================================
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Config = require(script.Parent.Config)

local ClientFloor = {}

local player = Players.LocalPlayer
local floorPart: Part? = nil
local floorTopY: number? = nil
local connection: RBXScriptConnection? = nil
local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude

local function getFeetOffset(humanoid: Humanoid, root: BasePart): number
	if humanoid.RigType == Enum.HumanoidRigType.R6 then
		return 3
	end
	return humanoid.HipHeight + root.Size.Y / 2
end

local function getCharacterParts()
	local character = player.Character
	if not character then return nil end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local root = character:FindFirstChild("HumanoidRootPart")
	if humanoid and root and root:IsA("BasePart") and humanoid.Health > 0 then
		return character, humanoid, root
	end
	return nil
end

local function createPart(): Part
	local part = Instance.new("Part")
	part.Name = "ClientFloor"
	part.Anchored = true
	part.CanCollide = true
	part.CanTouch = false
	part.CastShadow = false
	part.Locked = true
	part.Material = Enum.Material.SmoothPlastic
	part.Transparency = Config.FLOOR_TRANSPARENCY
	part.Size = Vector3.new(Config.FLOOR_SIZE, Config.FLOOR_THICKNESS, Config.FLOOR_SIZE)
	if Config.FLOOR_OUTLINE then
		local box = Instance.new("SelectionBox")
		box.Adornee = part
		box.LineThickness = 0.03
		box.Transparency = 0.6
		box.Color3 = Config.COLORS.Accent
		box.Parent = part
	end
	part.Parent = workspace -- created on the client => only the local player sees/collides
	return part
end

local function update()
	local character, humanoid, root = getCharacterParts()
	if not character or not humanoid or not root or not floorPart then return end

	local feetOffset = getFeetOffset(humanoid, root)
	rayParams.FilterDescendantsInstances = { character, floorPart }

	local hit = workspace:Raycast(root.Position, Vector3.new(0, -(feetOffset + 1.5), 0), rayParams)
	if hit then
		floorTopY = hit.Position.Y
	elseif floorTopY == nil then
		floorTopY = root.Position.Y - feetOffset
	end

	local v = root.AssemblyLinearVelocity
	local lead = Vector3.new(v.X, 0, v.Z) * Config.FLOOR_LEAD_TIME
	floorPart.CFrame = CFrame.new(
		root.Position.X + lead.X,
		(floorTopY :: number) - Config.FLOOR_THICKNESS / 2,
		root.Position.Z + lead.Z
	)
end

function ClientFloor.enable()
	if connection then return end
	floorTopY = nil
	floorPart = createPart()
	connection = RunService.Heartbeat:Connect(update)
end

function ClientFloor.disable()
	if connection then connection:Disconnect() connection = nil end
	if floorPart then floorPart:Destroy() floorPart = nil end
	floorTopY = nil
end

-- Raise / lower the player AND the plate together (used by the "Me ▲/▼" buttons
-- so you can reach building height in mid-air).
function ClientFloor.nudgeHeight(delta: number)
	local character, humanoid, root = getCharacterParts()
	if not character or not humanoid or not root or not floorTopY then return end

	if delta < 0 then
		-- Don't sink into real ground below us.
		rayParams.FilterDescendantsInstances = { character, floorPart }
		local hit = workspace:Raycast(
			Vector3.new(root.Position.X, floorTopY + 0.5, root.Position.Z),
			Vector3.new(0, delta - 1, 0),
			rayParams
		)
		if hit then
			delta = -math.max(0, floorTopY - hit.Position.Y)
		end
		if delta == 0 then return end
	end

	floorTopY += delta
	root.CFrame += Vector3.new(0, delta, 0)
	root.AssemblyLinearVelocity = Vector3.zero
end

return ClientFloor
