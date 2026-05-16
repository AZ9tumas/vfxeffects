--[[
	TrackController (stripped for isolated VFX test bed)
	Drives client-side movement, FOV, neon track, fire/smoke, lighting effects,
	wormhole camera, distance counter, cancel button, and Overdrive on click.
	Builds its own minimal UI; no external UI controllers required.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local ContextActionService = game:GetService("ContextActionService")
local TweenService = game:GetService("TweenService")
local Lighting = game:GetService("Lighting")
local RunService = game:GetService("RunService")
local PhysicsService = game:GetService("PhysicsService")

local Knit = require(ReplicatedStorage:WaitForChild("Packages"):WaitForChild("Knit"))
local Stats = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("Stats"))
local TrackRunVFXConfig = require(ReplicatedStorage.Modules.TrackRunVFXConfig)
local WormHoleVFX = require(ReplicatedStorage.Modules.WormHoleVFX)
local TrailCameraVFX = require(ReplicatedStorage.Modules.TrailCameraVFX)
local CharacterTransparency = require(ReplicatedStorage.Modules.CharacterTransparency)
local BlackScreenTransition = require(ReplicatedStorage.Modules.BlackScreenTransition)
local BodyMoversTemplate = ReplicatedStorage:WaitForChild("Assets"):WaitForChild("BodyMovers")
local TrailTemplate = ReplicatedStorage:WaitForChild("Assets"):WaitForChild("VFX"):WaitForChild("Trail")

-- Collision groups so TrackChar and the (hidden) original char pass through
-- each other. Registered once at module load; safe to call again if already
-- registered (errors are swallowed by pcall).
do
	pcall(function() PhysicsService:RegisterCollisionGroup("TrackChar") end)
	pcall(function() PhysicsService:RegisterCollisionGroup("OriginalChar") end)
	pcall(function() PhysicsService:CollisionGroupSetCollidable("TrackChar", "OriginalChar", false) end)
end

local player = Players.LocalPlayer
local PlayerGui = player:WaitForChild("PlayerGui")

-- =========================================================================
-- Camera / lighting tunables
-- =========================================================================
local DEFAULT_FOV = 70
local TRACK_FOV = 90
local OVERDRIVE_FOV = 110
local FOV_TWEEN_TIME = 0.5
local TRACK_END_LOADING_DELAY = 0.8
local LIGHTING_TWEEN_TIME = 0.5
local RENDER_STEP_BINDING = "TrackController_Movement"
local TIME_EPSILON = 0.001

local TrackController = Knit.CreateController({ Name = "TrackController" })

-- =========================================================================
-- State
-- =========================================================================
local IsOnTrack = false
local TrackData: any = nil
local CurrentWorldName = "JurassicPeriod"
local OriginalWalkSpeed = 16
local OriginalJumpPower = 50
local TrackLightingEffects: any = {}
local TrackFireEffects: any = {}

local CurrentAngle = 0
local ElapsedTime = 0
local DistanceTraveled = 0
local LapCount = 0

-- TrackChar (client-side clone) state
local TrackChar: Model? = nil
local TrackCharHRP: BasePart? = nil
local TrackCharHum: Humanoid? = nil
local TrackCharYOffset: number = 0

local ClientTrackY: number = 0
local TrailApplied = false
local WormholeActivationStarted = false  -- guards against re-entry during the async hand-off

-- UI references (built in KnitInit)
local liveScreenGui: ScreenGui
local distanceCounter: TextLabel
local cancelButton: TextButton

local function Log(_msg: string)
	--print("[TrackController]: " .. _msg)
end

-- =========================================================================
-- UI construction
-- =========================================================================
local function BuildUI()
	liveScreenGui = Instance.new("ScreenGui")
	liveScreenGui.Name = "TrackRunHUD"
	liveScreenGui.ResetOnSpawn = false
	liveScreenGui.IgnoreGuiInset = true
	liveScreenGui.DisplayOrder = 50
	liveScreenGui.Parent = PlayerGui

	distanceCounter = Instance.new("TextLabel")
	distanceCounter.Name = "DistanceCounter"
	distanceCounter.Size = UDim2.new(0, 420, 0, 48)
	distanceCounter.Position = UDim2.new(0.5, -210, 0, 24)
	distanceCounter.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
	distanceCounter.BackgroundTransparency = 0.4
	distanceCounter.BorderSizePixel = 0
	distanceCounter.Font = Enum.Font.GothamBold
	distanceCounter.TextSize = 22
	distanceCounter.TextColor3 = Color3.fromRGB(255, 255, 255)
	distanceCounter.Text = ""
	distanceCounter.Visible = false
	distanceCounter.Parent = liveScreenGui

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 8)
	corner.Parent = distanceCounter

	cancelButton = Instance.new("TextButton")
	cancelButton.Name = "Cancel"
	cancelButton.Size = UDim2.new(0, 160, 0, 44)
	cancelButton.AnchorPoint = Vector2.new(0.5, 1)
	cancelButton.Position = UDim2.new(0.5, 0, 1, -24)
	cancelButton.BackgroundColor3 = Color3.fromRGB(200, 40, 40)
	cancelButton.BorderSizePixel = 0
	cancelButton.AutoButtonColor = true
	cancelButton.Font = Enum.Font.GothamBold
	cancelButton.TextSize = 20
	cancelButton.TextColor3 = Color3.fromRGB(255, 255, 255)
	cancelButton.Text = "CANCEL"
	cancelButton.Visible = false
	cancelButton.Parent = liveScreenGui

	local cancelCorner = Instance.new("UICorner")
	cancelCorner.CornerRadius = UDim.new(0, 8)
	cancelCorner.Parent = cancelButton
