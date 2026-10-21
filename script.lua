-- ============================================================================
-- BuildSandbox  (single LocalScript)  ->  StarterPlayer > StarterPlayerScripts
--
-- Fully self-contained: no ModuleScripts, no loadstring. CLIENT-ONLY prototype:
-- everything it spawns/moves exists only on your screen (other players and the
-- server never see it).
--
-- NEW IN THIS VERSION
--   * Asset ID TextBox + "Add / Load" button. Each ID is fetched with
--       pcall(function() return game:GetObjects("rbxassetid://" .. assetId) end)
--     and every successful result is stored in a session list (savedAssets).
--   * Saved list: tap a row to select it, tap its ▶ to spawn it directly, tap
--     ✕ to remove it. "Spawn / Build" spawns whichever row is selected.
--   * "+" button in the panel header closes the panel (Frame.Visible = false).
--     Reopen with the B key (Config.TOGGLE_KEY), or set Config.SHOW_REOPEN_TAB
--     = true to get a small tap-to-reopen icon on touch devices.
--   * Movement controls (X/Y/Z), orbit camera and the mid-air client floor
--     (RenderStepped) are unchanged and fully integrated below.
--
-- NEW IN THIS VERSION (deletion + dragging)
--   * "Delete" (build-mode top bar) removes the model you are editing.
--   * "Clear (n)" (main panel) removes EVERY placed model. Tap it twice
--     within 2.5 s to confirm.
--   * Direct dragging: press on the model and drag (mouse left button or one
--     finger). "Drag: Ground (XZ)" slides it along the floor plane, "Drag:
--     Height (Y)" slides it straight up/down. The arrow buttons still work.
--   * Tap/click any placed model (outside build mode) to select and edit it.
--   * Drags that start on the model never orbit the camera; drags that start
--     on empty space still orbit it.
--
-- Sections: Config / ClientFloor / BuildCamera / BuildMover / ModelDragger /
--           BuildUI / Saved Assets / Wiring
-- ============================================================================

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local player = Players.LocalPlayer

-- ============================================================================
-- CONFIG
-- ============================================================================
local Config = {
	DEFAULT_ASSET_ID = "11653804170",  -- auto-loaded into the saved list at start
	AUTO_LOAD_DEFAULT = true,
	MAX_SAVED = 30,                    -- max entries in the saved list
	SPAWN_DISTANCE = 12,               -- studs in front of the player
	MAX_MODELS = 20,                   -- oldest local model removed beyond this
	STRIP_SCRIPTS = true,              -- remove scripts inside fetched assets

	-- Panel
	TOGGLE_KEY = Enum.KeyCode.B,       -- show/hide the panel (PC / emulator)
	SHOW_REOPEN_TAB = false,           -- true = small icon stays after closing with "+"
	CLOSE_ICON_ROTATION = 0,           -- 45 makes the "+" look like an "x"

	-- Moving
	STEP_SIZES = { 0.5, 1, 2, 4 },     -- studs per nudge (Step button cycles)
	DEFAULT_STEP_INDEX = 2,
	CLIMB_STEP = 4,                    -- studs the player platform rises/lowers
	ROTATE_DEGREES = 90,
	HOLD_DELAY = 0.35,                 -- hold this long before auto-repeat
	HOLD_INTERVAL = 0.07,              -- repeat rate while holding
	MAX_BUILD_RADIUS = 300,            -- model can't be pushed farther than this from you

	-- Dragging (direct screen drag in build mode)
	DRAG_SMOOTHNESS = 18,              -- higher = model follows the finger tighter
	DRAG_RAY_DISTANCE = 2000,          -- studs; max distance for drag / pick rays

	-- Tap-to-select (tap a placed model outside build mode to edit it again)
	TAP_MAX_MOVE = 10,                 -- pixels the finger may move and still count as a tap
	TAP_MAX_TIME = 0.5,                -- seconds

	-- Client floor
	FLOOR_ONLY_IN_BUILD_MODE = true,   -- false = platform always active
	FLOOR_SIZE = 16,
	FLOOR_THICKNESS = 1,
	FLOOR_TRANSPARENCY = 1,            -- 1 = invisible
	FLOOR_OUTLINE = false,             -- true = faint outline (debugging)
	FLOOR_LEAD_TIME = 0.15,            -- plate leads your velocity slightly

	-- Camera
	CAMERA_YAW = 35,                   -- degrees
	CAMERA_PITCH = 32,
	CAMERA_MIN_PITCH = 10,
	CAMERA_MAX_PITCH = 80,
	CAMERA_MIN_DIST = 12,
	CAMERA_MAX_DIST = 150,
	CAMERA_DIST_MULT = 1.8,            -- start distance = model size * this
	CAMERA_SMOOTHNESS = 9,             -- higher = snappier
	CAMERA_SCREEN_SHIFT = 0.12,        -- pushes model up, away from bottom controls
	CAMERA_ROTATE_SPEED = 0.008,       -- radians per pixel dragged
	CAMERA_EXIT_TIME = 0.5,

	COLORS = {
		Panel = Color3.fromRGB(28, 30, 38),
		Button = Color3.fromRGB(58, 62, 78),
		Accent = Color3.fromRGB(70, 130, 255),
		Good = Color3.fromRGB(60, 180, 110),
		Warn = Color3.fromRGB(230, 150, 50),
		Error = Color3.fromRGB(235, 95, 95),
		Text = Color3.fromRGB(255, 255, 255),
	},
}

-- ============================================================================
-- CLIENT FLOOR  (invisible, collidable, local-only plate under the feet)
-- Height comes from a downward ray: real ground found -> plate sits flush with
-- it; nothing found (jump / off an edge) -> plate keeps its last height, so you
-- keep walking on thin air. Updated on RenderStepped.
-- ============================================================================
local ClientFloor = {}
do
	local floorPart = nil
	local floorTopY = nil
	local connection = nil
	local rayParams = RaycastParams.new()
	rayParams.FilterType = Enum.RaycastFilterType.Exclude

	local function getFeetOffset(humanoid, root)
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

	local function createPart()
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
		part.Parent = workspace -- created on the client => local-only
		return part
	end

	local function update()
		local character, humanoid, root = getCharacterParts()
		if not character or not floorPart then return end

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
			floorTopY - Config.FLOOR_THICKNESS / 2,
			root.Position.Z + lead.Z
		)
	end

	function ClientFloor.enable()
		if connection then return end
		floorTopY = nil
		floorPart = createPart()
		connection = RunService.RenderStepped:Connect(update)
	end

	function ClientFloor.disable()
		if connection then connection:Disconnect() connection = nil end
		if floorPart then floorPart:Destroy() floorPart = nil end
		floorTopY = nil
	end

	-- Raises/lowers the player AND the plate together ("Me ▲/▼" buttons).
	function ClientFloor.nudgeHeight(delta)
		local character, humanoid, root = getCharacterParts()
		if not character or not floorTopY then return end

		if delta < 0 then
			-- don't sink into real ground below
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
end

