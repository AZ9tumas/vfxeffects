--!strict
--[[
	AfterImagesVFX object — always-on Sandevistan-style ghost trail.
	Activated at track start, deactivated at track end. Does not use a
	threshold; flagged with AlwaysOn = true so the controller skips the
	queue and activates it directly.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local AfterImagesVFX = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("AfterImagesVFX"))

local types = require(script.Parent:WaitForChild("types"))
type VFXContext = types.VFXContext

local AfterImagesObject = {}
AfterImagesObject.Name = "AfterImages"
AfterImagesObject.Enabled = true
AfterImagesObject.AlwaysOn = true
AfterImagesObject.Configuration = nil :: any

local _active = false

function AfterImagesObject:IsActive(): boolean
	return _active
end

function AfterImagesObject:Activate(context: VFXContext)
	if _active then return end
	if not context.trackChar then return end
	AfterImagesVFX.Activate(context.trackChar)
	_active = true
end

function AfterImagesObject:Update(_context: VFXContext)
	-- Self-driven via its own RunService loop; nothing to do here.
end

function AfterImagesObject:Deactivate()
	AfterImagesVFX.Deactivate()
	_active = false
end

return AfterImagesObject