end

local function FormatNumber(n: number): string
	if n >= 1_000_000_000 then return string.format("%.2fB", n / 1_000_000_000) end
	if n >= 1_000_000 then return string.format("%.2fM", n / 1_000_000) end
	if n >= 1_000 then return string.format("%.2fK", n / 1_000) end
	return string.format("%.0f", n)
end

local function UpdateDistanceDisplay(distance: number, totalDistance: number)
	if distanceCounter then
		local percentage = math.clamp((distance / math.max(totalDistance, 1)) * 100, 0, 100)
		distanceCounter.Text = string.format("%s / %s  (%.1f%%)", FormatNumber(distance), FormatNumber(totalDistance), percentage)
	end
end

-- =========================================================================
-- World helpers
-- =========================================================================
local function GetWorldFolder(worldName: string): Folder?
	local f = workspace:FindFirstChild(worldName) or workspace:FindFirstChild("JurassicPeriod")
	return f :: any
end

local function GetVisualTrackForWorld(worldName: string): Instance?
	local worldFolder = GetWorldFolder(worldName)
	if not worldFolder then return nil end
	local trackSystem = worldFolder:FindFirstChild("Track_System")
	if not trackSystem then return nil end
	return trackSystem:FindFirstChild("Visual_Track")
end

-- Collect all BaseParts under a Visual_Track Model (or return itself if a BasePart)
local function GetVisualTrackParts(worldName: string): { BasePart }
	local visual = GetVisualTrackForWorld(worldName)
	if not visual then return {} end
	if visual:IsA("BasePart") then return { visual } end
	local parts: { BasePart } = {}
	for _, d in visual:GetDescendants() do
		if d:IsA("BasePart") then table.insert(parts, d) end
	end
	return parts
end

local function UpdateCircularPosition(center: Vector3, radius: number, angle: number, trackY: number): (CFrame, Vector3)
	local x = center.X + radius * math.cos(angle)
	local z = center.Z + radius * math.sin(angle)
	local targetPosition = Vector3.new(x, trackY, z)
	local lookAtPos = targetPosition + Vector3.new(-math.sin(angle), 0, math.cos(angle))
	local finalCFrame = CFrame.lookAt(targetPosition, lookAtPos)
	return finalCFrame, targetPosition
end

-- =========================================================================
-- TrackChar (client-only character clone driven by body movers)
-- =========================================================================
local function ApplyTrailToTrackChar()
	if not TrackCharHRP then return end
	if TrackCharHRP:FindFirstChild("TrackTrailA0") then return end
	local trailPart = TrailTemplate:Clone()
	local a0 = trailPart:FindFirstChild("0") :: Attachment
	local a1 = trailPart:FindFirstChild("1") :: Attachment
	if not a0 or not a1 then
		trailPart:Destroy()
		return
	end
	a0.Name = "TrackTrailA0"
	a1.Name = "TrackTrailA1"
	a0.Parent = TrackCharHRP
	a1.Parent = TrackCharHRP
	for _, child in trailPart:GetChildren() do
		if child:IsA("Trail") then
			child.Attachment0 = a0
			child.Attachment1 = a1
			child.Parent = TrackCharHRP
		end
	end
	trailPart:Destroy()
