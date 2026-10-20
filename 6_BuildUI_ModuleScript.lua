-- ============================================================================
-- BuildUI  (ModuleScript, child of BuildClient)
-- Builds every GUI element in code. No game logic here: it only calls the
-- handler functions you pass to BuildUI.create().
--
-- Mobile-friendly: every button is >= 48px, controls sit bottom-centre so they
-- don't collide with Roblox's thumbstick (left) and jump button (right).
-- ============================================================================
local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local Config = require(script.Parent.Config)

local BuildUI = {}

local COLORS = Config.COLORS
local BTN = 56
local GAP = 6
local DRAG_THRESHOLD = 8

-- ---------- helpers ----------
local function isPress(input: InputObject): boolean
	return input.UserInputType == Enum.UserInputType.MouseButton1
		or input.UserInputType == Enum.UserInputType.Touch
end

local function addCorner(gui: GuiObject, radius: number)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, radius)
	c.Parent = gui
end

local function makeButton(parent: Instance, text: string, size: UDim2, color: Color3, pos: UDim2?): TextButton
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

-- Press-and-hold repeat (nudge buttons). One shared token: releasing any press cancels.
local holdToken = 0
UserInputService.InputEnded:Connect(function(input)
	if isPress(input) then holdToken += 1 end
end)

local function bindHold(button: GuiButton, callback: () -> ())
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
local function makeDraggable(gui: GuiObject, screenGui: ScreenGui, onTap: () -> ())
	local dragInput: InputObject? = nil
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

-- ---------- public ----------
export type Handlers = {
	onSpawn: () -> (),
	onMove: (direction: string) -> (),   -- "Forward","Back","Left","Right","Up","Down"
	onRotate: () -> (),
	onCycleStep: () -> (),
	onClimb: (sign: number) -> (),        -- +1 / -1 (moves the player platform)
	onDone: () -> (),
}

function BuildUI.create(handlers: Handlers)
	local gui = Instance.new("ScreenGui")
	gui.Name = "BuildSystemGui"
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

	-- Minimised icon (draggable)
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
	local function moveButton(text: string, dirName: string, col: number, row: number)
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

	gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")

	-- ===== API returned to the main script =====
	local api = {}

	function api.setBuildMode(on: boolean)
		inBuild = on
		controls.Visible = on
		panel.Visible = not on and not minimized
		icon.Visible = not on and minimized
	end

	function api.setStepText(value: number)
		stepButton.Text = "Step\n" .. tostring(value)
	end

	function api.setSpawnBusy(busy: boolean)
		spawnButton.Active = not busy
		spawnButton.Text = busy and "Loading…" or "Spawn / Build"
	end

	return api
end

return BuildUI
