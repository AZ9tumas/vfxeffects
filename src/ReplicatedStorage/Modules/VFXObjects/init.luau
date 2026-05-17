--!strict
--[[
	VFXHandler — parent object that owns every track-run VFX. Each child VFX
	is reachable as a named field (e.g. VFXHandler.Trail, VFXHandler.Wormhole)
	so siblings can interact with each other through the handler without
	cross-importing their modules.

	Lifecycle:
	  VFXHandler:Init(context)       -- start of run; activates AlwaysOn, queues rest
	  VFXHandler:Update(context)     -- every frame; ticks active, drains queue
	  VFXHandler:Deactivate()        -- end of run; tears every active effect down

	To register a new VFX:
	  1. Create <NewName>VFX.luau in this folder matching the VFXObject type.
	  2. Require it below, expose it as a named field, and add it to _registry.
	  3. Set AlwaysOn = true on the object if it should run for the entire
	     track run (e.g. AfterImages).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TrackRunVFXConfig = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("TrackRunVFXConfig"))

local types = require(script:WaitForChild("types"))
export type VFXContext = types.VFXContext
export type VFXObject = types.VFXObject

local TrailVFX = require(script:WaitForChild("TrailVFX"))
local AuraVFX = require(script:WaitForChild("AuraVFX"))
local WormholeVFX = require(script:WaitForChild("WormholeVFX"))
local AfterImagesVFX = require(script:WaitForChild("AfterImagesVFX"))

local VFXHandler = {}

-- Named children (public API). Reachable as:
--   VFXHandler.Trail:Deactivate()
--   if VFXHandler.Wormhole:IsActive() then ... end
VFXHandler.Trail = TrailVFX
VFXHandler.Aura = AuraVFX
VFXHandler.Wormhole = WormholeVFX
VFXHandler.AfterImages = AfterImagesVFX

-- Ordered registry the queue iterates over. Order is informational; each
-- object activates independently when its threshold is met.
VFXHandler._registry = {
	TrailVFX,
	AuraVFX,
	WormholeVFX,
	AfterImagesVFX,
}

-- Internal queue / active state. Children NEVER touch these directly —
-- they coordinate through the named fields above (e.g. self.Handler.Trail).
VFXHandler._queue = {} :: { any }
VFXHandler._active = {} :: { any }

-- Inject the handler reference into every child so they can address siblings.
for _, vfx in VFXHandler._registry do
	vfx.Handler = VFXHandler
end

function VFXHandler:Init(context: VFXContext)
	self._queue = {}
	self._active = {}
	for _, vfx in self._registry do
		if not vfx.Enabled then continue end
		if vfx.AlwaysOn then
			vfx:Activate(context)
			table.insert(self._active, vfx)
		else
			table.insert(self._queue, vfx)
		end
	end
end

function VFXHandler:Update(context: VFXContext)
	-- Tick currently-active effects.
	for _, vfx in self._active do
		vfx:Update(context)
	end

	-- Drain the queue: promote anything whose threshold has been crossed.
	for i = #self._queue, 1, -1 do
		local vfx = self._queue[i]
		if TrackRunVFXConfig.IsThresholdMet(vfx.Configuration, context.distanceTraveled, context.playerMaxDistance) then
			vfx:Activate(context)
			table.insert(self._active, vfx)
			table.remove(self._queue, i)
		end
	end
end

function VFXHandler:Deactivate()
	for _, vfx in self._active do
		vfx:Deactivate()
	end
	self._active = {}
	self._queue = {}
end

-- Removes an object from the active/queue lists. Used by siblings that
-- take over from an existing effect: e.g. WormholeVFX calls
-- self.Handler:Retire(self.Handler.Trail) after asking Trail to deactivate.
function VFXHandler:Retire(target: any)
	for i = #self._active, 1, -1 do
		if self._active[i] == target then
			table.remove(self._active, i)
		end
	end
	for i = #self._queue, 1, -1 do
		if self._queue[i] == target then
			table.remove(self._queue, i)
		end
	end
end

return VFXHandler
