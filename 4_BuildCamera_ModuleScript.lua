-- ============================================================================
-- BuildCamera  (ModuleScript, child of BuildClient)
-- Smooth angled orbit camera focused on the model.
--   PC:     right-mouse drag = orbit, wheel = zoom
--   Mobile: one-finger drag on empty screen = orbit, pinch = zoom
-- Touches that START on a GUI button are ignored, so controls never rotate it.
-- ============================================================================
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local Config = require(script.Parent.Config)

local BuildCamera = {}

local RENDER_NAME = "BuildCameraUpdate"

local active = false
local model: Model? = nil
local centerOffset = Vector3.zero   -- bounding-box centre in the model's pivot space
local focus = Vector3.zero          -- smoothed look-at point
local yaw, pitch, distance = 0, 0, 30
local connections: { RBXScriptConnection } = {}
local touches: { [InputObject]: boolean } = {}
local touchCount = 0
local rightMouseDown = false
local pinchStartDistance: number? = nil
local exitTween: Tween? = nil

local function rotate(dx: number, dy: number)
	yaw -= dx * Config.CAMERA_ROTATE_SPEED
	pitch = math.clamp(
		pitch + dy * Config.CAMERA_ROTATE_SPEED,
		math.rad(Config.CAMERA_MIN_PITCH),
		math.rad(Config.CAMERA_MAX_PITCH)
	)
end

local function setDistance(d: number)
	distance = math.clamp(d, Config.CAMERA_MIN_DIST, Config.CAMERA_MAX_DIST)
end

local function update(dt: number)
	local m = model
	if not active or not m or not m.Parent then return end
	local cam = workspace.CurrentCamera
	if not cam then return end

	local alpha = 1 - math.exp(-Config.CAMERA_SMOOTHNESS * dt)
	focus = focus:Lerp(m:GetPivot():PointToWorldSpace(centerOffset), alpha)

	local dir = Vector3.new(
		math.cos(pitch) * math.sin(yaw),
		math.sin(pitch),
		math.cos(pitch) * math.cos(yaw)
	)
	-- Dropping the camera along its local Y pushes the model UP on screen,
	-- keeping it clear of the bottom touch controls.
	local target = CFrame.lookAt(focus + dir * distance, focus)
		* CFrame.new(0, -distance * Config.CAMERA_SCREEN_SHIFT, 0)

	-- Lerping from the CURRENT camera CFrame = the smooth transition in.
	cam.CFrame = cam.CFrame:Lerp(target, alpha)
end

function BuildCamera.enter(targetModel: Model)
	if active then return end
	if exitTween then exitTween:Cancel() exitTween = nil end

	local cam = workspace.CurrentCamera
	if not cam then return end

	active = true
	model = targetModel

	local boxCF, boxSize = targetModel:GetBoundingBox()
	centerOffset = targetModel:GetPivot():ToObjectSpace(boxCF).Position
	focus = boxCF.Position
	yaw = math.rad(Config.CAMERA_YAW)
	pitch = math.rad(Config.CAMERA_PITCH)
	setDistance(boxSize.Magnitude * Config.CAMERA_DIST_MULT)

	cam.CameraType = Enum.CameraType.Scriptable
	RunService:BindToRenderStep(RENDER_NAME, Enum.RenderPriority.Camera.Value + 1, update)

	table.insert(connections, UserInputService.InputBegan:Connect(function(input, processed)
		if input.UserInputType == Enum.UserInputType.MouseButton2 then
			rightMouseDown = true
		elseif input.UserInputType == Enum.UserInputType.Touch and not processed then
			touches[input] = true
			touchCount += 1
		end
	end))

	table.insert(connections, UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton2 then
			rightMouseDown = false
		elseif touches[input] then
			touches[input] = nil
			touchCount -= 1
		end
	end))

	table.insert(connections, UserInputService.InputChanged:Connect(function(input, processed)
		local t = input.UserInputType
		if t == Enum.UserInputType.MouseMovement and rightMouseDown then
			rotate(input.Delta.X, input.Delta.Y)
		elseif t == Enum.UserInputType.Touch and touches[input] and touchCount == 1 then
			rotate(input.Delta.X, input.Delta.Y)
		elseif t == Enum.UserInputType.MouseWheel and not processed then
			setDistance(distance - input.Position.Z * distance * 0.1)
		end
	end))

	table.insert(connections, UserInputService.TouchPinch:Connect(function(_, scale, _, state, processed)
		if processed then return end
		if state == Enum.UserInputState.Begin then
			pinchStartDistance = distance
		elseif state == Enum.UserInputState.Change and pinchStartDistance then
			setDistance(pinchStartDistance / math.max(scale, 0.05))
		else
			pinchStartDistance = nil
		end
	end))
end

function BuildCamera.exit()
	if not active then return end
	active = false
	model = nil
	RunService:UnbindFromRenderStep(RENDER_NAME)
	for _, c in ipairs(connections) do c:Disconnect() end
	table.clear(connections)
	table.clear(touches)
	touchCount = 0
	rightMouseDown = false
	pinchStartDistance = nil

	local cam = workspace.CurrentCamera
	if not cam then return end

	local character = Players.LocalPlayer.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root or not root:IsA("BasePart") then
		cam.CameraType = Enum.CameraType.Custom
		return
	end

	-- Glide back behind the player, then hand control back to Roblox.
	local goal = CFrame.lookAt((root.CFrame * CFrame.new(0, 5, 12)).Position, root.Position)
	local value = Instance.new("CFrameValue")
	value.Value = cam.CFrame
	local conn = value.Changed:Connect(function(cf) cam.CFrame = cf end)

	local tween = TweenService:Create(
		value,
		TweenInfo.new(Config.CAMERA_EXIT_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ Value = goal }
	)
	exitTween = tween
	tween.Completed:Connect(function(state)
		conn:Disconnect()
		value:Destroy()
		if exitTween == tween then exitTween = nil end
		if state == Enum.PlaybackState.Completed and not active then
			cam.CameraType = Enum.CameraType.Custom
		end
	end)
	tween:Play()
end

return BuildCamera