-- ============================================================================
-- BUILD CAMERA  (smooth angled orbit around the model)
--   PC: right-mouse drag = orbit, wheel = zoom
--   Mobile: one-finger drag on empty screen = orbit, pinch = zoom
--   Touches that START on a GUI button are ignored.
-- ============================================================================
local BuildCamera = {}
do
	local RENDER_NAME = "BuildSandboxCamera"

	local active = false
	local model = nil
	local centerOffset = Vector3.zero
	local focus = Vector3.zero
	local yaw, pitch, distance = 0, 0, 30
	local connections = {}
	local touches = {}
	local claimed = {}        -- touches taken over by the model dragger
	local touchCount = 0
	local following = true    -- false while dragging: focus stays put so the
	                          -- camera doesn't chase the model being dragged
	local rightMouseDown = false
	local pinchStartDistance = nil
	local exitTween = nil

	local function rotate(dx, dy)
		yaw -= dx * Config.CAMERA_ROTATE_SPEED
		pitch = math.clamp(
			pitch + dy * Config.CAMERA_ROTATE_SPEED,
			math.rad(Config.CAMERA_MIN_PITCH),
			math.rad(Config.CAMERA_MAX_PITCH)
		)
	end

	local function setDistance(d)
		distance = math.clamp(d, Config.CAMERA_MIN_DIST, Config.CAMERA_MAX_DIST)
	end

	local function update(dt)
		local m = model
		if not active or not m or not m.Parent then return end
		local cam = workspace.CurrentCamera
		if not cam then return end

		local alpha = 1 - math.exp(-Config.CAMERA_SMOOTHNESS * dt)
		if following then
			focus = focus:Lerp(m:GetPivot():PointToWorldSpace(centerOffset), alpha)
		end

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

	function BuildCamera.enter(targetModel)
		if active then return end
		if exitTween then exitTween:Cancel() exitTween = nil end
		local cam = workspace.CurrentCamera
		if not cam then return end

		active = true
		following = true
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
			elseif input.UserInputType == Enum.UserInputType.Touch and not processed and not claimed[input] then
				touches[input] = true
				touchCount += 1
			end
		end))

		table.insert(connections, UserInputService.InputEnded:Connect(function(input)
			claimed[input] = nil
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
			if processed or next(claimed) ~= nil then return end
			if state == Enum.UserInputState.Begin then
				pinchStartDistance = distance
			elseif state == Enum.UserInputState.Change and pinchStartDistance then
				setDistance(pinchStartDistance / math.max(scale, 0.05))
			else
				pinchStartDistance = nil
			end
		end))
	end

	-- A touch that starts on the model belongs to the dragger, not the orbit.
	function BuildCamera.claim(input)
		claimed[input] = true
		if touches[input] then
			touches[input] = nil
			touchCount -= 1
		end
	end

	-- false = freeze the orbit focus (used while the model is being dragged).
	function BuildCamera.setFollow(on)
		following = on
	end

	function BuildCamera.exit()
		if not active then return end
		active = false
		model = nil
		RunService:UnbindFromRenderStep(RENDER_NAME)
		for _, c in ipairs(connections) do c:Disconnect() end
		table.clear(connections)
		table.clear(touches)
		table.clear(claimed)
		touchCount = 0
		rightMouseDown = false
		pinchStartDistance = nil

		local cam = workspace.CurrentCamera
		if not cam then return end

		local character = player.Character
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
end

-- ============================================================================
-- BUILD MOVER  (movement logic, no UI)
-- Directions are CAMERA-RELATIVE, snapped to world axes: "Forward" always
-- means "away from the camera" however you've orbited.
-- ============================================================================
local BuildMover = {}
do
	local model = nil
	local stepIndex = Config.DEFAULT_STEP_INDEX

	local function snapToAxis(v)
		local x, z = v.X, v.Z
		if math.abs(x) < 1e-3 and math.abs(z) < 1e-3 then
			return Vector3.new(0, 0, -1)
		end
		if math.abs(x) > math.abs(z) then
			return Vector3.new(math.sign(x), 0, 0)
		end
		return Vector3.new(0, 0, math.sign(z))
	end

	local function directionVector(name)
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

	local function applyPivot(newPivot)
		local m = model
		if not m or not m.Parent then return end
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if root and (newPivot.Position - root.Position).Magnitude > Config.MAX_BUILD_RADIUS then
			return -- too far from the player
		end
		m:PivotTo(newPivot)
	end

	function BuildMover.setModel(newModel) model = newModel end
	function BuildMover.clear() model = nil end

	-- Keeps a requested position within MAX_BUILD_RADIUS of the player.
	function BuildMover.clampPosition(pos)
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if not root then return pos end
		local offset = pos - root.Position
		if offset.Magnitude > Config.MAX_BUILD_RADIUS then
			return root.Position + offset.Unit * Config.MAX_BUILD_RADIUS
		end
		return pos
	end

	-- Moves the model's pivot to an exact position, keeping its rotation.
	function BuildMover.setPosition(pos)
		local m = model
		if not m or not m.Parent then return end
		m:PivotTo(m:GetPivot().Rotation + pos)
	end
	function BuildMover.getStep() return Config.STEP_SIZES[stepIndex] end

	function BuildMover.cycleStep()
		stepIndex = stepIndex % #Config.STEP_SIZES + 1
		return Config.STEP_SIZES[stepIndex]
	end

	-- directionName: "Forward","Back","Left","Right","Up","Down"
	function BuildMover.nudge(directionName)
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
end

