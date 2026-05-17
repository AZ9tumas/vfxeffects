--!strict
--[[
	TrailVFX object — clones the Trail template onto TrackChar's HRP once
	the distance threshold is met, then grows trail lifetime over time.

	Owns the TrailCameraVFX cinematic camera. This object knows nothing
	about WormHoleVFX; when the wormhole takes over it asks TrailVFX to
	deactivate via the shared VFXHandler.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Modules = ReplicatedStorage:WaitForChild("Modules")
local TrackRunVFXConfig = require(Modules:WaitForChild("TrackRunVFXConfig"))
local TrailCameraVFX = require(Modules:WaitForChild("TrailCameraVFX"))

local types = require(script.Parent:WaitForChild("types"))
type VFXContext = types.VFXContext

local TrailTemplate = ReplicatedStorage:WaitForChild("Assets"):WaitForChild("VFX"):WaitForChild("Trail")

local TrailVFX = {}
TrailVFX.Name = "Trail"
TrailVFX.Enabled = true
TrailVFX.Configuration = TrackRunVFXConfig.Trail
TrailVFX.Handler = nil :: any

local _active = false

function TrailVFX:IsActive(): boolean
	return _active
end

function TrailVFX:Activate(context: VFXContext)
	if _active then return end
	local hrp = context.trackCharHRP
	if not hrp then return end
	if hrp:FindFirstChild("TrackTrailA0") then
		_active = true
		return
	end

	local trailPart = TrailTemplate:Clone()
	local a0 = trailPart:FindFirstChild("0") :: Attachment
	local a1 = trailPart:FindFirstChild("1") :: Attachment
	if not a0 or not a1 then
		trailPart:Destroy()
		return
	end
	a0.Name = "TrackTrailA0"
	a1.Name = "TrackTrailA1"
	a0.Parent = hrp
	a1.Parent = hrp
	for _, child in trailPart:GetChildren() do
		if child:IsA("Trail") then
			child.Attachment0 = a0
			child.Attachment1 = a1
			child.Parent = hrp
		end
	end
	trailPart:Destroy()

	_active = true

	-- Take over the camera with the cinematic. The wormhole's threshold is
	-- strictly later than the trail's, so there's no contention here — once
	-- the wormhole's threshold is hit, WormholeVFX will ask us (through the
	-- handler) to deactivate gracefully.
	TrailCameraVFX.Activate(hrp, context.trackCenter)
end

function TrailVFX:Update(context: VFXContext)
	if not _active then return end
	local hrp = context.trackCharHRP
	if not hrp then return end

	local lifetime = math.clamp(
		TrackRunVFXConfig.TrailBaseLifetime + TrackRunVFXConfig.TrailGrowthRate * context.elapsedTime,
		TrackRunVFXConfig.TrailBaseLifetime,
		TrackRunVFXConfig.TrailMaxLifetime
	)
	for _, child in hrp:GetChildren() do
		if child:IsA("Trail") and child.Attachment0 and child.Attachment0.Name == "TrackTrailA0" then
			child.Lifetime = lifetime
		end
	end
end

-- Deactivate the trail.
--   graceful = true  : play TrailCameraVFX's return phase first (yields),
--                       producing a smooth hand-off to whatever is taking
--                       over the camera next (e.g. the wormhole).
--   graceful = false : immediate cleanup, used at end-of-track teardown.
function TrailVFX:Deactivate(graceful: boolean?)
	if not _active then return end
	_active = false
	if graceful and TrailCameraVFX.IsActive() then
		TrailCameraVFX.RunReturnPhase() -- yields until done
	end
	TrailCameraVFX.Deactivate()
	-- Trail attachments live on TrackChar; controller destroys TrackChar
	-- on track end so no explicit cleanup is required here.
end

return TrailVFX
