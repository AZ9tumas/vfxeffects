--[[
	RunButtonUIController (isolated test bed)
	Shows a "RUN" button when the local player is near any track gate.
	Hides itself while a track run is active or while a request is pending.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Knit = require(ReplicatedStorage:WaitForChild("Packages"):WaitForChild("Knit"))
local Stats = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("Stats"))

local RunButtonUIController = Knit.CreateController({
	Name = "RunButtonUIController",
})

local player = Players.LocalPlayer
local PlayerGui = player:WaitForChild("PlayerGui")

local runButton: TextButton
local requestingTrack = false

local function BuildUI()
	local gui = Instance.new("ScreenGui")
	gui.Name = "RunButtonUI"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.Parent = PlayerGui

	runButton = Instance.new("TextButton")
	runButton.Name = "Run"
	runButton.Size = UDim2.new(0, 220, 0, 64)
	runButton.AnchorPoint = Vector2.new(0.5, 1)
	runButton.Position = UDim2.new(0.5, 0, 1, -120)
	runButton.BackgroundColor3 = Color3.fromRGB(0, 170, 80)
	runButton.BorderSizePixel = 0
	runButton.AutoButtonColor = true
	runButton.Font = Enum.Font.GothamBlack
	runButton.TextSize = 28
	runButton.TextColor3 = Color3.fromRGB(255, 255, 255)
	runButton.Text = "RUN"
	runButton.Visible = false
	runButton.Parent = gui

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 10)
	corner.Parent = runButton
end

local function GetGatePositions(): { Vector3 }
	local out = {}
	local worldFolder = workspace:FindFirstChild("JurassicPeriod")
	if not worldFolder then return out end
	local ts = worldFolder:FindFirstChild("Track_System")
	if not ts then return out end
	local gates = ts:FindFirstChild("Track_Gates")
	if not gates then return out end

	for i = 0, Stats.MaxGateIndex do
		local g = gates:FindFirstChild("Gate_" .. i)
		if g then
			if g:IsA("BasePart") then
				table.insert(out, g.Position)
			elseif g:IsA("Model") then
				local p = g.PrimaryPart or g:FindFirstChildWhichIsA("BasePart")
				if p then table.insert(out, p.Position) end
			end
		end
	end
	return out
end

local function IsPlayerNearGate(): boolean
	local character = player.Character
	if not character then return false end
	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if not rootPart or not rootPart:IsA("BasePart") then return false end

	local proximity = Stats.GateProximityDistance
	for _, pos in GetGatePositions() do
		if (rootPart.Position - pos).Magnitude <= proximity then
			return true
		end
	end
	return false
end

function RunButtonUIController:KnitInit()
	BuildUI()
end

function RunButtonUIController:KnitStart()
	local TrackService = Knit.GetService("TrackService")
	local TrackController = Knit.GetController("TrackController")

	runButton.MouseButton1Click:Connect(function()
		if requestingTrack then return end
		if TrackController and TrackController:IsOnTrack() then return end

		requestingTrack = true
		runButton.Visible = false
		TrackService:RequestTrackStart():andThen(function(success: boolean, errorMsg: string?)
			requestingTrack = false
			if not success then
				warn("[RunButtonUIController]: " .. tostring(errorMsg))
			end
		end, function(err)
			requestingTrack = false
			warn("[RunButtonUIController]: request errored - " .. tostring(err))
		end)
	end)

	-- Update visibility on heartbeat (cheap, only 4 gates)
	local accum = 0
	RunService.Heartbeat:Connect(function(dt)
		accum = accum + dt
		if accum < 0.15 then return end
		accum = 0

		if requestingTrack then
			runButton.Visible = false
			return
		end
		if TrackController and TrackController:IsOnTrack() then
			runButton.Visible = false
			return
		end
		runButton.Visible = IsPlayerNearGate()
	end)
end

return RunButtonUIController
