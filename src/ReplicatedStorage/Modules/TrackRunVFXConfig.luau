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
	AbsoluteDistance = 4_000,
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

-- =========================================================================
-- Trail Camera VFX — four-phase cinematic camera sequence played when the
-- Trail VFX activates. See TrailCameraVFX.luau for full design notes.
-- All durations are in seconds; tweak freely to retune the cinematic.
-- =========================================================================

-- Phase 1: hold position, rotate so the camera's LookVector matches the
-- direction from the arena centre to the TrackChar.
TrackRunVFXConfig.TrailCameraInitialTurnPeriod = 0.25

-- Phase 2: dolly the camera from its phase-1 position back to the arena
-- centre (XZ collapsed, Y preserved) while continuing to face the runner.
TrackRunVFXConfig.TrailCameraReverseToCenterPeriod = 0.35

-- Phase 3: at the arena centre, rotate in place from "facing the runner"
-- to "facing straight down".
TrackRunVFXConfig.TrailCameraFaceDownPeriod = 0.4

-- Phase 4: with the camera facing straight down, "reverse" along its
-- -LookVector (i.e. rise straight up in world space) over this duration.
TrackRunVFXConfig.TrailCameraAscendPeriod = 0.45

-- Total studs of vertical ascent during phase 4.
TrackRunVFXConfig.TrailCameraAscendDistance = 100

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
