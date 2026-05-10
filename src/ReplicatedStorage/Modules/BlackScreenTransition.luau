--[[
	BlackScreenTransition — wave-in / hold / wave-out black screen for the local player.
]]

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")

local WAVE_IN_TIME = 0.15
local WAVE_OUT_TIME = 0.15

local State = "IDLE"
local HoldEndTime = 0
local BlackFrame: Frame? = nil
local CurrentTween: Tween? = nil

local BlackScreenTransition = {}

local function GetBlackFrame(): Frame?
	if BlackFrame and BlackFrame.Parent then
		return BlackFrame
	end

	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui", 5)
	if not playerGui then return nil end

	local screenGui = playerGui:FindFirstChild("BlackScreenTransitionGui")
	if not screenGui then
		screenGui = Instance.new("ScreenGui")
		screenGui.Name = "BlackScreenTransitionGui"
		screenGui.DisplayOrder = 999
		screenGui.IgnoreGuiInset = true
		screenGui.ResetOnSpawn = false
		screenGui.Parent = playerGui
	end

	local frame = screenGui:FindFirstChild("BlackFrame")
	if not frame then
		frame = Instance.new("Frame")
		frame.Name = "BlackFrame"
		frame.Size = UDim2.fromScale(1, 1)
		frame.BackgroundColor3 = Color3.new(0, 0, 0)
		frame.BackgroundTransparency = 1
		frame.BorderSizePixel = 0
		frame.Visible = false
		frame.Parent = screenGui
	end

	BlackFrame = frame
	return frame
end

local function CancelCurrentTween()
	if CurrentTween then
		CurrentTween:Cancel()
		CurrentTween = nil
	end
end

local function DoWaveIn(frame: Frame)
	State = "WAVE_IN"
	frame.Visible = true
	frame.BackgroundTransparency = 1
	CurrentTween = TweenService:Create(frame, TweenInfo.new(WAVE_IN_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { BackgroundTransparency = 0 })
	CurrentTween:Play()
	CurrentTween.Completed:Wait()
	CurrentTween = nil
end

local function DoHold()
	State = "HOLD"
	while tick() < HoldEndTime do
		task.wait(0.05)
	end
end

local function DoWaveOut(frame: Frame)
	State = "WAVE_OUT"
	CurrentTween = TweenService:Create(frame, TweenInfo.new(WAVE_OUT_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.In), { BackgroundTransparency = 1 })
	CurrentTween:Play()
	CurrentTween.Completed:Wait()
	CurrentTween = nil

	if tick() < HoldEndTime then
		frame.BackgroundTransparency = 0
		DoHold()
		DoWaveOut(frame)
		return
	end

	frame.Visible = false
	State = "IDLE"
end

function BlackScreenTransition.Play(holdDuration: number)
	local frame = GetBlackFrame()
	if not frame then return end

	if State ~= "IDLE" then
		BlackScreenTransition.ExtendHold(holdDuration)
		return
	end

	HoldEndTime = tick() + WAVE_IN_TIME + holdDuration

	task.spawn(function()
		DoWaveIn(frame)
		DoHold()
		DoWaveOut(frame)
	end)
end

function BlackScreenTransition.ExtendHold(additionalHold: number)
	local newEnd = tick() + additionalHold
	if newEnd > HoldEndTime then
		HoldEndTime = newEnd
	end
	if State == "WAVE_OUT" then
		CancelCurrentTween()
		local frame = GetBlackFrame()
		if frame then frame.BackgroundTransparency = 0 end
		State = "HOLD"
	end
end

function BlackScreenTransition.IsActive(): boolean
	return State ~= "IDLE"
end

return BlackScreenTransition