end

local function UpdateTrackCharTrailLifetime(elapsedTime: number)
	if not TrackCharHRP then return end
	local lifetime = math.clamp(
		TrackRunVFXConfig.TrailBaseLifetime + TrackRunVFXConfig.TrailGrowthRate * elapsedTime,
		TrackRunVFXConfig.TrailBaseLifetime,
		TrackRunVFXConfig.TrailMaxLifetime
	)
	for _, child in TrackCharHRP:GetChildren() do
		if child:IsA("Trail") and child.Attachment0 and child.Attachment0.Name == "TrackTrailA0" then
			child.Lifetime = lifetime
		end
	end
end


local function BuildTrackChar(original_char: Model): (Model?, BasePart?, number)
	-- Roblox sets Character.Archivable = false on every spawned character.
	-- Clone() on a non-archivable instance returns nil, not an error — so
	-- we must temporarily enable it on the root and any non-archivable
	-- descendants (some accessories can also have Archivable = false).
	local nonArchivable: { Instance } = {}
	if not original_char.Archivable then
		original_char.Archivable = true
		table.insert(nonArchivable, original_char)
	end
	for _, d in original_char:GetDescendants() do
		if not d.Archivable then
			d.Archivable = true
			table.insert(nonArchivable, d)
		end
	end

	local clone: Model? = original_char:Clone()

	-- Restore Archivable immediately so the original character is unchanged.
	for _, inst in nonArchivable do
		if inst and inst.Parent then
			inst.Archivable = false
		end
	end

	if not clone then
		warn("[TrackChar] Clone() returned nil even after setting Archivable=true")
		return nil, nil, 0
	end

	clone.Name = player.Name .. "TrackChar"

	-- Strip embedded scripts so nothing fights us (BaseScript = Script | LocalScript).
	for _, d in clone:GetDescendants() do
		if d:IsA("BaseScript") then d:Destroy() end
	end

	local hum = clone:FindFirstChildOfClass("Humanoid")
	if hum then
		-- Destroy the Animator: stripping BaseScripts removes the Animate
		-- LocalScript but leaves the Animator instance alive inside the
		-- Humanoid. The engine can still drive idle/walk poses through it,
		-- fighting our PlatformStand + Physics state. Removing it prevents that.
		local animator = hum:FindFirstChildOfClass("Animator")
		if animator then animator:Destroy() end

		-- Hide the cloned humanoid's name tag and health bar.
		hum.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
		hum.HealthDisplayType = Enum.HumanoidHealthDisplayType.AlwaysOff

		for _, state in {
			Enum.HumanoidStateType.Climbing,
			Enum.HumanoidStateType.FallingDown,
			Enum.HumanoidStateType.Freefall,
			Enum.HumanoidStateType.GettingUp,
			Enum.HumanoidStateType.Jumping,
			Enum.HumanoidStateType.Landed,
			Enum.HumanoidStateType.Ragdoll,
			Enum.HumanoidStateType.Running,
			Enum.HumanoidStateType.RunningNoPhysics,
			Enum.HumanoidStateType.Seated,
			Enum.HumanoidStateType.StrafingNoPhysics,
			Enum.HumanoidStateType.Swimming,
		} do
			hum:SetStateEnabled(state, false)
		end
		hum:ChangeState(Enum.HumanoidStateType.Physics)
		hum.PlatformStand = true
		hum.AutoRotate = false
		hum.WalkSpeed = 0
		hum.JumpPower = 0
	end

	-- Non-colliding, massless parts — removes physics interference so
	-- body movers can drive arbitrarily high speeds without engine resistance.
	for _, d in clone:GetDescendants() do
		if d:IsA("BasePart") then
			d.CanCollide = false
			d.CanTouch = false
			d.Massless = true
		end
	end

	-- Assign TrackChar parts to the "TrackChar" collision group so the engine
	-- ignores collisions between it and the hidden original character.
	for _, d in clone:GetDescendants() do
		if d:IsA("BasePart") then
			PhysicsService:SetPartCollisionGroup(d, "TrackChar")
		end
	end

	clone.Parent = workspace

	local hrp = clone:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not hrp then
		clone:Destroy()
		return nil, nil, 0
	end

	-- Bounding-box-based Y offset: distance from HRP centre to the bottom of
	-- the rig (works for R6, R15, and custom rigs).
	local cf, size = clone:GetBoundingBox()
	local bottomY = cf.Y - size.Y / 2
	local hrpToBottom = hrp.Position.Y - bottomY

	return clone, hrp, hrpToBottom
