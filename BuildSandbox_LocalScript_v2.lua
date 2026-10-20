-- ============================================================================
-- BuildSandbox  (single LocalScript)  ->  StarterPlayer > StarterPlayerScripts
--
-- Fully self-contained: no ModuleScripts, no loadstring. CLIENT-ONLY prototype:
-- everything it spawns/moves exists only on your screen (other players and the
-- server never see it).
--
-- MODEL LOADING (see createModel below), in this order:
--   1) pcall(game:GetObjects("rbxassetid://11653804170")) -> objects[1]
--   2) a "BuildTemplate" Model/Part in ReplicatedStorage (if you saved one)
--   3) a basic Part block, so the script never errors out
--   The first successful fetch is cached as the active building template.
--
-- Sections: Config / ClientFloor / BuildCamera / BuildMover / BuildUI / Wiring
-- ============================================================================

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local player = Players.LocalPlayer

-- ============================================================================
-- CONFIG
-- ============================================================================
local Config = {
	ASSET_ID = 11653804170,            -- asset to fetch (see MODEL LOADING above)
	TEMPLATE_NAME = "BuildTemplate",   -- optional saved copy in ReplicatedStorage
	SPAWN_DISTANCE = 12,               -- studs in front of the player
	MAX_MODELS = 20,                   -- oldest local model removed beyond this
	STRIP_SCRIPTS = true,              -- remove scripts inside the cloned template

	-- Moving
	STEP_SIZES = { 0.5, 1, 2, 4 },     -- studs per nudge (Step button cycles)
	DEFAULT_STEP_INDEX = 2,
	CLIMB_STEP = 4,                    -- studs the player platform rises/lowers
	ROTATE_DEGREES = 90,
	HOLD_DELAY = 0.35,                 -- hold this long before auto-repeat
	HOLD_INTERVAL = 0.07,              -- repeat rate while holding
	MAX_BUILD_RADIUS = 300,            -- model can't be pushed farther than this from you

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
	local touchCount = 0
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

	function BuildCamera.enter(targetModel)
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
-- BUILD UI  (all GUI created in code; only calls the handlers it is given)
-- Buttons are >= 48px. Controls sit bottom-centre so they don't collide with
-- Roblox's thumbstick (left) or jump button (right).
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

	-- handlers: onSpawn, onMove(dirName), onRotate, onCycleStep, onClimb(sign), onDone
	function BuildUI.create(handlers)
		local gui = Instance.new("ScreenGui")
		gui.Name = "BuildSandboxGui"
		gui.ResetOnSpawn = false
		gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
		gui.DisplayOrder = 10

		-- ===== Main menu (CanvasGroup so the whole panel can fade) =====
		local PANEL_SIZE = UDim2.fromOffset(210, 168)
		local PANEL_POS = UDim2.fromOffset(12, 90)
		local ICON_SIZE = UDim2.fromOffset(60, 60)

		local panel = Instance.new("CanvasGroup")
		panel.Name = "MainPanel"
		panel.Size = PANEL_SIZE
		panel.Position = PANEL_POS
		panel.BackgroundColor3 = COLORS.Panel
		panel.BackgroundTransparency = 0.05
		panel.Parent = gui
		addCorner(panel, 16)

		local padding = Instance.new("UIPadding")
		padding.PaddingTop = UDim.new(0, 10)
		padding.PaddingBottom = UDim.new(0, 10)
		padding.PaddingLeft = UDim.new(0, 10)
		padding.PaddingRight = UDim.new(0, 10)
		padding.Parent = panel

		local list = Instance.new("UIListLayout")
		list.Padding = UDim.new(0, 8)
		list.SortOrder = Enum.SortOrder.LayoutOrder
		list.Parent = panel

		local title = Instance.new("TextLabel")
		title.BackgroundTransparency = 1
		title.Size = UDim2.new(1, 0, 0, 26)
		title.Font = Enum.Font.GothamBold
		title.Text = "Build Menu"
		title.TextColor3 = COLORS.Text
		title.TextSize = 20
		title.LayoutOrder = 1
		title.Parent = panel

		local spawnButton = makeButton(panel, "Spawn / Build", UDim2.new(1, 0, 0, 56), COLORS.Good)
		spawnButton.TextSize = 20
		spawnButton.LayoutOrder = 2

		local minimizeButton = makeButton(panel, "Minimize", UDim2.new(1, 0, 0, 48), COLORS.Button)
		minimizeButton.LayoutOrder = 3

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
		topBar.Size = UDim2.fromOffset(3 * 104 + 2 * 8, 48)
		topBar.Parent = controls

		local climbUp = makeButton(topBar, "Me ▲", UDim2.fromOffset(104, 48), COLORS.Button, UDim2.fromOffset(0, 0))
		local climbDown = makeButton(topBar, "Me ▼", UDim2.fromOffset(104, 48), COLORS.Button, UDim2.fromOffset(112, 0))
		local doneButton = makeButton(topBar, "Done ✔", UDim2.fromOffset(104, 48), COLORS.Good, UDim2.fromOffset(224, 0))

		local hint = Instance.new("TextLabel")
		hint.BackgroundTransparency = 1
		hint.AnchorPoint = Vector2.new(0.5, 0)
		hint.Position = UDim2.new(0.5, 0, 0, 64)
		hint.Size = UDim2.fromOffset(320, 20)
		hint.Font = Enum.Font.Gotham
		hint.Text = "Drag empty screen to orbit • Pinch / wheel to zoom"
		hint.TextColor3 = COLORS.Text
		hint.TextTransparency = 0.25
		hint.TextStrokeTransparency = 0.6
		hint.TextSize = 14
		hint.Parent = controls

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

		-- ===== Minimise / restore animation =====
		local minimized = false
		local animating = false
		local inBuild = false

		local function minimize()
			if minimized or animating then return end
			animating = true
			minimized = true
			local t = TweenService:Create(panel, TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
				Size = ICON_SIZE,
				Position = icon.Position,
				GroupTransparency = 1,
			})
			t.Completed:Connect(function()
				panel.Visible = false
				icon.Visible = not inBuild
				animating = false
			end)
			t:Play()
		end

		local function restore()
			if not minimized or animating then return end
			animating = true
			minimized = false
			icon.Visible = false
			panel.Size = ICON_SIZE
			panel.Position = icon.Position
			panel.GroupTransparency = 1
			panel.Visible = true
			local t = TweenService:Create(panel, TweenInfo.new(0.25, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
				Size = PANEL_SIZE,
				Position = PANEL_POS,
				GroupTransparency = 0,
			})
			t.Completed:Connect(function() animating = false end)
			t:Play()
		end

		makeDraggable(icon, gui, restore)

		-- ===== Wire buttons =====
		spawnButton.Activated:Connect(function() handlers.onSpawn() end)
		minimizeButton.Activated:Connect(minimize)
		rotateButton.Activated:Connect(function() handlers.onRotate() end)
		stepButton.Activated:Connect(function() handlers.onCycleStep() end)
		doneButton.Activated:Connect(function() handlers.onDone() end)

		gui.Parent = player:WaitForChild("PlayerGui")

		-- ===== API =====
		local api = {}

		function api.setBuildMode(on)
			inBuild = on
			controls.Visible = on
			panel.Visible = not on and not minimized
			icon.Visible = not on and minimized
		end

		function api.setStepText(value)
			stepButton.Text = "Step\n" .. tostring(value)
		end

		return api
	end
