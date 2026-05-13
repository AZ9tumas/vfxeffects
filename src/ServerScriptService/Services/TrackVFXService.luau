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
local AuraTemplate = VFXFolder:WaitForChild("CyberpunkAura")

local AURA_BODY_PARTS = { "Head", "Torso", "Left Arm", "Right Arm", "Left Leg", "Right Leg" }

local PlayerVFXState = {}

local function Log(_message: string)
	--print(string.format("[TrackVFXService]: %s", _message))
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
	self:RemoveAura(player)
	PlayerVFXState[player.UserId] = nil
end

function TrackVFXService:UpdateVFX(player: Player, currentRunDistance: number, playerMaxDistance: number, elapsedTime: number)
	local userId = player.UserId
	local state = PlayerVFXState[userId]
	if not state then
		state = { auraApplied = false }
		PlayerVFXState[userId] = state
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
