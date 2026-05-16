--!strict
--[[
	WormHoleVFX (client) — wormhole camera transition & particle scaling.
	Requires workspace.WormHoleArea with children WormHole + CameraPart.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Lighting = game:GetService("Lighting")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local TrackRunVFXConfig = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("TrackRunVFXConfig"))

local WormHoleVFX = {}

local FADE_DURATION = 0.25

local FREQ_RATIO_X = 1.0
local FREQ_RATIO_Y = 1.24
local FREQ_RATIO_ROT = 0.68

local isActive: boolean = false
local shakeConnection: RBXScriptConnection? = nil
local baseCFrame: CFrame? = nil
local savedBrightness: number? = nil
local savedAmbient: Color3? = nil
local savedOutdoorAmbient: Color3? = nil
local savedClockTime: number? = nil
local fadeGui: ScreenGui? = nil
local fadeFrame: Frame? = nil
local baseParticleValues: { [ParticleEmitter]: { Rate: number, SpeedMin: number, SpeedMax: number } } = {}
local lapBoostActive: boolean = false
local lapBoostThread: thread? = nil

local function GetWormHoleArea()
	return workspace:FindFirstChild("WormHoleArea")
end

local function GetFadeGui(): (ScreenGui, Frame)
	if fadeGui and fadeFrame then
		return fadeGui, fadeFrame
	end
	local player = Players.LocalPlayer
	if not player then error("[WormHoleVFX] No LocalPlayer") end

	local gui = Instance.new("ScreenGui")
	gui.Name = "WormHoleFadeGui"
	gui.DisplayOrder = 100
	gui.IgnoreGuiInset = true
	gui.ResetOnSpawn = false
	gui.Parent = player:WaitForChild("PlayerGui")

	local frame = Instance.new("Frame")
	frame.Name = "Black"
	frame.Size = UDim2.fromScale(1, 1)
	frame.BackgroundColor3 = Color3.new(0, 0, 0)
	frame.BackgroundTransparency = 1
	frame.BorderSizePixel = 0
	frame.Parent = gui

	fadeGui = gui
	fadeFrame = frame
	return gui, frame
end

local function FadeBlack(targetTransparency: number)
	local _, frame = GetFadeGui()
	local tween = TweenService:Create(frame, TweenInfo.new(FADE_DURATION, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut), { BackgroundTransparency = targetTransparency })
	tween:Play()
	tween.Completed:Wait()
end

local function createWormHoleCamera()
	local area = GetWormHoleArea()
	if not area then
		warn("[WormHoleVFX] Cannot create WormHoleCamera, WormHoleArea not found")
		return nil
	end
	local cameraPart = area:FindFirstChild("CameraPart")
	local wormHolePart = area:FindFirstChild("WormHole")
	if not (cameraPart and wormHolePart) then return nil end

	local camera = Instance.new("Camera")
	camera.CameraType = Enum.CameraType.Scriptable
	camera.Name = "WormHoleCamera"
	camera.CFrame = CFrame.new(cameraPart.Position, wormHolePart.Position)
	camera.Parent = workspace
	return camera
end

local function destroyWormHoleCamera()
	local camera = workspace:FindFirstChild("WormHoleCamera")
	if camera and camera:IsA("Camera") then
		camera:Destroy()
	end
end

local function ShakeNormalCamera(duration: number)
	local camera = workspace.CurrentCamera
	if not camera then return end

	local magnitude = TrackRunVFXConfig.WormholePreShakeMagnitude
	local rotMag = math.rad(TrackRunVFXConfig.WormholePreShakeRotation)
	local elapsed = 0

	local freqX = 7.1 * math.pi * 2
	local freqY = 5.3 * math.pi * 2
	local freqRot = 3.7 * math.pi * 2

	local originalCFrame = camera.CFrame
	local conn: RBXScriptConnection? = nil

	conn = RunService.RenderStepped:Connect(function(dt)
		elapsed = elapsed + dt
		if elapsed >= duration then
			camera.CFrame = originalCFrame
			if conn then conn:Disconnect(); conn = nil end
			return
		end
		local intensity = 1.0 - 0.3 * (elapsed / duration)
		local ox = math.sin(elapsed * freqX) * magnitude * intensity
		local oy = math.sin(elapsed * freqY) * magnitude * intensity
		local oRot = math.sin(elapsed * freqRot) * rotMag * intensity
		camera.CFrame = camera.CFrame * CFrame.new(ox, oy, 0) * CFrame.Angles(oRot, oRot * 0.5, 0)
	end)

	task.wait(duration)
	if conn then conn:Disconnect() end
end

local function CacheBaseParticleValues()
	local area = GetWormHoleArea()
	if not area then return end
	local wormHolePart = area:FindFirstChild("WormHole")
	if not wormHolePart then return end
	for _, desc in wormHolePart:GetDescendants() do
		if desc:IsA("ParticleEmitter") and not baseParticleValues[desc] then
			baseParticleValues[desc] = {
				Rate = desc.Rate,
				SpeedMin = desc.Speed.Min,
				SpeedMax = desc.Speed.Max,
			}
		end
	end
end

function WormHoleVFX.Activate()
	if isActive then return end
	isActive = true

	local area = GetWormHoleArea()
	if not area then
		warn("[WormHoleVFX] workspace.WormHoleArea not found")
		isActive = false
		return
	end

	local wormHoleCamera = area:FindFirstChild("WormHoleCamera")
	if not wormHoleCamera or not wormHoleCamera:IsA("Camera") then
		wormHoleCamera = createWormHoleCamera()
		if not wormHoleCamera then
			isActive = false
			return
		end
	end

	-- Pre-wormhole intense shake removed: the trail-camera "Return" phase
	-- now runs immediately before this, so the camera arrives back at the
	-- runner already in continuous-shake territory. Adding another shake on
	-- top felt redundant and jerky next to the smooth interpolation.
	FadeBlack(0)
	-- Kill all ambient/sky lighting while the screen is black so that when
	-- it fades back in only the wormhole particles are visible.
	WormHoleVFX.DarkenLighting()

	local cameraPart = area:FindFirstChild("CameraPart")
	local wormHolePart = area:FindFirstChild("WormHole")
	if cameraPart and wormHolePart then
		baseCFrame = CFrame.new(cameraPart.Position, wormHolePart.Position)
	end
	workspace.CurrentCamera = wormHoleCamera
	if baseCFrame then
		workspace.CurrentCamera.CFrame = baseCFrame
	end

	FadeBlack(1)

	local lightMag = TrackRunVFXConfig.WormholeLightShakeMagnitude
	local lightRotMag = math.rad(TrackRunVFXConfig.WormholeLightShakeRotation)
	local baseFreq = TrackRunVFXConfig.WormholeLightShakeFrequency * math.pi * 2

	shakeConnection = RunService.RenderStepped:Connect(function(_dt)
		local base = baseCFrame
		if not base then return end
		local t = tick()
		local ox = math.sin(t * baseFreq * FREQ_RATIO_X) * lightMag
		local oy = math.sin(t * baseFreq * FREQ_RATIO_Y) * lightMag
		local oRot = math.sin(t * baseFreq * FREQ_RATIO_ROT) * lightRotMag
		wormHoleCamera.CFrame = base * CFrame.new(ox, oy, 0) * CFrame.Angles(oRot, oRot * 0.5, 0)
	end)

	CacheBaseParticleValues()
end

function WormHoleVFX.Deactivate()
	if not isActive then return end
	isActive = false

	FadeBlack(0)

	if shakeConnection then
		shakeConnection:Disconnect()
		shakeConnection = nil
	end

	local area = GetWormHoleArea()
	if area then
		local wormHoleCamera = area:FindFirstChild("WormHoleCamera")
		if wormHoleCamera and wormHoleCamera:IsA("Camera") and baseCFrame then
			wormHoleCamera.CFrame = baseCFrame
		end
	end
	baseCFrame = nil

	destroyWormHoleCamera()

	local localPlayer = Players.LocalPlayer
	local character = localPlayer and localPlayer.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if workspace.CurrentCamera and humanoid then
		workspace.CurrentCamera.CameraType = Enum.CameraType.Custom
		workspace.CurrentCamera.CameraSubject = humanoid
	end

	WormHoleVFX.RestoreLighting()
	WormHoleVFX.ResetParticles()

	FadeBlack(1)
end

function WormHoleVFX.DarkenLighting()
	if savedBrightness == nil then savedBrightness = Lighting.Brightness end
	if savedAmbient == nil then savedAmbient = Lighting.Ambient end
	if savedOutdoorAmbient == nil then savedOutdoorAmbient = Lighting.OutdoorAmbient end
	if savedClockTime == nil then savedClockTime = Lighting.ClockTime end
	Lighting.Brightness = 0
	Lighting.Ambient = Color3.new(0, 0, 0)
	Lighting.OutdoorAmbient = Color3.new(0, 0, 0)
	Lighting.ClockTime = 0
end

function WormHoleVFX.RestoreLighting()
	if savedBrightness ~= nil then Lighting.Brightness = savedBrightness; savedBrightness = nil end
	if savedAmbient ~= nil then Lighting.Ambient = savedAmbient; savedAmbient = nil end
	if savedOutdoorAmbient ~= nil then Lighting.OutdoorAmbient = savedOutdoorAmbient; savedOutdoorAmbient = nil end
	if savedClockTime ~= nil then Lighting.ClockTime = savedClockTime; savedClockTime = nil end
end

function WormHoleVFX.UpdateParticleEffects(speedRatio: number)
	if not isActive then return end
	local maxMult = TrackRunVFXConfig.WormholeParticleMaxMultiplier
	local t = math.clamp(speedRatio, 0, 1)
	local multiplier = 1.0 + t * (maxMult - 1.0)
	if lapBoostActive then
		multiplier = multiplier * TrackRunVFXConfig.WormholeLapBoostMultiplier
	end
	for emitter, base in baseParticleValues do
		emitter.Rate = base.Rate * multiplier
		emitter.Speed = NumberRange.new(base.SpeedMin * multiplier, base.SpeedMax * multiplier)
	end
end

function WormHoleVFX.TriggerLapBoost()
	if not isActive then return end
	if lapBoostThread then
		task.cancel(lapBoostThread)
		lapBoostThread = nil
	end
	lapBoostActive = true
	lapBoostThread = task.delay(TrackRunVFXConfig.WormholeLapBoostDuration, function()
		lapBoostActive = false
		lapBoostThread = nil
	end)
end

function WormHoleVFX.ResetParticles()
	if lapBoostThread then
		task.cancel(lapBoostThread)
		lapBoostThread = nil
	end
	lapBoostActive = false
	for emitter, base in baseParticleValues do
		if emitter and emitter.Parent then
			emitter.Rate = base.Rate
			emitter.Speed = NumberRange.new(base.SpeedMin, base.SpeedMax)
		end
	end
	table.clear(baseParticleValues)
end

function WormHoleVFX.IsActive(): boolean
	return isActive
end

return WormHoleVFX