end

local function AttachBodyMoversTo(hrp: BasePart)
	local attachment = Instance.new("Attachment")
	attachment.Name = "TrackAttachment"
	attachment.Parent = hrp

	local alignPos = BodyMoversTemplate.AlignPosition:Clone()
	alignPos.Attachment0 = attachment
	alignPos.Position = hrp.Position
	alignPos.Parent = hrp

	local alignOri = BodyMoversTemplate.AlignOrientation:Clone()
	alignOri.Attachment0 = attachment
	alignOri.CFrame = hrp.CFrame
	alignOri.Parent = hrp
end

local function SetupTrackCharRun(originalChar: Model, trackData: any)
	local originalHRP = originalChar:FindFirstChild("HumanoidRootPart") :: BasePart
	if not originalHRP or not originalHRP:IsA("BasePart") then return end

	local clone, cloneHRP, hrpToBottom = BuildTrackChar(originalChar)
	if not clone or not cloneHRP then return end

	TrackChar = clone
	TrackCharHRP = cloneHRP
	TrackCharYOffset = hrpToBottom

	-- Client-side trackY = gate ground Y + bounding-box HRP offset
	local gateY = trackData.gateY or (trackData.trackY - hrpToBottom)
	ClientTrackY = gateY + hrpToBottom

	-- Visual continuity: seed at original character's current CFrame
	cloneHRP.CFrame = (originalHRP :: BasePart).CFrame

	AttachBodyMoversTo(cloneHRP)

	-- Anchor original HRP so we can drive its CFrame locally each frame
	-- without physics fighting back; server-attached VFX (Trail/Aura) follow.
	originalHRP.Anchored = true

	-- Assign original character parts to the "OriginalChar" collision group so
	-- the engine ignores collisions between it and the TrackChar.
	for _, d in originalChar:GetDescendants() do
		if d:IsA("BasePart") then
			PhysicsService:SetPartCollisionGroup(d, "OriginalChar")
		end
	end

	-- Hide the original character on this client now that the TrackChar is fully
	-- set up and visible. CharacterTransparency saves originals for restoration.
	CharacterTransparency.EnableCharacterTransparency(originalChar, 1)

	TrackCharHum = clone:FindFirstChildOfClass("Humanoid")
	local camera = workspace.CurrentCamera
	if camera then
		-- Scriptable gives us full CFrame control; the default camera module is bypassed.
		camera.CameraType = Enum.CameraType.Scriptable
	end
end

local function TeardownTrackCharRun()
	local originalChar = player.Character
	if originalChar then
		CharacterTransparency.RestoreCharacterTransparency(originalChar)
	end

	local originalHRP = originalChar and originalChar:FindFirstChild("HumanoidRootPart")
	if originalHRP and originalHRP:IsA("BasePart") then
		originalHRP.Anchored = false
	end

	-- Restore original character parts back to the Default collision group.
	if originalChar then
		for _, d in originalChar:GetDescendants() do
			if d:IsA("BasePart") then
				PhysicsService:SetPartCollisionGroup(d, "Default")
			end
		end
	end

	if TrackChar then
		TrackChar:Destroy()
	end
	TrackChar = nil
	TrackCharHRP = nil
	TrackCharHum = nil
	TrackCharYOffset = 0
	ClientTrackY = 0
	TrailApplied = false
	WormholeActivationStarted = false
end