-- ============================================================================
-- MODEL DRAGGER  (direct screen dragging of the model while in build mode)
--   Press on the model and drag: mouse (left button) or one finger.
--   "Ground" mode slides it on a horizontal plane (X/Z) through the grabbed
--   point; "Height" mode slides it straight up/down (Y) under your finger.
--   The model eases toward the finger every frame, which keeps drags smooth.
--   Parts need CanQuery = true to be grabbed (set when assets are loaded).
-- ============================================================================
local ModelDragger = {}
do
	local RENDER_NAME = "BuildSandboxDrag"
	local MODES = {
		{ name = "Ground", label = "Drag: Ground (XZ)" },
		{ name = "Height", label = "Drag: Height (Y)" },
	}

	local modeIndex = 1
	local model = nil
	local connections = {}
	local bound = false
	local dragging = false
	local dragInput = nil
	local activeMode = "Ground"
	local planePoint = Vector3.zero
	local planeNormal = Vector3.yAxis
	local grabOffset = Vector3.zero
	local startPosition = Vector3.zero
	local target = nil

	local rayParams = RaycastParams.new()
	rayParams.FilterType = Enum.RaycastFilterType.Include

	local function screenRay(position)
		local cam = workspace.CurrentCamera
		if not cam then return nil end
		return cam:ScreenPointToRay(position.X, position.Y)
	end

	local function pointOnPlane(ray)
		local denom = ray.Direction:Dot(planeNormal)
		if math.abs(denom) < 1e-3 then return nil end
		local t = (planePoint - ray.Origin):Dot(planeNormal) / denom
		if t <= 0 or t > Config.DRAG_RAY_DISTANCE then return nil end
		return ray.Origin + ray.Direction * t
	end

	local function updateTarget(position)
		local ray = screenRay(position)
		if not ray then return end
		local p = pointOnPlane(ray)
		if not p then return end

		local goal = p + grabOffset
		if activeMode == "Height" then
			goal = Vector3.new(startPosition.X, goal.Y, startPosition.Z)
		end
		target = BuildMover.clampPosition(goal)
	end

	-- Starts a drag only if the press actually lands on the model.
	local function beginDrag(input)
		local m = model
		local cam = workspace.CurrentCamera
		if not m or not m.Parent or not cam then return false end
		local ray = screenRay(input.Position)
		if not ray then return false end

		rayParams.FilterDescendantsInstances = { m }
		local hit = workspace:Raycast(ray.Origin, ray.Direction * Config.DRAG_RAY_DISTANCE, rayParams)
		if not hit then return false end

		activeMode = MODES[modeIndex].name
		if activeMode == "Ground" then
			planeNormal = Vector3.yAxis
		else
			local look = cam.CFrame.LookVector
			local flat = Vector3.new(look.X, 0, look.Z)
			if flat.Magnitude < 1e-3 then return false end
			planeNormal = flat.Unit
		end

		planePoint = hit.Position
		startPosition = m:GetPivot().Position
		grabOffset = startPosition - hit.Position
		target = nil
		dragging = true
		dragInput = input
		BuildCamera.setFollow(false)
		return true
	end

	local function endDrag()
		dragging = false
		dragInput = nil
		BuildCamera.setFollow(true)
	end

	local function step(dt)
		local m = model
		if not m or not m.Parent or not target then return end

		local alpha = 1 - math.exp(-Config.DRAG_SMOOTHNESS * dt)
		local current = m:GetPivot().Position
		local newPos = current:Lerp(target, alpha)
		if not dragging and (target - newPos).Magnitude < 0.02 then
			newPos = target
			target = nil
		end
		BuildMover.setPosition(newPos)
	end

	function ModelDragger.enable(newModel)
		ModelDragger.disable()
		model = newModel

		RunService:BindToRenderStep(RENDER_NAME, Enum.RenderPriority.Camera.Value - 1, step)
		bound = true

		table.insert(connections, UserInputService.InputBegan:Connect(function(input, processed)
			if processed or dragging then return end
			local t = input.UserInputType
			if t ~= Enum.UserInputType.MouseButton1 and t ~= Enum.UserInputType.Touch then return end
			if beginDrag(input) and t == Enum.UserInputType.Touch then
				BuildCamera.claim(input)
			end
		end))

		table.insert(connections, UserInputService.InputChanged:Connect(function(input)
			if not dragging then return end
			if input == dragInput
				or (dragInput.UserInputType == Enum.UserInputType.MouseButton1
					and input.UserInputType == Enum.UserInputType.MouseMovement) then
				updateTarget(input.Position)
			end
		end))

		table.insert(connections, UserInputService.InputEnded:Connect(function(input)
			if not dragging then return end
			if input == dragInput
				or (dragInput.UserInputType == Enum.UserInputType.MouseButton1
					and input.UserInputType == Enum.UserInputType.MouseButton1) then
				endDrag()
			end
		end))
	end

	function ModelDragger.disable()
		if bound then
			RunService:UnbindFromRenderStep(RENDER_NAME)
			bound = false
		end
		for _, c in ipairs(connections) do c:Disconnect() end
		table.clear(connections)
		if dragging then endDrag() end
		model = nil
		target = nil
	end

	-- Drop any pending drag motion (arrow buttons take over).
	function ModelDragger.cancel()
		target = nil
	end

	-- Ground (X/Z) <-> Height (Y). Returns the new button label.
	function ModelDragger.cycleMode()
		modeIndex = modeIndex % #MODES + 1
		return MODES[modeIndex].label
	end
end

