--!strict
--[[
	VFXObjects/types — shared type definitions for the track-run VFX system.

	Every VFX object exposes the same interface so VFXHandler can manage
	them uniformly via a queue + active list. Each object also receives a
	reference back to its parent VFXHandler so it can interact with its
	siblings (e.g. WormholeVFX asks the handler to deactivate TrailVFX
	when its threshold is met) without taking direct module dependencies
	on them.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TrackRunVFXConfig = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("TrackRunVFXConfig"))

export type VFXContext = {
	trackChar: Model?,
	trackCharHRP: BasePart?,
	trackCenter: Vector3,
	trackData: any,
	distanceTraveled: number,
	elapsedTime: number,
	playerMaxDistance: number,
	dt: number,
}

export type VFXObject = {
	Name: string,
	-- Configuration drives threshold-gated activation. nil = always-on (see AlwaysOn).
	Configuration: TrackRunVFXConfig.VFXEntry?,
	-- Master switch checked by the handler before placing this object in the queue.
	Enabled: boolean,
	-- When true the object is activated at track start instead of being queued.
	AlwaysOn: boolean?,
	-- Set by VFXHandler at registration time so the object can address siblings.
	Handler: any,

	IsActive: (self: VFXObject) -> boolean,
	Activate: (self: VFXObject, context: VFXContext) -> (),
	Deactivate: (self: VFXObject, ...any) -> (),
	Update: (self: VFXObject, context: VFXContext) -> (),
}

return {}
