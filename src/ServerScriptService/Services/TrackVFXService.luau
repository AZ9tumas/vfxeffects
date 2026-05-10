--[[
	TrackVFXService
	Owns all track-run visual effects: trail, cyberpunk aura.
	Delegated to by TrackService during the heartbeat loop.
	Trail length (Lifetime) increases significantly over the duration of a run.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Knit = require(ReplicatedStorage.Packages.Knit)
local TrackRunVFXConfig = require(ReplicatedStorage.Modules.TrackRunVFXConfig)

local TrackVFXService = Knit.CreateService({
	Name = "TrackVFXService",
	Client = {},
})

local VFXFolder = ReplicatedStorage:WaitForChild("Assets"):WaitForChild("VFX")
local TrailTemplate = VFXFolder:WaitForChild("Trail")
local AuraTemplate = VFXFolder:WaitForChild("CyberpunkAura")

local AURA_BODY_PARTS = { "Head", "Torso", "Left Arm", "Right Arm", "Left Leg", "Right Leg" }

local PlayerVFXState = {}

local function Log(_message: string)
	--print(string.format("[TrackVFXService]: %s", _message))
end

function TrackVFXService:ApplyTrail(player: Player)
	local character = player.Character
	if not character then return end

	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if not rootPart then return end

	if rootPart:FindFirstChild("TrackTrailA0") then return end

	local trailPart = TrailTemplate:Clone()

	local a0 = trailPart:FindFirstChild("0") :: Attachment
	local a1 = trailPart:FindFirstChild("1") :: Attachment
	if not a0 or not a1 then
		trailPart:Destroy()
		return
	end
	a0.Name = "TrackTrailA0"
	a1.Name = "TrackTrailA1"
	a0.Parent = rootPart
	a1.Parent = rootPart

	for _, child in trailPart:GetChildren() do
		if child:IsA("Trail") then
			child.Attachment0 = a0
			child.Attachment1 = a1
			child.Parent = rootPart
		end
	end

	trailPart:Destroy()
	Log(string.format("Applied trail VFX to player %s", player.Name))
end

function TrackVFXService:RemoveTrail(player: Player)
	local character = player.Character
	if not character then return end
	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if not rootPart then return end

	for _, child in rootPart:GetChildren() do
		if child:IsA("Trail") and (child.Attachment0 and child.Attachment0.Name == "TrackTrailA0") then
			child:Destroy()
		end
	end

	local a0 = rootPart:FindFirstChild("TrackTrailA0")
	if a0 then a0:Destroy() end
	local a1 = rootPart:FindFirstChild("TrackTrailA1")
	if a1 then a1:Destroy() end
end

local function UpdateTrailLifetime(player: Player, elapsedTime: number)
	local character = player.Character
	if not character then return end
	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if not rootPart then return end

	local baseLifetime = TrackRunVFXConfig.TrailBaseLifetime
	local maxLifetime = TrackRunVFXConfig.TrailMaxLifetime
	local growthRate = TrackRunVFXConfig.TrailGrowthRate
	local lifetime = math.clamp(baseLifetime + growthRate * elapsedTime, baseLifetime, maxLifetime)

	for _, child in rootPart:GetChildren() do
		if child:IsA("Trail") and (child.Attachment0 and child.Attachment0.Name == "TrackTrailA0") then
			child.Lifetime = lifetime
		end
	end
end

function TrackVFXService:ApplyAura(player: Player)
	local character = player.Character
	if not character then return end

	local head = character:FindFirstChild("Head")
	if head and head:FindFirstChild("TrackAura_Glitch") then return end

	for _, partName in AURA_BODY_PARTS do
		local charPart = character:FindFirstChild(partName)
		if not charPart then continue end

		local templatePart = AuraTemplate:FindFirstChild(partName)
		if not templatePart then continue end

		for _, child in templatePart:GetChildren() do
			if child:IsA("ParticleEmitter") then
				local emitter = child:Clone()
				emitter.Name = "TrackAura_" .. child.Name
				emitter.Parent = charPart
			end
		end
	end
	Log(string.format("Applied aura VFX to player %s", player.Name))
end

function TrackVFXService:RemoveAura(player: Player)
	local character = player.Character
	if not character then return end

	for _, partName in AURA_BODY_PARTS do
		local part = character:FindFirstChild(partName)
		if not part then continue end
		for _, child in part:GetChildren() do
			if child:IsA("ParticleEmitter") and string.sub(child.Name, 1, 10) == "TrackAura_" then
				child:Destroy()
			end
		end
	end
end

function TrackVFXService:CleanupAllVFX(player: Player)
	self:RemoveTrail(player)
	self:RemoveAura(player)
	PlayerVFXState[player.UserId] = nil
end

function TrackVFXService:UpdateVFX(player: Player, currentRunDistance: number, playerMaxDistance: number, elapsedTime: number)
	local userId = player.UserId
	local state = PlayerVFXState[userId]
	if not state then
		state = { trailApplied = false, auraApplied = false }
		PlayerVFXState[userId] = state
	end

	if TrackRunVFXConfig.IsThresholdMet(TrackRunVFXConfig.Trail, currentRunDistance, playerMaxDistance) then
		if not state.trailApplied then
			self:ApplyTrail(player)
			state.trailApplied = true
		end
		UpdateTrailLifetime(player, elapsedTime)
	else
		if state.trailApplied then
			self:RemoveTrail(player)
			state.trailApplied = false
		end
	end

	if TrackRunVFXConfig.IsThresholdMet(TrackRunVFXConfig.Aura, currentRunDistance, playerMaxDistance) then
		if not state.auraApplied then
			self:ApplyAura(player)
			state.auraApplied = true
		end
	else
		if state.auraApplied then
			self:RemoveAura(player)
			state.auraApplied = false
		end
	end
end

function TrackVFXService:KnitInit() end
function TrackVFXService:KnitStart() end

return TrackVFXService
