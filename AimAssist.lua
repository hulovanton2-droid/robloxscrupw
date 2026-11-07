--!strict
--[[
    AimAssist.lua -- ONE LocalScript for YOUR OWN Roblox experience.
    Put it in StarterPlayer > StarterPlayerScripts (or save as AimAssist.client.luau for Rojo).

    Contains, inline: config, pure math, aim assist, debug ESP, settings menu.
    Hold RMB to aim, LMB to fire, RightShift to open the menu.

    SCOPE / HONEST LIMITS
    - This is a CLIENT script. It steers the local camera and draws an overlay.
    - It does NOT contain server authority. Roblox cannot put server code inside a
      LocalScript: a server Script is a separate instance by design. If you want
      damage, route it through your own RemoteEvent (see `fire()` below) and
      validate on the server: distance, FOV, line of sight, rate limit, alive.
      Never trust anything this client sends.
    - `wallCheck` here is LOCAL and cosmetic (target selection + ESP label).
      It is not an authoritative visibility check.
    - Targets are BaseParts tagged "AimTarget" via CollectionService, with an
      optional string attribute "TargetId" used as the label.
    - All numeric defaults are uncalibrated starting points, not measured values.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")

-- === BEGIN PURE MATH (extracted and unit-tested without Roblox) ===
type Vec3 = { x: number, y: number, z: number }
type Projected = { x: number, y: number, depth: number }
type Box = { x0: number, y0: number, x1: number, y1: number, visible: boolean }
type ConeResult = { ok: boolean, distance: number, angleDeg: number, reason: string }

local EPS = 1e-6
local HIDDEN: Box = { x0 = 0, y0 = 0, x1 = 0, y1 = 0, visible = false }

local MathUtil = {}

function MathUtil.vec(x: number, y: number, z: number): Vec3
	return { x = x, y = y, z = z }
end

function MathUtil.add(a: Vec3, b: Vec3): Vec3
	return { x = a.x + b.x, y = a.y + b.y, z = a.z + b.z }
end

function MathUtil.sub(a: Vec3, b: Vec3): Vec3
	return { x = a.x - b.x, y = a.y - b.y, z = a.z - b.z }
end

function MathUtil.scale(a: Vec3, s: number): Vec3
	return { x = a.x * s, y = a.y * s, z = a.z * s }
end

function MathUtil.dot(a: Vec3, b: Vec3): number
	return a.x * b.x + a.y * b.y + a.z * b.z
end

function MathUtil.length(a: Vec3): number
	return math.sqrt(MathUtil.dot(a, a))
end

function MathUtil.distance(a: Vec3, b: Vec3): number
	return MathUtil.length(MathUtil.sub(a, b))
end

function MathUtil.clamp(v: number, lo: number, hi: number): number
	if v < lo then return lo end
	if v > hi then return hi end
	return v
end

function MathUtil.clamp01(v: number): number
	return MathUtil.clamp(v, 0, 1)
end

function MathUtil.isFinite(v: number): boolean
	return v == v and v ~= math.huge and v ~= -math.huge
end

function MathUtil.isFiniteVec(v: Vec3): boolean
	return MathUtil.isFinite(v.x) and MathUtil.isFinite(v.y) and MathUtil.isFinite(v.z)
end

-- nil for zero-length / non-finite input instead of producing NaN downstream.
function MathUtil.normalize(a: Vec3): Vec3?
	if not MathUtil.isFiniteVec(a) then return nil end
	local len = MathUtil.length(a)
	if len < EPS then return nil end
	return MathUtil.scale(a, 1 / len)
end

function MathUtil.angleDeg(a: Vec3, b: Vec3): number?
	local na = MathUtil.normalize(a)
	local nb = MathUtil.normalize(b)
	if na == nil or nb == nil then return nil end
	return math.deg(math.acos(MathUtil.clamp(MathUtil.dot(na, nb), -1, 1)))
end

--[[ Cone test. `forward` is the camera direction. reason:
     "ok" | "invalid-vector" | "degenerate" | "out-of-range" | "outside-fov" ]]
function MathUtil.coneCheck(
	origin: Vec3,
	forward: Vec3,
	target: Vec3,
	fovDeg: number,
	maxDistance: number
): ConeResult
	local bad: ConeResult = { ok = false, distance = 0, angleDeg = 0, reason = "invalid-vector" }
	if not (MathUtil.isFiniteVec(origin) and MathUtil.isFiniteVec(forward) and MathUtil.isFiniteVec(target)) then
		return bad
	end
	if not (MathUtil.isFinite(fovDeg) and MathUtil.isFinite(maxDistance)) then return bad end
	if fovDeg <= 0 or maxDistance <= 0 then return bad end

	local toTarget = MathUtil.sub(target, origin)
	local dist = MathUtil.length(toTarget)
	if dist < EPS then
		return { ok = false, distance = 0, angleDeg = 0, reason = "degenerate" }
	end
	if dist > maxDistance then
		return { ok = false, distance = dist, angleDeg = 0, reason = "out-of-range" }
	end
	local nf = MathUtil.normalize(forward)
	if nf == nil then return bad end
	local dir = MathUtil.scale(toTarget, 1 / dist)
	local angle = math.deg(math.acos(MathUtil.clamp(MathUtil.dot(nf, dir), -1, 1)))
	if angle > fovDeg then
		return { ok = false, distance = dist, angleDeg = angle, reason = "outside-fov" }
	end
	return { ok = true, distance = dist, angleDeg = angle, reason = "ok" }
end

--[[ Steer toward a direction by a fraction of the remaining angle, capped by
     maxTurnDegPerSec * dt. Linear interpolation + renormalize; intended for the
     small angles of an aim cone, never for >90 degree turns. Never overshoots. ]]
function MathUtil.steerTowards(
	current: Vec3,
	target: Vec3,
	alpha: number,
	maxTurnDegPerSec: number,
	dt: number
): Vec3
	local nc = MathUtil.normalize(current)
	local nt = MathUtil.normalize(target)
	if nc == nil then return MathUtil.vec(0, 0, 1) end
	if nt == nil then return nc end

	local total = math.acos(MathUtil.clamp(MathUtil.dot(nc, nt), -1, 1))
	local a = MathUtil.clamp01(MathUtil.isFinite(alpha) and alpha or 0)
	local step = math.min(total * a, math.rad(math.max(maxTurnDegPerSec, 0)) * math.max(dt, 0))
	local t = total > EPS and math.min(step / total, 1) or 0
	local mixed = MathUtil.add(MathUtil.scale(nc, 1 - t), MathUtil.scale(nt, t))
	return MathUtil.normalize(mixed) or nc
end

--[[ Bounding box from already-projected corners. Any corner with depth <= 0
     (behind the camera) hides the whole box -- no near-plane clipping, so no
     mirrored/garbage boxes. Fully off-screen boxes are hidden too. ]]
function MathUtil.boundsFromProjected(
	points: { Projected },
	viewportW: number,
	viewportH: number
): Box
	if #points == 0 then return HIDDEN end
	if not (MathUtil.isFinite(viewportW) and MathUtil.isFinite(viewportH)) then return HIDDEN end
	if viewportW <= 0 or viewportH <= 0 then return HIDDEN end

	local minX, minY = math.huge, math.huge
	local maxX, maxY = -math.huge, -math.huge
	for _, p in ipairs(points) do
		if not (MathUtil.isFinite(p.x) and MathUtil.isFinite(p.y) and MathUtil.isFinite(p.depth)) then
			return HIDDEN
		end
		if p.depth <= 0 then return HIDDEN end
		minX = math.min(minX, p.x)
		minY = math.min(minY, p.y)
		maxX = math.max(maxX, p.x)
		maxY = math.max(maxY, p.y)
	end

	minX = MathUtil.clamp(minX, 0, viewportW)
	maxX = MathUtil.clamp(maxX, 0, viewportW)
	minY = MathUtil.clamp(minY, 0, viewportH)
	maxY = MathUtil.clamp(maxY, 0, viewportH)
	if maxX <= minX or maxY <= minY then return HIDDEN end
	return { x0 = minX, y0 = minY, x1 = maxX, y1 = maxY, visible = true }
end

function MathUtil.parseNumber(text: string, lo: number, hi: number, fallback: number): (number, boolean)
	local n: number? = tonumber(text)
	if n == nil or not MathUtil.isFinite(n) then return fallback, false end
	return MathUtil.clamp(n, lo, hi), true
end
-- === END PURE MATH ===

-- ---------------------------------------------------------------- config ---
local Config = {
	aimAssistEnabled = true,
	fovDeg = 12,              -- half-angle of the aim cone, degrees
	maxDistance = 250,        -- attack / selection distance, studs (LOCAL)
	smoothing = 0.18,         -- fraction of remaining angle per frame, 0..1
	maxTurnDegPerSec = 220,   -- hard cap on aim speed, degrees/second
	wallCheck = true,         -- LOCAL visibility for selection + ESP label
	espEnabled = true,
	espMaxDistance = 300,
	espShowBoxes = true,
	menuHotkey = "RightShift",
	targetTag = "AimTarget",
}

-- Runtime copy; the menu mutates this, never Config.
local settings: any = {}
for k, v in pairs(Config) do
	settings[k] = v
end

local function v3(v: Vector3): Vec3
	return { x = v.X, y = v.Y, z = v.Z }
end

local function fromVec(v: Vec3): Vector3
	return Vector3.new(v.x, v.y, v.z)
end

-- -------------------------------------------------------------------- ESP ---
local CORNERS = {
	{ -1, -1, -1 }, { 1, -1, -1 }, { -1, 1, -1 }, { 1, 1, -1 },
	{ -1, -1, 1 }, { 1, -1, 1 }, { -1, 1, 1 }, { 1, 1, 1 },
}

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local espGui = Instance.new("ScreenGui")
espGui.Name = "AimAssistEsp"
espGui.ResetOnSpawn = false
espGui.IgnoreGuiInset = true -- WorldToViewportPoint is viewport-relative
espGui.DisplayOrder = 10
espGui.Parent = playerGui

local pool = {}

local function createEntry()
	local box = Instance.new("Frame")
	box.BackgroundTransparency = 1
	box.BorderSizePixel = 0
	box.Visible = false
	box.Parent = espGui

	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 1.5
	stroke.Color = Color3.fromRGB(0, 255, 180)
	stroke.Parent = box

	local label = Instance.new("TextLabel")
	label.AnchorPoint = Vector2.new(0.5, 1)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.Code
	label.TextSize = 12
	label.TextStrokeTransparency = 0.4
	label.Visible = false
	label.Parent = espGui

	return { box = box, stroke = stroke, label = label }
end

local function projectCorners(part: BasePart, cam: Camera): { Projected }
	local out: { Projected } = {}
	local cf = part.CFrame
	local half = part.Size * 0.5
	for _, c in ipairs(CORNERS) do
		local world = cf * Vector3.new(c[1] * half.X, c[2] * half.Y, c[3] * half.Z)
		local p = cam:WorldToViewportPoint(world)
		table.insert(out, { x = p.X, y = p.Y, depth = p.Z })
	end
	return out
end

local function isOccluded(camPos: Vector3, targetPos: Vector3): boolean
	local delta = targetPos - camPos
	local dist = delta.Magnitude
	if dist < 1e-4 then return false end
	local hit = workspace:Raycast(camPos, delta)
	if hit == nil then return false end
	return (hit.Position - camPos).Magnitude < dist - 0.5
end

local function updateEsp(cam: Camera)
	if not settings.espEnabled then
		for _, e in ipairs(pool) do
			e.box.Visible = false
			e.label.Visible = false
		end
		return
	end

	-- Read every frame: resize / DPI changes need no GUI rebuild.
	local vp = cam.ViewportSize
	local camPos = cam.CFrame.Position
	local used = 0

	for _, inst in ipairs(CollectionService:GetTagged(settings.targetTag)) do
		if inst:IsA("BasePart") and inst:IsDescendantOf(workspace) then
			local part: BasePart = inst
			local dist = (part.Position - camPos).Magnitude
			if dist <= settings.espMaxDistance then
				used += 1
				local entry = pool[used]
				if entry == nil then
					entry = createEntry()
					pool[used] = entry
				end

				local bounds = MathUtil.boundsFromProjected(projectCorners(part, cam), vp.X, vp.Y)
				local blocked = settings.wallCheck and isOccluded(camPos, part.Position)
				local color: Color3
				local suffix: string
				if blocked then
					color = Color3.fromRGB(255, 120, 90)
					suffix = " | OCCLUDED"
				else
					color = Color3.fromRGB(0, 255, 180)
					suffix = ""
				end

				if not bounds.visible or not settings.espShowBoxes then
					entry.box.Visible = false
				else
					entry.box.Visible = true
					entry.box.Position = UDim2.fromOffset(bounds.x0, bounds.y0)
					entry.box.Size = UDim2.fromOffset(bounds.x1 - bounds.x0, bounds.y1 - bounds.y0)
					entry.stroke.Color = color
				end

				local id = part:GetAttribute("TargetId")
				local name: string
				if type(id) == "string" then
					name = id
				else
					name = part.Name
				end
				entry.label.Text = string.format("%s | %.0fm%s", name, dist, suffix)
				entry.label.TextColor3 = color
				entry.label.Visible = bounds.visible
				if bounds.visible then
					entry.label.Position = UDim2.fromOffset((bounds.x0 + bounds.x1) * 0.5, bounds.y0 - 4)
				end
			end
		end
	end

	for i = used + 1, #pool do
		pool[i].box.Visible = false
		pool[i].label.Visible = false
	end
end

-- ------------------------------------------------------------------- menu ---
local menuGui = Instance.new("ScreenGui")
menuGui.Name = "AimAssistMenu"
menuGui.ResetOnSpawn = false
menuGui.DisplayOrder = 20
menuGui.Enabled = false
menuGui.Parent = playerGui

local panel = Instance.new("Frame")
panel.Size = UDim2.fromOffset(360, 400)
panel.Position = UDim2.fromOffset(20, 20)
panel.BackgroundColor3 = Color3.fromRGB(18, 20, 26)
panel.BackgroundTransparency = 0.08
panel.BorderSizePixel = 0
panel.Parent = menuGui

local panelStroke = Instance.new("UIStroke")
panelStroke.Color = Color3.fromRGB(0, 255, 180)
panelStroke.Thickness = 1
panelStroke.Parent = panel

local layout = Instance.new("UIListLayout")
layout.SortOrder = Enum.SortOrder.LayoutOrder
layout.Padding = UDim.new(0, 4)
layout.Parent = panel

local layoutOrder = 0
local function addLabel(text: string): TextLabel
	local l = Instance.new("TextLabel")
	l.Size = UDim2.new(1, -16, 0, 18)
	l.BackgroundTransparency = 1
	l.TextXAlignment = Enum.TextXAlignment.Left
	l.Font = Enum.Font.Code
	l.TextSize = 12
	l.TextColor3 = Color3.fromRGB(215, 225, 235)
	l.Text = text
	l.LayoutOrder = layoutOrder
	layoutOrder += 1
	l.Parent = panel
	return l
end

addLabel("AIM ASSIST / DEBUG ESP -- RightShift to toggle")
addLabel("LOCAL values only. Server must validate FOV / distance / LOS.")

local NUMBER_ROWS = {
	{ key = "fovDeg", label = "FOV, deg", lo = 1, hi = 90 },
	{ key = "maxDistance", label = "Attack distance (local)", lo = 10, hi = 2000 },
	{ key = "smoothing", label = "Smoothing (0..1)", lo = 0, hi = 1 },
	{ key = "maxTurnDegPerSec", label = "Aim speed, deg/s", lo = 10, hi = 720 },
	{ key = "espMaxDistance", label = "ESP distance", lo = 10, hi = 2000 },
}
local TOGGLE_ROWS = {
	{ key = "aimAssistEnabled", label = "Aim assist" },
	{ key = "wallCheck", label = "Wall check (local)" },
	{ key = "espEnabled", label = "Debug ESP" },
	{ key = "espShowBoxes", label = "ESP boxes" },
}

local numberBoxes = {}
for _, row in ipairs(NUMBER_ROWS) do
	local line = Instance.new("Frame")
	line.Size = UDim2.new(1, -16, 0, 24)
	line.BackgroundTransparency = 1
	line.LayoutOrder = layoutOrder
	layoutOrder += 1
	line.Parent = panel

	local label = Instance.new("TextLabel")
	label.Size = UDim2.new(0.66, 0, 1, 0)
	label.BackgroundTransparency = 1
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.Font = Enum.Font.Code
	label.TextSize = 12
	label.TextColor3 = Color3.fromRGB(190, 200, 215)
	label.Text = row.label
	label.Parent = line

	local box = Instance.new("TextBox")
	box.Size = UDim2.new(0.34, 0, 1, 0)
	box.Position = UDim2.new(0.66, 0, 0, 0)
	box.BackgroundColor3 = Color3.fromRGB(30, 34, 42)
	box.TextColor3 = Color3.fromRGB(235, 240, 250)
	box.Font = Enum.Font.Code
	box.TextSize = 12
	box.Text = tostring(settings[row.key])
	box.PlaceholderText = string.format("%g..%g", row.lo, row.hi)
	box.ClearTextOnFocus = false
	box.Parent = line
	table.insert(numberBoxes, { row = row, box = box })
end

local toggleButtons = {}
for _, row in ipairs(TOGGLE_ROWS) do
	local button = Instance.new("TextButton")
	button.Size = UDim2.new(1, -16, 0, 22)
	button.BackgroundColor3 = Color3.fromRGB(30, 34, 42)
	button.Font = Enum.Font.Code
	button.TextSize = 12
	button.TextXAlignment = Enum.TextXAlignment.Left
	button.LayoutOrder = layoutOrder
	layoutOrder += 1
	button.Parent = panel
	table.insert(toggleButtons, { row = row, button = button })
end

local function refreshToggles()
	for _, entry in ipairs(toggleButtons) do
		local on = settings[entry.row.key] == true
		local state: string
		local color: Color3
		if on then
			state = "ON"
			color = Color3.fromRGB(0, 255, 180)
		else
			state = "OFF"
			color = Color3.fromRGB(235, 130, 120)
		end
		entry.button.Text = string.format("%s  :  %s", entry.row.label, state)
		entry.button.TextColor3 = color
	end
end

for _, entry in ipairs(toggleButtons) do
	entry.button.Activated:Connect(function()
		settings[entry.row.key] = not (settings[entry.row.key] == true)
		refreshToggles()
	end)
end
refreshToggles()

local statusLabel = addLabel("Ready.")

local applyButton = Instance.new("TextButton")
applyButton.Size = UDim2.new(1, -16, 0, 26)
applyButton.BackgroundColor3 = Color3.fromRGB(0, 120, 100)
applyButton.Font = Enum.Font.Code
applyButton.TextSize = 13
applyButton.TextColor3 = Color3.fromRGB(255, 255, 255)
applyButton.Text = "APPLY"
applyButton.LayoutOrder = layoutOrder
layoutOrder += 1
applyButton.Parent = panel

applyButton.Activated:Connect(function()
	local applied, rejected = 0, 0
	for _, entry in ipairs(numberBoxes) do
		local value, accepted = MathUtil.parseNumber(
			entry.box.Text, entry.row.lo, entry.row.hi, settings[entry.row.key]
		)
		if accepted then
			settings[entry.row.key] = value
			entry.box.Text = tostring(value)
			applied += 1
		else
			entry.box.Text = tostring(settings[entry.row.key])
			rejected += 1
		end
	end
	statusLabel.Text = string.format("Applied %d, rejected %d. Values are LOCAL.", applied, rejected)
end)

local hotkey = Enum.KeyCode.RightShift
local resolvedOk, resolved = pcall(function()
	return Enum.KeyCode[settings.menuHotkey]
end)
if resolvedOk and typeof(resolved) == "EnumItem" then
	hotkey = resolved
end

-- ------------------------------------------------------------ aim + fire ---
local windowFocused = true
local currentTargetId: string? = nil

--[[ Damage is your server's job. If your experience already exposes a
     RemoteEvent named "WeaponFire" in ReplicatedStorage, LMB proposes a shot.
     Your server Script must independently validate targetId, origin, direction,
     distance, FOV, line of sight, rate limit and alive state before damage.
     Without that Script this fires nothing and applies no damage. ]]
local function fire()
	if currentTargetId == nil then return end
	local remote = ReplicatedStorage:FindFirstChild("WeaponFire")
	if remote == nil or not remote:IsA("RemoteEvent") then return end
	local cam = workspace.CurrentCamera
	if cam == nil then return end
	remote:FireServer({
		origin = v3(cam.CFrame.Position),
		direction = v3(cam.CFrame.LookVector),
		targetId = currentTargetId,
	})
end

UserInputService.InputBegan:Connect(function(input: InputObject, processed: boolean)
	if processed then return end
	if input.UserInputType == Enum.UserInputType.MouseButton1 then
		fire()
	elseif input.UserInputType == Enum.UserInputType.Keyboard
		and UserInputService:GetFocusedTextBox() == nil
		and input.KeyCode == hotkey then
		menuGui.Enabled = not menuGui.Enabled
	end
end)

UserInputService.WindowFocusReleased:Connect(function()
	windowFocused = false -- drop assist state; no synthetic input to release
	currentTargetId = nil
end)
UserInputService.WindowFocused:Connect(function()
	windowFocused = true
end)
player.CharacterRemoving:Connect(function()
	currentTargetId = nil
end)

local function pickTarget(camPos: Vec3, forward: Vec3): BasePart?
	local best: BasePart? = nil
	local bestAngle = math.huge
	for _, inst in ipairs(CollectionService:GetTagged(settings.targetTag)) do
		if inst:IsA("BasePart") and inst:IsDescendantOf(workspace) then
			local part: BasePart = inst
			local cone = MathUtil.coneCheck(
				camPos, forward, v3(part.Position), settings.fovDeg, settings.maxDistance
			)
			if cone.ok and cone.angleDeg < bestAngle then
				if not settings.wallCheck or not isOccluded(fromVec(camPos), part.Position) then
					bestAngle = cone.angleDeg
					best = part
				end
			end
		end
	end
	return best
end

RunService.RenderStepped:Connect(function(dt: number)
	local cam = workspace.CurrentCamera
	if cam == nil then return end
	updateEsp(cam)

	if not settings.aimAssistEnabled or menuGui.Enabled or not windowFocused then
		currentTargetId = nil
		return
	end
	-- Rechecked every frame rather than latched.
	if not UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton2) then
		currentTargetId = nil
		return
	end

	local camPos = v3(cam.CFrame.Position)
	local forward = v3(cam.CFrame.LookVector)
	local target = pickTarget(camPos, forward)
	if target == nil then
		currentTargetId = nil
		return
	end

	local id = target:GetAttribute("TargetId")
	if type(id) == "string" then
		currentTargetId = id
	else
		currentTargetId = target.Name
	end

	local desired = MathUtil.normalize(MathUtil.sub(v3(target.Position), camPos))
	if desired == nil then return end
	local newForward = MathUtil.steerTowards(
		forward, desired, settings.smoothing, settings.maxTurnDegPerSec, dt
	)
	cam.CFrame = CFrame.lookAt(
		cam.CFrame.Position,
		cam.CFrame.Position + fromVec(newForward),
		Vector3.new(0, 1, 0)
	)
end)

print("[AimAssist] ready (own experience only): RMB aim, LMB fire, RightShift menu")
