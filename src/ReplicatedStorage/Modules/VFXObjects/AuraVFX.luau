--!strict
--[[
	AuraVFX object — clones CyberpunkAura particle emitters onto each
	body part of TrackChar when the distance threshold is met.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local TrackRunVFXConfig = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("TrackRunVFXConfig"))

local types = require(script.Parent:WaitForChild("types"))
type VFXContext = types.VFXContext

local AuraTemplate = ReplicatedStorage:WaitForChild("Assets"):WaitForChild("VFX"):WaitForChild("CyberpunkAura")

local AURA_BODY_PARTS = { "Head", "Torso", "Left Arm", "Right Arm", "Left Leg", "Right Leg" }

local AuraVFX = {}
AuraVFX.Name = "Aura"
AuraVFX.Enabled = true
AuraVFX.Configuration = TrackRunVFXConfig.Aura

local _active = false
local _trackChar: Model? = nil

function AuraVFX:IsActive(): boolean
	return _active
end

function AuraVFX:Activate(context: VFXContext)
	if _active then return end
	local trackChar = context.trackChar
	if not trackChar then return end

	_trackChar = trackChar

	for _, partName in AURA_BODY_PARTS do
		local charPart = trackChar:FindFirstChild(partName)
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

	_active = true
end

function AuraVFX:Update(_context: VFXContext)
	-- particle emitters drive themselves; no per-frame work required.
end

function AuraVFX:Deactivate()
	if not _active then
		_trackChar = nil
		return
	end
	local trackChar = _trackChar
	if trackChar then
		for _, partName in AURA_BODY_PARTS do
			local part = trackChar:FindFirstChild(partName)
			if not part then continue end
			for _, child in part:GetChildren() do
				if child:IsA("ParticleEmitter") and string.sub(child.Name, 1, 10) == "TrackAura_" then
					child:Destroy()
				end
			end
		end
	end
	_active = false
	_trackChar = nil
end

return AuraVFX