-- ============================================================================
-- BUILD UI  (all GUI created in code; only calls the handlers it is given)
-- Buttons are >= 48px in build mode. Controls sit bottom-centre so they don't
-- collide with Roblox's thumbstick (left) or jump button (right).
--
-- handlers: onAdd(idText), onSelect(i), onSpawn(i|nil), onRemove(i),
--           onClearAll, onDeleteSelected, onToggleDragMode,
--           onMove(dirName), onRotate, onCycleStep, onClimb(sign), onDone
-- ============================================================================
local BuildUI = {}
do
	local COLORS = Config.COLORS
	local BTN = 56
	local GAP = 6
	local DRAG_THRESHOLD = 8

	local function isPress(input)
		return input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch
	end

	local function addCorner(gui, radius)
		local c = Instance.new("UICorner")
		c.CornerRadius = UDim.new(0, radius)
		c.Parent = gui
	end

	local function addPadding(gui, top, bottom, left, right)
		local p = Instance.new("UIPadding")
		p.PaddingTop = UDim.new(0, top)
		p.PaddingBottom = UDim.new(0, bottom)
		p.PaddingLeft = UDim.new(0, left)
		p.PaddingRight = UDim.new(0, right)
		p.Parent = gui
	end

	local function makeButton(parent, text, size, color, pos)
		local b = Instance.new("TextButton")
		b.AutoButtonColor = true
		b.BackgroundColor3 = color
		b.Size = size
		if pos then b.Position = pos end
		b.Font = Enum.Font.GothamBold
		b.Text = text
		b.TextColor3 = COLORS.Text
		b.TextSize = 18
		b.Parent = parent
		addCorner(b, 12)
		return b
	end

	-- Shrinks text to fit its box (up to maxSize) so labels never overflow.
	local function fitText(label, maxSize)
		label.TextScaled = true
		local c = Instance.new("UITextSizeConstraint")
		c.MaxTextSize = maxSize
		c.MinTextSize = 8
		c.Parent = label
	end

	-- Press-and-hold repeat. One shared token: releasing any press cancels it.
	local holdToken = 0
	UserInputService.InputEnded:Connect(function(input)
		if isPress(input) then holdToken += 1 end
	end)

	local function bindHold(button, callback)
		button.InputBegan:Connect(function(input)
			if not isPress(input) then return end
			holdToken += 1
			local mine = holdToken
			callback()
			task.spawn(function()
				task.wait(Config.HOLD_DELAY)
				while holdToken == mine do
					callback()
					task.wait(Config.HOLD_INTERVAL)
				end
			end)
		end)
	end

	-- Draggable GUI that still reports a "tap" when released without moving.
	local function makeDraggable(gui, screenGui, onTap)
		local dragInput = nil
		local startPos = Vector3.zero
		local startGuiPos = gui.Position
		local moved = false

		gui.InputBegan:Connect(function(input)
			if not isPress(input) or dragInput then return end
			dragInput = input
			startPos = input.Position
			startGuiPos = gui.Position
			moved = false
			input.Changed:Connect(function()
				if input.UserInputState == Enum.UserInputState.End and dragInput == input then
					dragInput = nil
					if not moved then onTap() end
				end
			end)
		end)

		UserInputService.InputChanged:Connect(function(input)
			local d = dragInput
			if not d then return end
			local mouseDrag = d.UserInputType == Enum.UserInputType.MouseButton1
				and input.UserInputType == Enum.UserInputType.MouseMovement
			if not (mouseDrag or input == d) then return end

			local delta = input.Position - startPos
			if not moved and delta.Magnitude > DRAG_THRESHOLD then moved = true end
			if moved then
				local maxX = screenGui.AbsoluteSize.X - gui.AbsoluteSize.X
				local maxY = screenGui.AbsoluteSize.Y - gui.AbsoluteSize.Y
				gui.Position = UDim2.fromOffset(
					math.clamp(startGuiPos.X.Offset + delta.X, 0, maxX),
					math.clamp(startGuiPos.Y.Offset + delta.Y, 0, maxY)
				)
			end
		end)
	end

	function BuildUI.create(handlers)
		local gui = Instance.new("ScreenGui")
		gui.Name = "BuildSandboxGui"
		gui.ResetOnSpawn = false
		gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
		gui.DisplayOrder = 10

		-- ===== Main menu (CanvasGroup so the whole panel can fade) =====
		local PANEL_SIZE = UDim2.fromOffset(290, 250)
		local PANEL_POS = UDim2.fromOffset(12, 44)
		local ICON_SIZE = UDim2.fromOffset(60, 60)

		local panel = Instance.new("CanvasGroup")
		panel.Name = "MainPanel"
		panel.Size = PANEL_SIZE
		panel.Position = PANEL_POS
		panel.BackgroundColor3 = COLORS.Panel
		panel.BackgroundTransparency = 0.05
		panel.Parent = gui
		addCorner(panel, 16)
		addPadding(panel, 8, 8, 8, 8)

		local list = Instance.new("UIListLayout")
		list.Padding = UDim.new(0, 6)
		list.SortOrder = Enum.SortOrder.LayoutOrder
		list.Parent = panel

		-- ----- Header: title + "+" close button -----
		local header = Instance.new("Frame")
		header.Name = "Header"
		header.BackgroundTransparency = 1
		header.Size = UDim2.new(1, 0, 0, 30)
		header.LayoutOrder = 1
		header.Parent = panel

		local title = Instance.new("TextLabel")
		title.BackgroundTransparency = 1
		title.Size = UDim2.new(1, -36, 1, 0)
		title.Font = Enum.Font.GothamBold
		title.Text = "Build Menu"
		title.TextColor3 = COLORS.Text
		title.TextSize = 20
		title.TextXAlignment = Enum.TextXAlignment.Left
		title.Parent = header

		local closeButton = makeButton(header, "+", UDim2.fromOffset(30, 30), COLORS.Error,
			UDim2.new(1, -30, 0, 0))
		closeButton.Name = "CloseButton"
		closeButton.TextSize = 26
		closeButton.Rotation = Config.CLOSE_ICON_ROTATION

		-- ----- Asset ID input row -----
		local inputRow = Instance.new("Frame")
		inputRow.Name = "InputRow"
		inputRow.BackgroundTransparency = 1
		inputRow.Size = UDim2.new(1, 0, 0, 38)
		inputRow.LayoutOrder = 2
		inputRow.Parent = panel

		local inputBox = Instance.new("TextBox")
		inputBox.Name = "AssetIdBox"
		inputBox.BackgroundColor3 = COLORS.Button
		inputBox.Size = UDim2.new(1, -96, 1, 0)
		inputBox.Font = Enum.Font.Gotham
		inputBox.PlaceholderText = "Asset ID (numbers)"
		inputBox.PlaceholderColor3 = Color3.fromRGB(160, 165, 180)
		inputBox.Text = ""
		inputBox.TextColor3 = COLORS.Text
		inputBox.TextSize = 16
		inputBox.TextXAlignment = Enum.TextXAlignment.Left
		inputBox.ClearTextOnFocus = false
		inputBox.Parent = inputRow
		addCorner(inputBox, 10)
		addPadding(inputBox, 0, 0, 8, 8)

		-- digits only (pasting "rbxassetid://123" keeps just the number)
		inputBox:GetPropertyChangedSignal("Text"):Connect(function()
			local cleaned = string.gsub(inputBox.Text, "%D", "")
			if cleaned ~= inputBox.Text then
				inputBox.Text = cleaned
			end
		end)

		local addButton = makeButton(inputRow, "Add / Load", UDim2.new(0, 90, 1, 0), COLORS.Accent,
			UDim2.new(1, -90, 0, 0))
		addButton.Name = "AddLoadButton"
		addButton.TextSize = 14

		-- ----- Status line -----
		local status = Instance.new("TextLabel")
		status.Name = "Status"
		status.BackgroundTransparency = 1
		status.Size = UDim2.new(1, 0, 0, 16)
		status.Font = Enum.Font.Gotham
		status.Text = "Enter an Asset ID and press Add / Load."
		status.TextColor3 = COLORS.Text
		status.TextTransparency = 0.2
		status.TextSize = 13
		status.TextXAlignment = Enum.TextXAlignment.Left
		status.TextTruncate = Enum.TextTruncate.AtEnd
		status.LayoutOrder = 3
		status.Parent = panel

		-- ----- Saved assets list -----
		local listFrame = Instance.new("ScrollingFrame")
		listFrame.Name = "SavedList"
		listFrame.BackgroundColor3 = Color3.fromRGB(20, 22, 28)
		listFrame.BorderSizePixel = 0
		listFrame.Size = UDim2.new(1, 0, 0, 84)
		listFrame.ScrollBarThickness = 4
		listFrame.ScrollingDirection = Enum.ScrollingDirection.Y
		listFrame.AutomaticCanvasSize = Enum.AutomaticSize.Y
		listFrame.CanvasSize = UDim2.new()
		listFrame.LayoutOrder = 4
		listFrame.Parent = panel
		addCorner(listFrame, 10)
		addPadding(listFrame, 4, 4, 4, 4)

		local listLayout = Instance.new("UIListLayout")
		listLayout.Padding = UDim.new(0, 4)
		listLayout.SortOrder = Enum.SortOrder.LayoutOrder
		listLayout.Parent = listFrame

		-- ----- Action row: Spawn + Minimize -----
		local actions = Instance.new("Frame")
		actions.Name = "Actions"
		actions.BackgroundTransparency = 1
		actions.Size = UDim2.new(1, 0, 0, 42)
		actions.LayoutOrder = 5
		actions.Parent = panel

		local spawnButton = makeButton(actions, "Spawn / Build", UDim2.new(0.44, -3, 1, 0), COLORS.Good)
		fitText(spawnButton, 17)
		local clearButton = makeButton(actions, "Clear (0)", UDim2.new(0.31, -3, 1, 0), COLORS.Warn,
			UDim2.new(0.44, 0, 0, 0))
		clearButton.Name = "ClearAllButton"
		fitText(clearButton, 15)
		local minimizeButton = makeButton(actions, "Minimize", UDim2.new(0.25, 0, 1, 0), COLORS.Button,
			UDim2.new(0.75, 0, 0, 0))
		fitText(minimizeButton, 14)

		-- Minimised icon (draggable, tap to restore)
		local icon = makeButton(gui, "🔨", ICON_SIZE, COLORS.Accent, PANEL_POS)
		icon.Name = "MinimizedIcon"
		icon.TextSize = 30
		icon.Visible = false
		icon.AutoButtonColor = false

		-- ===== Build controls =====
		local controls = Instance.new("Frame")
		controls.Name = "BuildControls"
		controls.BackgroundTransparency = 1
		controls.Size = UDim2.fromScale(1, 1)
		controls.Visible = false
		controls.Parent = gui

		-- Top bar: climb up/down, done
		local topBar = Instance.new("Frame")
		topBar.BackgroundTransparency = 1
		topBar.AnchorPoint = Vector2.new(0.5, 0)
		topBar.Position = UDim2.new(0.5, 0, 0, 10)
		topBar.Size = UDim2.fromOffset(4 * 88 + 3 * 6, 48)
		topBar.Parent = controls

		local climbUp = makeButton(topBar, "Me ▲", UDim2.fromOffset(88, 48), COLORS.Button, UDim2.fromOffset(0, 0))
		local climbDown = makeButton(topBar, "Me ▼", UDim2.fromOffset(88, 48), COLORS.Button, UDim2.fromOffset(94, 0))
		local deleteButton = makeButton(topBar, "Delete", UDim2.fromOffset(88, 48), COLORS.Error, UDim2.fromOffset(188, 0))
		local doneButton = makeButton(topBar, "Done ✔", UDim2.fromOffset(88, 48), COLORS.Good, UDim2.fromOffset(282, 0))
		for _, b in ipairs({ climbUp, climbDown, deleteButton, doneButton }) do
			b.TextSize = 16
		end

		local hint = Instance.new("TextLabel")
		hint.BackgroundTransparency = 1
		hint.AnchorPoint = Vector2.new(0.5, 0)
		hint.Position = UDim2.new(0.5, 0, 0, 102)
		hint.Size = UDim2.new(1, -16, 0, 20)
		hint.Font = Enum.Font.Gotham
		hint.Text = "Drag the model to move it • Drag empty space to orbit • Pinch / wheel to zoom"
		fitText(hint, 14)
		hint.TextColor3 = COLORS.Text
		hint.TextTransparency = 0.25
		hint.TextStrokeTransparency = 0.6
		hint.TextSize = 14
		hint.Parent = controls

		-- Switches what dragging the model does: slide on the ground (X/Z) or lift (Y).
		local dragModeButton = makeButton(controls, "Drag: Ground (XZ)", UDim2.fromOffset(160, 34), COLORS.Button,
			UDim2.new(0.5, 0, 0, 64))
		dragModeButton.Name = "DragModeButton"
		dragModeButton.AnchorPoint = Vector2.new(0.5, 0)
		dragModeButton.TextSize = 14

		-- Bottom bar: move cluster (left) + height cluster (right)
		local bar = Instance.new("Frame")
		bar.BackgroundTransparency = 1
		bar.AnchorPoint = Vector2.new(0.5, 1)
		bar.Position = UDim2.new(0.5, 0, 1, -12)
		bar.Size = UDim2.fromOffset(3 * BTN + 2 * GAP + 24 + 2 * BTN + GAP, 2 * BTN + GAP)
		bar.Parent = controls

		local step = BTN + GAP
		local function moveButton(text, dirName, col, row)
			local b = makeButton(bar, text, UDim2.fromOffset(BTN, BTN), COLORS.Button,
				UDim2.fromOffset(col * step, row * step))
			bindHold(b, function() handlers.onMove(dirName) end)
			return b
		end
		moveButton("FWD", "Forward", 1, 0)
		moveButton("◀", "Left", 0, 1)
		moveButton("BACK", "Back", 1, 1)
		moveButton("▶", "Right", 2, 1)

		local hx = 3 * step + 18 -- x origin of the height cluster
		local upButton = makeButton(bar, "▲ UP", UDim2.fromOffset(BTN, BTN), COLORS.Accent, UDim2.fromOffset(hx, 0))
		local downButton = makeButton(bar, "▼ DOWN", UDim2.fromOffset(BTN, BTN), COLORS.Accent, UDim2.fromOffset(hx, step))
		bindHold(upButton, function() handlers.onMove("Up") end)
		bindHold(downButton, function() handlers.onMove("Down") end)

		local rotateButton = makeButton(bar, "⟳", UDim2.fromOffset(BTN, BTN), COLORS.Warn, UDim2.fromOffset(hx + step, 0))
		rotateButton.TextSize = 28
		local stepButton = makeButton(bar, "Step\n1", UDim2.fromOffset(BTN, BTN), COLORS.Button, UDim2.fromOffset(hx + step, step))
		stepButton.TextSize = 16

		bindHold(climbUp, function() handlers.onClimb(1) end)
		bindHold(climbDown, function() handlers.onClimb(-1) end)

		-- ===== Panel visibility: "open" | "minimized" | "closed" =====
		local mode = "open"
		local inBuild = false
		local activeTween = nil

		local function applyVisibility()
			panel.Visible = (mode == "open") and not inBuild
			icon.Visible = not inBuild and (
				mode == "minimized" or (mode == "closed" and Config.SHOW_REOPEN_TAB)
			)
		end

		local function stopTween()
			if activeTween then
				local t = activeTween
				activeTween = nil
				t:Cancel()
			end
		end

		local function playPanelTween(goal, style, direction)
			stopTween()
			local t = TweenService:Create(panel, TweenInfo.new(0.25, style, direction), goal)
			activeTween = t
			t.Completed:Connect(function()
				if activeTween ~= t then return end -- cancelled / superseded
				activeTween = nil
				applyVisibility()
			end)
			t:Play()
		end

		local function minimize()
			if mode ~= "open" or activeTween then return end
			mode = "minimized"
			playPanelTween({
				Size = ICON_SIZE,
				Position = icon.Position,
				GroupTransparency = 1,
			}, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
		end

		local function restore()
			if mode ~= "minimized" or activeTween then return end
			mode = "open"
			icon.Visible = false
			panel.Size = ICON_SIZE
			panel.Position = icon.Position
			panel.GroupTransparency = 1
			panel.Visible = not inBuild
			playPanelTween({
				Size = PANEL_SIZE,
				Position = PANEL_POS,
				GroupTransparency = 0,
			}, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
		end

		-- Fully closes the panel: Frame.Visible = false (no icon unless SHOW_REOPEN_TAB).
		local function closePanel()
			stopTween()
			mode = "closed"
			panel.Visible = false
			applyVisibility()
		end

		local function reopen()
			stopTween()
			mode = "open"
			panel.Size = PANEL_SIZE
			panel.Position = PANEL_POS
			panel.GroupTransparency = 0
			applyVisibility()
		end

		makeDraggable(icon, gui, function()
			if mode == "minimized" then
				restore()
			elseif mode == "closed" then
				reopen()
			end
		end)

		-- ===== Wire buttons =====
		closeButton.Activated:Connect(closePanel)
		minimizeButton.Activated:Connect(minimize)

		-- "Clear (n)": tap twice within 2.5 s to remove every placed model.
		local placedCount = 0
		local clearArmed = false
		local clearToken = 0

		local function refreshClearButton()
			if clearArmed then
				clearButton.Text = "Sure?"
				clearButton.BackgroundColor3 = COLORS.Error
			else
				clearButton.Text = "Clear (" .. placedCount .. ")"
				clearButton.BackgroundColor3 = COLORS.Warn
			end
		end

		clearButton.Activated:Connect(function()
			if placedCount == 0 then return end
			clearToken += 1
			if clearArmed then
				clearArmed = false
				refreshClearButton()
				handlers.onClearAll()
				return
			end
			clearArmed = true
			refreshClearButton()
			local mine = clearToken
			task.delay(2.5, function()
				if clearToken == mine and clearArmed then
					clearArmed = false
					refreshClearButton()
				end
			end)
		end)

		addButton.Activated:Connect(function()
			inputBox:ReleaseFocus()
			handlers.onAdd(inputBox.Text)
		end)
		inputBox.FocusLost:Connect(function(enterPressed)
			if enterPressed then handlers.onAdd(inputBox.Text) end
		end)

		spawnButton.Activated:Connect(function() handlers.onSpawn(nil) end)
		rotateButton.Activated:Connect(function() handlers.onRotate() end)
		stepButton.Activated:Connect(function() handlers.onCycleStep() end)
		doneButton.Activated:Connect(function() handlers.onDone() end)
		deleteButton.Activated:Connect(function() handlers.onDeleteSelected() end)
		dragModeButton.Activated:Connect(function() handlers.onToggleDragMode() end)

		gui.Parent = player:WaitForChild("PlayerGui")

		-- ===== API =====
		local api = {}

		function api.setBuildMode(on)
			inBuild = on
			controls.Visible = on
			applyVisibility()
		end

		function api.setStepText(value)
			stepButton.Text = "Step\n" .. tostring(value)
		end

		function api.setStatus(text, colorKey)
			status.Text = text
			status.TextColor3 = COLORS[colorKey or "Text"] or COLORS.Text
			status.TextTransparency = (colorKey and colorKey ~= "Text") and 0 or 0.2
		end

		function api.clearInput()
			inputBox.Text = ""
		end

		function api.setPlacedCount(n)
			placedCount = n
			clearArmed = false
			clearToken += 1
			refreshClearButton()
		end

		function api.setDragModeText(text)
			dragModeButton.Text = text
		end

		function api.togglePanel()
			if mode == "open" then
				closePanel()
			else
				reopen()
			end
		end

		-- items: array of { label = string, removable = boolean }
		function api.refreshList(items, selectedIndex)
			for _, child in ipairs(listFrame:GetChildren()) do
				if child:IsA("GuiObject") then child:Destroy() end
			end

			for i, item in ipairs(items) do
				local row = Instance.new("Frame")
				row.Name = "Row" .. i
				row.LayoutOrder = i
				row.Size = UDim2.new(1, -6, 0, 34)
				row.BackgroundColor3 = (i == selectedIndex) and COLORS.Accent or COLORS.Button
				row.Parent = listFrame
				addCorner(row, 8)

				local rightWidth = item.removable and 68 or 36

				local pick = Instance.new("TextButton")
				pick.Name = "Select"
				pick.BackgroundTransparency = 1
				pick.AutoButtonColor = false
				pick.Size = UDim2.new(1, -rightWidth, 1, 0)
				pick.Font = Enum.Font.GothamMedium
				pick.Text = item.label
				pick.TextColor3 = COLORS.Text
				pick.TextSize = 14
				pick.TextXAlignment = Enum.TextXAlignment.Left
				pick.TextTruncate = Enum.TextTruncate.AtEnd
				pick.Parent = row
				addPadding(pick, 0, 0, 8, 0)
				pick.Activated:Connect(function() task.defer(handlers.onSelect, i) end)

				local spawnX = item.removable and -64 or -32
				local spawnRow = makeButton(row, "▶", UDim2.fromOffset(30, 28), COLORS.Good,
					UDim2.new(1, spawnX, 0.5, 0))
				spawnRow.Name = "SpawnRow"
				spawnRow.AnchorPoint = Vector2.new(0, 0.5)
				spawnRow.TextSize = 14
				spawnRow.Activated:Connect(function() task.defer(handlers.onSpawn, i) end)

				if item.removable then
					local remove = makeButton(row, "✕", UDim2.fromOffset(30, 28), COLORS.Error,
						UDim2.new(1, -32, 0.5, 0))
					remove.Name = "RemoveRow"
					remove.AnchorPoint = Vector2.new(0, 0.5)
					remove.TextSize = 14
					remove.Activated:Connect(function() task.defer(handlers.onRemove, i) end)
				end
			end
		end

		return api
	end
end

-- ============================================================================
-- SAVED ASSETS  (session-only list of fetched models)
-- Each entry: { id = "123" | nil, name = string, template = Model, builtin = bool }
-- Templates stay unparented; spawning always uses template:Clone().
-- ============================================================================
local buildFolder = Instance.new("Folder")
buildFolder.Name = "LocalBuilds"
buildFolder.Parent = workspace

local placedModels = {}
local savedAssets = {}
local selectedIndex = 1
local isLoading = false

local inBuildMode = false
local currentModel = nil   -- the placed model being edited in build mode
local ui

-- Turns GetObjects results into one anchored, script-free Model (or nil if it
-- contains no parts).
local function prepareTemplate(objects)
	local model
	if #objects == 1 and objects[1]:IsA("Model") then
		model = objects[1]
	else
		model = Instance.new("Model")
		for _, obj in ipairs(objects) do
			obj.Parent = model
		end
	end

	local hasPart = false
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("BasePart") then
			hasPart = true
			d.Anchored = true
			d.CanQuery = true -- so drag / tap raycasts can hit it
		elseif Config.STRIP_SCRIPTS and d:IsA("LuaSourceContainer") then
			d:Destroy()
		end
	end

	if not hasPart then
		model:Destroy()
		return nil
	end
	return model
end

local function makeFallbackBlock()
	local block = Instance.new("Part")
	block.Name = "FallbackBlock"
	block.Size = Vector3.new(4, 4, 4)
	block.Color = Color3.fromRGB(196, 140, 90)
	block.Material = Enum.Material.WoodPlanks
	block.Anchored = true
	local model = Instance.new("Model")
	block.Parent = model
	return model
end

local function refreshUI()
	local items = {}
	for i, entry in ipairs(savedAssets) do
		items[i] = {
			label = entry.id and (entry.name .. "  #" .. entry.id) or entry.name,
			removable = not entry.builtin,
		}
	end
	ui.refreshList(items, selectedIndex)
end

-- Places the model in front of the player, resting at foot level.
local function placeInFrontOfPlayer(model)
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not root or not humanoid then return false end

	local boxCF, boxSize = model:GetBoundingBox()
	local pivotToBox = model:GetPivot():ToObjectSpace(boxCF)

	local look = Vector3.new(root.CFrame.LookVector.X, 0, root.CFrame.LookVector.Z)
	look = look.Magnitude > 0.01 and look.Unit or Vector3.new(0, 0, -1)

	local feetOffset = humanoid.RigType == Enum.HumanoidRigType.R6 and 3
		or (humanoid.HipHeight + root.Size.Y / 2)
	local feetY = root.Position.Y - feetOffset

	local flat = root.Position + look * (Config.SPAWN_DISTANCE + math.max(boxSize.X, boxSize.Z) / 2)
	local center = Vector3.new(flat.X, feetY + boxSize.Y / 2, flat.Z)
	model:PivotTo(CFrame.new(center) * pivotToBox:Inverse())
	return true
end

-- ============================================================================
-- WIRING
-- ============================================================================
local function enterBuildMode(model)
	inBuildMode = true
	currentModel = model
	BuildMover.setModel(model)
	ClientFloor.enable()
	BuildCamera.enter(model)
	ModelDragger.enable(model)
	ui.setStepText(BuildMover.getStep())
	ui.setBuildMode(true)
end

local function exitBuildMode()
	if not inBuildMode then return end
	inBuildMode = false
	currentModel = nil
	ModelDragger.disable()
	BuildMover.clear()
	BuildCamera.exit()
	if Config.FLOOR_ONLY_IN_BUILD_MODE then
		ClientFloor.disable()
	end
	ui.setBuildMode(false)
end

-- index = which saved entry to spawn (nil = the selected one)
local function onSpawn(index)
	if inBuildMode then return end

	if index and savedAssets[index] then
		selectedIndex = index
	end
	local entry = savedAssets[selectedIndex]
	if not entry then return end

	local model = entry.template:Clone()
	model.Name = "BuildModel"
	if not placeInFrontOfPlayer(model) then
		model:Destroy()
		ui.setStatus("Character not ready yet.", "Warn")
		return
	end
	model.Parent = buildFolder

	table.insert(placedModels, model)
	while #placedModels > Config.MAX_MODELS do
		local oldest = table.remove(placedModels, 1)
		if oldest then oldest:Destroy() end
	end

	refreshUI()
	ui.setPlacedCount(#placedModels)
	ui.setStatus("Spawned: " .. entry.name, "Good")
	enterBuildMode(model)
end

local function onSelect(index)
	local entry = savedAssets[index]
	if not entry then return end
	selectedIndex = index
	refreshUI()
	ui.setStatus("Selected: " .. entry.name, "Text")
end

local function onRemove(index)
	local entry = savedAssets[index]
	if not entry or entry.builtin then return end

	entry.template:Destroy()
	table.remove(savedAssets, index)
	if index < selectedIndex then
		selectedIndex -= 1
	end
	selectedIndex = math.clamp(selectedIndex, 1, #savedAssets)

	refreshUI()
	ui.setStatus("Removed: " .. entry.name, "Text")
end

-- ----- Deleting placed models -----
local function removePlaced(model)
	for i, m in ipairs(placedModels) do
		if m == model then
			table.remove(placedModels, i)
			break
		end
	end
	model:Destroy()
end

-- Build-mode "Delete": removes the model currently being edited.
local function onDeleteSelected()
	local model = currentModel
	if not inBuildMode or not model then return end
	exitBuildMode()
	removePlaced(model)
	ui.setPlacedCount(#placedModels)
	ui.setStatus("Deleted the selected model.", "Warn")
end

-- Panel "Clear (n)": removes every model placed this session.
local function onClearAll()
	if inBuildMode then exitBuildMode() end
	local count = #placedModels
	for _, m in ipairs(placedModels) do
		m:Destroy()
	end
	table.clear(placedModels)
	buildFolder:ClearAllChildren()
	ui.setPlacedCount(0)
	ui.setStatus("Cleared " .. count .. " placed model(s).", "Warn")
end

-- ----- Tap a placed model (outside build mode) to select / edit it -----
local pickParams = RaycastParams.new()
pickParams.FilterType = Enum.RaycastFilterType.Include

local function pickPlacedModel(screenPos)
	if inBuildMode then return end
	local cam = workspace.CurrentCamera
	if not cam then return end

	local ray = cam:ScreenPointToRay(screenPos.X, screenPos.Y)
	pickParams.FilterDescendantsInstances = { buildFolder }
	local hit = workspace:Raycast(ray.Origin, ray.Direction * Config.DRAG_RAY_DISTANCE, pickParams)
	if not hit then return end

	-- climb to the top-level model inside LocalBuilds
	local inst = hit.Instance
	while inst and inst.Parent ~= buildFolder do
		inst = inst.Parent
	end
	if inst and inst:IsA("Model") then
		enterBuildMode(inst)
	end
end

local tapStarts = {}
local function tapKey(input)
	return input.UserInputType == Enum.UserInputType.Touch and input or "mouse"
end

UserInputService.InputBegan:Connect(function(input, processed)
	if processed or inBuildMode then return end
	local t = input.UserInputType
	if t ~= Enum.UserInputType.MouseButton1 and t ~= Enum.UserInputType.Touch then return end
	tapStarts[tapKey(input)] = { position = input.Position, time = os.clock() }
end)

UserInputService.InputEnded:Connect(function(input)
	local t = input.UserInputType
	if t ~= Enum.UserInputType.MouseButton1 and t ~= Enum.UserInputType.Touch then return end

	local key = tapKey(input)
	local start = tapStarts[key]
	tapStarts[key] = nil
	if not start or inBuildMode then return end

	local moved = (input.Position - start.position).Magnitude
	if moved <= Config.TAP_MAX_MOVE and os.clock() - start.time <= Config.TAP_MAX_TIME then
		pickPlacedModel(input.Position)
	end
end)

-- Add / Load: fetch an asset by ID and save it to the list.
local function onAdd(rawText)
	if isLoading then return end

	local assetId = string.gsub(rawText or "", "%D", "")
	assetId = string.gsub(assetId, "^0+", "")
	if assetId == "" or #assetId > 19 then
		ui.setStatus("Enter a numeric Asset ID.", "Warn")
		return
	end

	-- already saved? just select it
	for i, entry in ipairs(savedAssets) do
		if entry.id == assetId then
			selectedIndex = i
			refreshUI()
			ui.setStatus("Already saved: " .. entry.name, "Warn")
			return
		end
	end

	if #savedAssets >= Config.MAX_SAVED then
		ui.setStatus("List full (" .. Config.MAX_SAVED .. "). Remove one first.", "Warn")
		return
	end

	isLoading = true
	ui.setStatus("Loading " .. assetId .. "...", "Text")

	task.spawn(function()
		local ok, result = pcall(function()
			return game:GetObjects("rbxassetid://" .. assetId)
		end)

		if not (ok and type(result) == "table" and #result > 0) then
			isLoading = false
			warn(("[BuildSandbox] Could not load asset %s: %s"):format(assetId, tostring(result)))
			ui.setStatus("Failed to load " .. assetId .. ".", "Error")
			return
		end

		local label = string.sub(tostring(result[1].Name), 1, 24)
		local template = prepareTemplate(result)
		isLoading = false

		if not template then
			ui.setStatus("Asset " .. assetId .. " has no parts.", "Error")
			return
		end

		table.insert(savedAssets, {
			id = assetId,
			name = label,
			template = template,
			builtin = false,
		})
		selectedIndex = #savedAssets
		refreshUI()
		ui.clearInput()
		ui.setStatus("Saved: " .. label .. "  #" .. assetId, "Good")
	end)
end

ui = BuildUI.create({
	onAdd = onAdd,
	onSelect = onSelect,
	onSpawn = onSpawn,
	onRemove = onRemove,
	onClearAll = onClearAll,
	onDeleteSelected = onDeleteSelected,
	onToggleDragMode = function() ui.setDragModeText(ModelDragger.cycleMode()) end,
	onMove = function(direction)
		ModelDragger.cancel()
		BuildMover.nudge(direction)
	end,
	onRotate = function()
		ModelDragger.cancel()
		BuildMover.rotate()
	end,
	onCycleStep = function() ui.setStepText(BuildMover.cycleStep()) end,
	onClimb = function(sign) ClientFloor.nudgeHeight(sign * Config.CLIMB_STEP) end,
	onDone = exitBuildMode,
})

-- Always-available built-in entry so Spawn works even if every fetch fails.
table.insert(savedAssets, {
	id = nil,
	name = "Basic Block",
	template = makeFallbackBlock(),
	builtin = true,
})
selectedIndex = 1
refreshUI()

-- Panel toggle key (reopens the panel after closing it with "+")
UserInputService.InputBegan:Connect(function(input, processed)
	if processed or UserInputService:GetFocusedTextBox() then return end
	if input.KeyCode == Config.TOGGLE_KEY and not inBuildMode then
		ui.togglePanel()
	end
end)

if not Config.FLOOR_ONLY_IN_BUILD_MODE then
	ClientFloor.enable()
end

if Config.AUTO_LOAD_DEFAULT and Config.DEFAULT_ASSET_ID then
	onAdd(Config.DEFAULT_ASSET_ID)
end