-- =========================================================================
-- Fire / smoke on track based on progress (no unlockRequirement here, so we
-- drive intensity from currentDistance / totalDistance instead)
-- =========================================================================
local function UpdateFireEffectOnTrack(worldName: string, progressPercent: number)
	local parts = GetVisualTrackParts(worldName)
	if #parts == 0 then return end

	if progressPercent < 0.5 then
		local effects = TrackFireEffects[worldName]
		if effects then
			for _, e in effects do
				if e.Fire then e.Fire:Destroy() end
				if e.Smoke then e.Smoke:Destroy() end
			end
			TrackFireEffects[worldName] = nil
		end
		return
	end

	local intensityFactor = math.clamp((progressPercent - 0.5) / 0.5, 0, 1)
	local effects = TrackFireEffects[worldName]
	if not effects then
		effects = {}
		for _, p in parts do
			local fire = Instance.new("Fire")
			fire.Name = "TrackFire"
			fire.Heat = 5 + intensityFactor * 10
			fire.Size = 5 + intensityFactor * 10
			fire.Parent = p

			local smoke = Instance.new("Smoke")
			smoke.Name = "TrackSmoke"
			smoke.Size = 2 + intensityFactor * 5
			smoke.Opacity = 0.3 + intensityFactor * 0.4
			smoke.RiseVelocity = 5 + intensityFactor * 10
			smoke.Parent = p

			table.insert(effects, { Fire = fire, Smoke = smoke })
		end
		TrackFireEffects[worldName] = effects
	end

	for _, e in effects do
		if e.Fire then
			e.Fire.Heat = 5 + intensityFactor * 10
			e.Fire.Size = 5 + intensityFactor * 10
			if progressPercent >= 0.9 then
				e.Fire.Color = Color3.fromRGB(128, 0, 255)
				e.Fire.SecondaryColor = Color3.fromRGB(75, 0, 130)
			else
				e.Fire.Color = Color3.fromRGB(255, 165, 0)
				e.Fire.SecondaryColor = Color3.fromRGB(255, 69, 0)
			end
		end
		if e.Smoke then
			e.Smoke.Size = 2 + intensityFactor * 5
			e.Smoke.Opacity = 0.3 + intensityFactor * 0.4
			e.Smoke.RiseVelocity = 5 + intensityFactor * 10
			if progressPercent >= 0.9 then
				e.Smoke.Color = Color3.fromRGB(75, 0, 130)
			else
				e.Smoke.Color = Color3.fromRGB(50, 50, 50)
			end
		end
	end
end

local function RemoveFireEffectFromTrack(worldName: string)
	local effects = TrackFireEffects[worldName]
	if not effects then return end
	for _, e in effects do
		if e.Fire then e.Fire:Destroy() end
		if e.Smoke then e.Smoke:Destroy() end
	end
	TrackFireEffects[worldName] = nil
end

-- =========================================================================
-- Lighting (blur / color / bloom)
-- =========================================================================
local function ApplyTrackLightingEffects()
	local blur = Instance.new("BlurEffect")
	blur.Name = "TrackBlur"
	blur.Size = 0
	blur.Parent = Lighting
	TrackLightingEffects.blur = blur
	TweenService:Create(blur, TweenInfo.new(LIGHTING_TWEEN_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Size = 6 }):Play()

	local cc = Instance.new("ColorCorrectionEffect")
	cc.Name = "TrackColorCorrection"
	cc.Saturation = 0
	cc.Contrast = 0
	cc.Brightness = 0
	cc.Parent = Lighting
	TrackLightingEffects.colorCorrection = cc
	TweenService:Create(cc, TweenInfo.new(LIGHTING_TWEEN_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Saturation = 0.15, Contrast = 0.1, Brightness = 0.03,
	}):Play()

	local bloom = Instance.new("BloomEffect")
	bloom.Name = "TrackBloom"
	bloom.Intensity = 0
	bloom.Size = 24
	bloom.Threshold = 1
	bloom.Parent = Lighting
	TrackLightingEffects.bloom = bloom
	TweenService:Create(bloom, TweenInfo.new(LIGHTING_TWEEN_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Intensity = 0.8, Threshold = 0.9,
	}):Play()
end

local function RemoveTrackLightingEffects()
	if TrackLightingEffects.blur then
		local blur = TrackLightingEffects.blur
		local t = TweenService:Create(blur, TweenInfo.new(LIGHTING_TWEEN_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.In), { Size = 0 })
		t:Play()
		t.Completed:Connect(function() blur:Destroy() end)
	end
	if TrackLightingEffects.colorCorrection then
		local cc = TrackLightingEffects.colorCorrection
		local t = TweenService:Create(cc, TweenInfo.new(LIGHTING_TWEEN_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
			Saturation = 0, Contrast = 0, Brightness = 0,
		})
		t:Play()
		t.Completed:Connect(function() cc:Destroy() end)
	end
	if TrackLightingEffects.bloom then
		local bloom = TrackLightingEffects.bloom
		local t = TweenService:Create(bloom, TweenInfo.new(LIGHTING_TWEEN_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.In), { Intensity = 0 })
		t:Play()
		t.Completed:Connect(function() bloom:Destroy() end)
	end
	TrackLightingEffects = {}
end

