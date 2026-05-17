--!strict
--[[
	WormholeVFX object — threshold-gated activation of the wormhole camera
	transition.

	This object knows nothing about TrailCameraVFX. When it takes over it
	asks the sibling TrailVFX (reached via self.Handler.Trail) to perform a
	graceful deactivation, which is how the smooth cinematic-camera return
	phase is preserved.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Modules = ReplicatedStorage:WaitForChild("Modules")
local TrackRunVFXConfig = require(Modules:WaitForChild("TrackRunVFXConfig"))
local WormHoleVFX = require(Modules:WaitForChild("WormHoleVFX"))

local types = require(script.Parent:WaitForChild("types"))
type VFXContext = types.VFXContext

local WormholeVFX = {}
WormholeVFX.Name = "Wormhole"
WormholeVFX.Enabled = true
WormholeVFX.Configuration = TrackRunVFXConfig.Wormhole
WormholeVFX.Handler = nil :: any

local _active = false

function WormholeVFX:IsActive(): boolean
	return _active or WormHoleVFX.IsActive()
end

function WormholeVFX:Activate(_context: VFXContext)
	if _active then return end
	_active = true

	-- Sibling hand-off: ask TrailVFX (through the handler) to deactivate
	-- gracefully. Trail owns the cinematic camera and the return phase;
	-- we don't import TrailCameraVFX directly. Once Trail releases the
	-- camera we activate the wormhole.
	local handler = self.Handler
	task.spawn(function()
		if handler and handler.Trail and handler.Trail:IsActive() then
			handler.Trail:Deactivate(true)
			handler:Retire(handler.Trail)
		end
		WormHoleVFX.Activate()
	end)
end

function WormholeVFX:Update(context: VFXContext)
	if not WormHoleVFX.IsActive() then return end

	local playerMaxDist = context.playerMaxDistance
	local wormholeDistThreshold = math.max(
		TrackRunVFXConfig.Wormhole.AbsoluteDistance,
		playerMaxDist * TrackRunVFXConfig.Wormhole.PercentageOfTotal
	)
	local wormholeSpeedRatio = math.clamp(
		(context.distanceTraveled - wormholeDistThreshold)
			/ math.max(1, context.trackData.totalDistance - wormholeDistThreshold),
		0, 1
	)
	WormHoleVFX.UpdateParticleEffects(wormholeSpeedRatio)
end

function WormholeVFX:Deactivate()
	_active = false
	task.spawn(function() WormHoleVFX.Deactivate() end)
end

-- Lap-boost forwarder so TrackController doesn't have to know about the
-- underlying WormHoleVFX module.
function WormholeVFX:OnLap()
	if WormHoleVFX.IsActive() then
		WormHoleVFX.TriggerLapBoost()
	end
end

return WormholeVFX
