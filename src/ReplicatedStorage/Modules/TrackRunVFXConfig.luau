--!strict
--[[
	TrackRunVFXConfig — distance-based VFX activation thresholds.
]]

export type ThresholdMode = "AbsoluteDistance" | "PercentageOfTotal" | "Both"

export type VFXEntry = {
	Enabled: boolean,
	ThresholdMode: ThresholdMode,
	AbsoluteDistance: number,
	PercentageOfTotal: number,
}

local TrackRunVFXConfig = {}

-- VFX are never shown to players below this all-time best distance. 0 disables.
TrackRunVFXConfig.MinTotalPlayerDistance = 50_000

TrackRunVFXConfig.Trail = {
	Enabled = true,
	ThresholdMode = "AbsoluteDistance" :: ThresholdMode,
	AbsoluteDistance = 13_500,
	PercentageOfTotal = 0.15,
} :: VFXEntry

TrackRunVFXConfig.Aura = {
	Enabled = true,
	ThresholdMode = "PercentageOfTotal" :: ThresholdMode,
	AbsoluteDistance = 150_000,
	PercentageOfTotal = 0.40,
} :: VFXEntry

TrackRunVFXConfig.Wormhole = {
	Enabled = true,
	ThresholdMode = "Both" :: ThresholdMode,
	AbsoluteDistance = 1_500_000,
	PercentageOfTotal = 0.70,
} :: VFXEntry

-- Trail length growth over time
TrackRunVFXConfig.TrailBaseLifetime = 0.3
TrackRunVFXConfig.TrailMaxLifetime = 4.0
TrackRunVFXConfig.TrailGrowthRate = 0.15

-- Wormhole transition
TrackRunVFXConfig.WormholeFirstPersonZoom = 0.5
TrackRunVFXConfig.WormholeZoomTweenDuration = 2.0
TrackRunVFXConfig.WormholePreShakeDuration = 0.5
TrackRunVFXConfig.WormholePreShakeMagnitude = 1.5
TrackRunVFXConfig.WormholePreShakeRotation = 3.0
TrackRunVFXConfig.WormholeLightShakeMagnitude = 0.08
TrackRunVFXConfig.WormholeLightShakeRotation = 0.2
TrackRunVFXConfig.WormholeLightShakeFrequency = 2.5
TrackRunVFXConfig.WormholeParticleMaxMultiplier = 3.0
TrackRunVFXConfig.WormholeLapBoostMultiplier = 2.0
TrackRunVFXConfig.WormholeLapBoostDuration = 0.35
TrackRunVFXConfig.WormholeShakeMaxMultiplier = 4.0

function TrackRunVFXConfig.IsThresholdMet(
	vfxEntry: VFXEntry,
	currentRunDistance: number,
	playerMaxDistance: number
): boolean
	if not vfxEntry.Enabled then return false end
	if playerMaxDistance < TrackRunVFXConfig.MinTotalPlayerDistance then return false end

	local mode = vfxEntry.ThresholdMode
	local absoluteMet = currentRunDistance >= vfxEntry.AbsoluteDistance
	local percentageMet = currentRunDistance >= (playerMaxDistance * vfxEntry.PercentageOfTotal)

	if mode == "AbsoluteDistance" then
		return absoluteMet
	elseif mode == "PercentageOfTotal" then
		return percentageMet
	else
		return absoluteMet and percentageMet
	end
end

return TrackRunVFXConfig
