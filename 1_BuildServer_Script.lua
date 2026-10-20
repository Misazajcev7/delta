--!strict
-- ============================================================================
-- BuildServer  (Script)  ->  place in ServerScriptService
-- ----------------------------------------------------------------------------
-- InsertService:LoadAsset() only works on the SERVER, so the server loads the
-- model, validates every move request from the client, and replicates the
-- result to everyone. The client never sends an asset id (can't be spoofed).
-- ============================================================================

local InsertService = game:GetService("InsertService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- ---------- Settings ----------
local ASSET_ID = 11653804170
local SPAWN_DISTANCE = 12          -- studs in front of the player
local MAX_BUILD_RADIUS = 300       -- keep in sync with Config.MAX_BUILD_RADIUS on client
local MAX_MODELS_PER_PLAYER = 20   -- oldest model is removed beyond this
local SPAWN_COOLDOWN = 1.5         -- seconds between spawns per player
local MOVE_MIN_INTERVAL = 0.03     -- server-side rate limit for move requests
local STRIP_SCRIPTS = true         -- remove scripts inside Toolbox models (safety)

-- ---------- Remotes ----------
local remotes = Instance.new("Folder")
remotes.Name = "BuildRemotes"

local spawnFunction = Instance.new("RemoteFunction")
spawnFunction.Name = "SpawnModel"
spawnFunction.Parent = remotes

local moveEvent = Instance.new("RemoteEvent")
moveEvent.Name = "MoveModel"
moveEvent.Parent = remotes

remotes.Parent = ReplicatedStorage

local buildFolder = Instance.new("Folder")
buildFolder.Name = "PlayerBuilds"
buildFolder.Parent = workspace

-- ---------- State ----------
local playerModels: { [Player]: { Model } } = {}
local lastSpawn: { [Player]: number } = {}
local lastMove: { [Player]: number } = {}

-- ---------- Helpers ----------
local function getCharacterParts(player: Player): (BasePart?, Humanoid?)
	local character = player.Character
	if not character then return nil, nil end
	local root = character:FindFirstChild("HumanoidRootPart")
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if root and root:IsA("BasePart") and humanoid and humanoid.Health > 0 then
		return root, humanoid
	end
	return nil, nil
end

-- Distance from HumanoidRootPart centre down to the soles of the feet.
local function getFeetOffset(humanoid: Humanoid, root: BasePart): number
	if humanoid.RigType == Enum.HumanoidRigType.R6 then
		return 3
	end
	return humanoid.HipHeight + root.Size.Y / 2
end

-- ---------- Spawn ----------
spawnFunction.OnServerInvoke = function(player: Player)
	local now = os.clock()
	if lastSpawn[player] and now - lastSpawn[player] < SPAWN_COOLDOWN then
		return nil
	end
	lastSpawn[player] = now

	local root, humanoid = getCharacterParts(player)
	if not root or not humanoid then return nil end

	-- LoadAsset can fail (asset private / not allowed / HTTP issues)
	local ok, container = pcall(function()
		return InsertService:LoadAsset(ASSET_ID)
	end)
	if not ok or not container then
		warn("[BuildServer] LoadAsset failed:", container)
		return nil
	end

	-- LoadAsset wraps its content in a Model; unwrap if it holds a single Model.
	local model: Model
	local children = container:GetChildren()
	if #children == 1 and children[1]:IsA("Model") then
		model = children[1] :: Model
		model.Parent = nil
		container:Destroy()
	else
		model = container
	end
	model.Name = "BuildModel"

	for _, descendant in ipairs(model:GetDescendants()) do
		if descendant:IsA("BasePart") then
			descendant.Anchored = true
		elseif STRIP_SCRIPTS and descendant:IsA("LuaSourceContainer") then
			descendant:Destroy()
		end
	end

	-- Place it in front of the player, resting on the ground/feet level.
	local boxCF, boxSize = model:GetBoundingBox()
	local pivotToBox = model:GetPivot():ToObjectSpace(boxCF)
	local look = Vector3.new(root.CFrame.LookVector.X, 0, root.CFrame.LookVector.Z)
	look = if look.Magnitude > 0.01 then look.Unit else Vector3.new(0, 0, -1)
	local feetY = root.Position.Y - getFeetOffset(humanoid, root)
	local horizontal = root.Position + look * (SPAWN_DISTANCE + math.max(boxSize.X, boxSize.Z) / 2)
	local center = Vector3.new(horizontal.X, feetY + boxSize.Y / 2, horizontal.Z)
	model:PivotTo(CFrame.new(center) * pivotToBox:Inverse())

	model:SetAttribute("OwnerUserId", player.UserId)
	model.Parent = buildFolder

	-- Track + cap per-player models
	local list = playerModels[player]
	if not list then
		list = {}
		playerModels[player] = list
	end
	table.insert(list, model)
	while #list > MAX_MODELS_PER_PLAYER do
		local oldest = table.remove(list, 1)
		if oldest then oldest:Destroy() end
	end

	return model
end

-- ---------- Move (validated) ----------
moveEvent.OnServerEvent:Connect(function(player: Player, model: any, cf: any)
	if typeof(model) ~= "Instance" or typeof(cf) ~= "CFrame" then return end
	if model.Parent ~= buildFolder or not model:IsA("Model") then return end
	if model:GetAttribute("OwnerUserId") ~= player.UserId then return end

	local now = os.clock()
	if lastMove[player] and now - lastMove[player] < MOVE_MIN_INTERVAL then return end
	lastMove[player] = now

	local root = getCharacterParts(player)
	if not root then return end

	-- "not (<= max)" also rejects NaN / inf values.
	if not ((cf.Position - root.Position).Magnitude <= MAX_BUILD_RADIUS) then return end

	model:PivotTo(cf:Orthonormalize())
end)

-- ---------- Cleanup ----------
Players.PlayerRemoving:Connect(function(player)
	local list = playerModels[player]
	if list then
		for _, m in ipairs(list) do m:Destroy() end
	end
	playerModels[player] = nil
	lastSpawn[player] = nil
	lastMove[player] = nil
end)