end

-- ============================================================================
-- MODEL CREATION / ASSET IMPORTER
-- ============================================================================
local buildFolder = Instance.new("Folder")
buildFolder.Name = "LocalBuilds"
buildFolder.Parent = workspace

local placedModels = {}
local activeTemplate = nil   -- clean copy of the fetched asset (kept unparented)
local warnedFallback = false

-- Tries to fetch the asset. Returns the first object, or nil on any failure.
local function loadAssetObject()
	local ok, objects = pcall(function()
		return game:GetObjects("rbxassetid://11653804170")
	end)
	if ok and type(objects) == "table" and typeof(objects[1]) == "Instance" then
		return objects[1]
	end
	return nil
end

-- Wraps non-Model results in a Model, anchors parts, strips scripts.
local function prepareModel(inst)
	local model = inst
	if not inst:IsA("Model") then
		model = Instance.new("Model")
		inst.Parent = model
	end
	model.Name = "BuildModel"

	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("BasePart") then
			d.Anchored = true
		elseif Config.STRIP_SCRIPTS and d:IsA("LuaSourceContainer") then
			d:Destroy()
		end
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
	return prepareModel(block)
end

local function createModel()
	-- Already fetched once: just clone the active template.
	if activeTemplate then
		return activeTemplate:Clone()
	end

	-- 1) game:GetObjects fetch
	local fetched = loadAssetObject()
	if fetched then
		local model = prepareModel(fetched)
		activeTemplate = model:Clone()   -- cache before the original is parented
		return model
	end

	-- 2) optional saved template in ReplicatedStorage
	local saved = ReplicatedStorage:FindFirstChild(Config.TEMPLATE_NAME)
	if saved and (saved:IsA("Model") or saved:IsA("BasePart")) then
		local model = prepareModel(saved:Clone())
		activeTemplate = model:Clone()
		return model
	end

	-- 3) basic block
	if not warnedFallback then
		warnedFallback = true
		warn(("[BuildSandbox] Could not load asset %d - using fallback block."):format(Config.ASSET_ID))
	end
	return makeFallbackBlock()
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
local inBuildMode = false
local ui

local function enterBuildMode(model)
	inBuildMode = true
	BuildMover.setModel(model)
	ClientFloor.enable()
	BuildCamera.enter(model)
	ui.setStepText(BuildMover.getStep())
	ui.setBuildMode(true)
end

local function exitBuildMode()
	if not inBuildMode then return end
	inBuildMode = false
	BuildMover.clear()
	BuildCamera.exit()
	if Config.FLOOR_ONLY_IN_BUILD_MODE then
		ClientFloor.disable()
	end
	ui.setBuildMode(false)
end

local function onSpawn()
	if inBuildMode then return end

	local model = createModel()
	if not placeInFrontOfPlayer(model) then
		model:Destroy()
		return
	end
	model.Parent = buildFolder

	table.insert(placedModels, model)
	while #placedModels > Config.MAX_MODELS do
		local oldest = table.remove(placedModels, 1)
		if oldest then oldest:Destroy() end
	end

	enterBuildMode(model)
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