-- =========================================================================
-- Camera / controls
-- =========================================================================
local function TweenCameraFOV(targetFOV: number, duration: number)
	local camera = workspace.CurrentCamera
	if not camera then return end
	TweenService:Create(camera, TweenInfo.new(duration, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { FieldOfView = targetFOV }):Play()
end

local function ResetCamera()
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")

	local existing = workspace:FindFirstChildWhichIsA("Camera")
	if existing then existing:Destroy() end

	local newCamera = Instance.new("Camera")
	newCamera.FieldOfView = DEFAULT_FOV
	newCamera.CameraType = Enum.CameraType.Custom
	if humanoid then newCamera.CameraSubject = humanoid end
	newCamera.Parent = workspace
	workspace.CurrentCamera = newCamera

	task.delay(0.5, function()
		if workspace.CurrentCamera == newCamera and humanoid then
			workspace.CurrentCamera.CameraType = Enum.CameraType.Custom
			workspace.CurrentCamera.CameraSubject = humanoid
		end
	end)
end

local function DisablePlayerControls()
	local character = player.Character
	if not character then return end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		OriginalWalkSpeed = Stats.NormalWalkSpeed
		OriginalJumpPower = humanoid.JumpPower
		humanoid.WalkSpeed = 0
		humanoid.JumpPower = 0
		humanoid.AutoRotate = false
	end

	pcall(function()
		ContextActionService:UnbindAction("TrackController_DisableMovement")
	end)

	pcall(function()
		ContextActionService:BindAction("TrackController_DisableMovement", function()
			return Enum.ContextActionResult.Sink
		end, false,
			Enum.PlayerActions.CharacterForward,
			Enum.PlayerActions.CharacterBackward,
			Enum.PlayerActions.CharacterLeft,
			Enum.PlayerActions.CharacterRight,
			Enum.PlayerActions.CharacterJump
		)
	end)
end

local function EnablePlayerControls()
	local character = player.Character
	if not character then return end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid.WalkSpeed = OriginalWalkSpeed
		humanoid.JumpPower = OriginalJumpPower
		humanoid.AutoRotate = true
	end
	ContextActionService:UnbindAction("TrackController_DisableMovement")
end

-- =========================================================================
-- Track started / ended handlers
-- =========================================================================
local function OnTrackStarted(trackData: any)
	IsOnTrack = true
	TrackData = trackData
	CurrentWorldName = trackData.worldName or "JurassicPeriod"
	distanceCounter.Visible = true

	CurrentAngle = trackData.startAngle
	ElapsedTime = 0
	DistanceTraveled = 0
	LapCount = 0

	Log(string.format("Track started at %s, total distance: %.2f", tostring(trackData.gateName), trackData.totalDistance))

	BlackScreenTransition.Play(0.5)

	-- TrackChar setup (clone, body movers, hide original, camera shift)
	local originalChar = player.Character
	if originalChar then
		SetupTrackCharRun(originalChar, trackData)
	end

	--TweenCameraFOV(TRACK_FOV, FOV_TWEEN_TIME)
	--ApplyTrackLightingEffects()
	UpdateDistanceDisplay(0, trackData.totalDistance)
	DisablePlayerControls()
	cancelButton.Visible = true

	task.delay(2.5, function()
		print("Tweening")
		TweenCameraFOV(TRACK_FOV, FOV_TWEEN_TIME)
	end)

	-- Run at Camera+1 so we execute AFTER the default camera module (priority 200)
	-- and can re-assert CameraSubject before the frame is rendered.
	RunService:BindToRenderStep(RENDER_STEP_BINDING, Enum.RenderPriority.Camera.Value + 1, function(dt)
		if not IsOnTrack or not TrackData then
			RunService:UnbindFromRenderStep(RENDER_STEP_BINDING)
			return
		end

		if not TrackCharHRP or not TrackCharHRP.Parent then return end

		local cam = workspace.CurrentCamera
		local originalChar = player.Character
		local originalHRP = originalChar and originalChar:FindFirstChild("HumanoidRootPart")

		local radius = TrackData.worldRadius
		local center = TrackData.trackCenter
		local trackY = ClientTrackY
		local maxPhysicalSpeed = TrackData.maxPhysicalSpeed or Stats.MaxPhysicalSpeed
		if not center or not radius or not trackY then return end

		ElapsedTime = ElapsedTime + dt

		local calculatedSpeed = Stats.CalculateCurrentSpeed(
			TrackData.initialSpeed,
			TrackData.acceleration,
			TrackData.maxSpeed,
			ElapsedTime,
			TrackData.rampDuration,
			TrackData.postRampAcceleration
		)
		local physicalSpeed = math.min(calculatedSpeed, maxPhysicalSpeed)

		-- Wormhole activation
		local playerMaxDist = TrackData.playerMaxDistance or 0
		local aboveWormhole = TrackRunVFXConfig.IsThresholdMet(TrackRunVFXConfig.Wormhole, DistanceTraveled, playerMaxDist)

		if aboveWormhole and not WormHoleVFX.IsActive() and not WormholeActivationStarted then
			WormholeActivationStarted = true
			-- Hand-off sequence: if the trail-camera cinematic is currently
			-- running, run its "return" phase (interpolate camera back to
			-- the in-run third-person offset) BEFORE the wormhole takes
			-- over. This produces a smooth lead-in instead of a hard cut
			-- from the overhead view straight to the wormhole pose.
			task.spawn(function()
				if TrailCameraVFX.IsActive() then
					TrailCameraVFX.RunReturnPhase() -- yields until done
					TrailCameraVFX.Deactivate()
				end
				local tweenInfo = TweenInfo.new(TrackRunVFXConfig.WormholeZoomTweenDuration, Enum.EasingStyle.Sine, Enum.EasingDirection.Out)
				local zoomTarget = TrackRunVFXConfig.WormholeFirstPersonZoom
				local tween = TweenService:Create(player, tweenInfo, {
					CameraMinZoomDistance = zoomTarget,
					CameraMaxZoomDistance = zoomTarget,
				})
				tween:Play()
				tween.Completed:Wait()
				WormHoleVFX.Activate()
			end)
		end

		local wormholeDistThreshold = math.max(
			TrackRunVFXConfig.Wormhole.AbsoluteDistance,
			playerMaxDist * TrackRunVFXConfig.Wormhole.PercentageOfTotal
		)
		local wormholeSpeedRatio = math.clamp(
			(DistanceTraveled - wormholeDistThreshold) / math.max(1, TrackData.totalDistance - wormholeDistThreshold),
			0, 1
		)
		if WormHoleVFX.IsActive() then
			WormHoleVFX.UpdateParticleEffects(wormholeSpeedRatio)
		end

		local angularVelocity = Stats.LinearSpeedToAngularVelocity(physicalSpeed, radius)
		CurrentAngle = CurrentAngle + angularVelocity * dt

		local distanceThisFrame = calculatedSpeed * dt
		DistanceTraveled = DistanceTraveled + distanceThisFrame

		UpdateDistanceDisplay(DistanceTraveled, TrackData.totalDistance)

		-- Trail VFX: applied client-side since TrackChar is a client-only clone.
		if TrackRunVFXConfig.IsThresholdMet(TrackRunVFXConfig.Trail, DistanceTraveled, playerMaxDist) then
			if not TrailApplied then
				ApplyTrailToTrackChar()
				TrailApplied = true
				-- Kick off the four-phase cinematic camera the moment the
				-- trail goes live. TrailCameraVFX seeds itself with the
				-- current camera's CFrame so the hand-off is seamless.
				if not TrailCameraVFX.IsActive() and not WormHoleVFX.IsActive() then
					TrailCameraVFX.Activate(TrackCharHRP, center)
				end
			end
			UpdateTrackCharTrailLifetime(ElapsedTime)
		end

		-- Lap detection (for wormhole particle boost)
		local lapThreshold = TrackData.startAngle + (2 * math.pi * (LapCount + 1))
		if CurrentAngle >= lapThreshold then
			LapCount = LapCount + 1
			if WormHoleVFX.IsActive() then
				WormHoleVFX.TriggerLapBoost()
			end
		end

		-- Fire effect based on run progress
		local progressPercent = math.clamp(DistanceTraveled / math.max(TrackData.totalDistance, 1), 0, 1)
		--UpdateFireEffectOnTrack(CurrentWorldName, progressPercent)

		-- End condition
		if ElapsedTime >= (TrackData.totalTime - TIME_EPSILON) or DistanceTraveled >= TrackData.totalDistance then
			RunService:UnbindFromRenderStep(RENDER_STEP_BINDING)
			local TrackService = Knit.GetService("TrackService")
			TrackService:RequestTrackEnd(DistanceTraveled, false)
			return
		end

		-- Drive TrackChar via body-mover constraints
		--[[
			local targetPosition = Vector3.new(x, trackY, z)
			local lookAtPos = targetPosition + Vector3.new(-math.sin(angle), 0, math.cos(angle))
			local finalCFrame = CFrame.lookAt(targetPosition, lookAtPos)
			return finalCFrame, targetPosition
		]]
		local targetCFrame, targetPosition = UpdateCircularPosition(center, radius, CurrentAngle, trackY)
		local alignPos = TrackCharHRP:FindFirstChild("AlignPosition")
		local alignOri = TrackCharHRP:FindFirstChild("AlignOrientation")
		if alignPos then (alignPos :: AlignPosition).Position = targetPosition end
		if alignOri then (alignOri :: AlignOrientation).CFrame = targetCFrame end

		-- Position camera behind and above TrackChar, facing the tangential direction.
		-- targetCFrame.LookVector IS the tangential direction (from UpdateCircularPosition).
		-- Skip when another VFX owns the camera (trail cinematic / wormhole)
		-- so we don't fight its CFrame writes for the same frame.
		if cam and not TrailCameraVFX.IsActive() and not WormHoleVFX.IsActive() then
			local cameraoffset = CFrame.new(0, TrackRunVFXConfig.TrackCameraHeight, TrackRunVFXConfig.TrackCameraBack)
			local baseCFrame = CFrame.new(TrackCharHRP.Position, TrackCharHRP.Position + targetCFrame.LookVector) * cameraoffset
			-- Apply the subtle continuous shake that runs throughout the track
			-- run. Multiplied in local space so the shake reads correctly
			-- regardless of camera orientation.
			cam.CFrame = baseCFrame * TrackRunVFXConfig.GetContinuousRunShakeCFrame(tick())
		end
	end)
end

local function OnTrackEnded(trackData: any)
	if not IsOnTrack then return end
	Log(string.format("Track ended, distance: %.2f", trackData.distanceTraveled or 0))

	IsOnTrack = false
	TrackData = nil

	pcall(function() RunService:UnbindFromRenderStep(RENDER_STEP_BINDING) end)

	CurrentAngle = 0
	ElapsedTime = 0
	DistanceTraveled = 0
	LapCount = 0

	task.spawn(function() WormHoleVFX.Deactivate() end)
	TrailCameraVFX.Deactivate()
	TeardownTrackCharRun()
	ResetCamera()

	player.CameraMinZoomDistance = 0.5
	player.CameraMaxZoomDistance = 128

	RemoveFireEffectFromTrack(CurrentWorldName)
	RemoveTrackLightingEffects()
	EnablePlayerControls()

	cancelButton.Visible = false

	BlackScreenTransition.Play(TRACK_END_LOADING_DELAY)
	task.delay(TRACK_END_LOADING_DELAY + 0.3, function()
		distanceCounter.Visible = false
	end)
end

function TrackController:IsOnTrack(): boolean
	return IsOnTrack
end

function TrackController:GetTrackData()
	return TrackData
end

function TrackController:KnitInit()
	BuildUI()
end

function TrackController:KnitStart()
	local TrackService = Knit.GetService("TrackService")

	TrackService.TrackStarted:Connect(OnTrackStarted)
	TrackService.TrackEnded:Connect(OnTrackEnded)

	cancelButton.MouseButton1Click:Connect(function()
		if not IsOnTrack then return end
		TrackService:CancelTrackRun():andThen(function() end)
	end)

	-- Overdrive on left click within OverdriveTimeframe
	TrackService.Overdrive:Connect(function(overdriveData)
		if not IsOnTrack or not TrackData then return end
		TrackData.initialSpeed = overdriveData.initialSpeed
		TrackData.maxSpeed = overdriveData.maxSpeed
		TrackData.acceleration = overdriveData.acceleration

		TweenCameraFOV(OVERDRIVE_FOV, 0.3)

		task.delay(overdriveData.duration, function()
			if IsOnTrack and TrackData then
				local m = overdriveData.multiplier
				TrackData.initialSpeed = TrackData.initialSpeed / m
				TrackData.maxSpeed = TrackData.maxSpeed / m
				TrackData.acceleration = TrackData.acceleration / m
				TweenCameraFOV(TRACK_FOV, 0.5)
			end
		end)
	end)

	UserInputService.InputBegan:Connect(function(input, gameProcessed)
		if gameProcessed then return end
		if input.UserInputType ~= Enum.UserInputType.MouseButton1 then return end
		if not IsOnTrack or not TrackData then return end
		if ElapsedTime > Stats.OverdriveTimeframe then return end
		TrackService:RequestOverdrive():andThen(function() end)
	end)
end

return TrackController
