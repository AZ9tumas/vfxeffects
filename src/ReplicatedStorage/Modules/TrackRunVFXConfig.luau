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
TrackRunVFXConfig.TrailBaseLifetime = 0.1
TrackRunVFXConfig.TrailMaxLifetime = 0.35
TrackRunVFXConfig.TrailGrowthRate = 0.05

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
TrackRunVFXConfig.TrailCameraReverseToCenterPeriod = 0.5

-- Phase 3: at the arena centre, rotate in place from "facing the runner"
-- to "facing straight down".
TrackRunVFXConfig.TrailCameraFaceDownPeriod = 0.25

-- Phase 4: with the camera facing straight down, "reverse" along its
-- -LookVector (i.e. rise straight up in world space) over this duration.
TrackRunVFXConfig.TrailCameraAscendPeriod = 0.5

-- Total studs of vertical ascent during phase 4.
TrackRunVFXConfig.TrailCameraAscendDistance = 100

-- Return phase: interpolates the trail-camera back to the third-person
-- tangent offset (right next to the runner) before the wormhole VFX
-- takes the camera over. Mirrors the trail-camera intro, in reverse.
TrackRunVFXConfig.TrailCameraReturnPeriod = 0.35

-- =========================================================================
-- In-run third-person camera offset (relative to TrackChar HRP, in local
-- space of the tangent-facing CFrame). Tweak to retune the chase view.
-- =========================================================================
TrackRunVFXConfig.TrackCameraHeight = 5  -- studs above HRP centre
TrackRunVFXConfig.TrackCameraBack   = 10 -- studs behind HRP (along +Z in local space)

-- =========================================================================
-- Continuous subtle camera shake applied throughout the entire track run
-- (matches the wormhole-active "light" shake; tweak independently if needed).
-- The shake is applied on TOP of whatever CFrame the active camera-owner
-- (TrackController tangent / TrailCameraVFX / WormHoleVFX) writes.
-- =========================================================================
TrackRunVFXConfig.TrackRunContinuousShakeMagnitude = 0.04 -- positional sway, studs
TrackRunVFXConfig.TrackRunContinuousShakeRotation  = 0.05  -- rotational sway, degrees
TrackRunVFXConfig.TrackRunContinuousShakeFrequency = 3  -- base Hz multiplier

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

-- Continuous-shake basis frequencies (kept consistent with the wormhole
-- light shake so the cadence matches across all phases of the run).
local CONT_SHAKE_FREQ_X = 1.0
local CONT_SHAKE_FREQ_Y = 1.24
local CONT_SHAKE_FREQ_ROT = 0.68

--[[
	GetContinuousRunShakeCFrame(t)
	  Returns the additive shake-offset CFrame for time `t` (seconds). The
	  caller multiplies this onto its final camera CFrame to apply the
	  subtle continuous shake. Frequencies / magnitudes come from the
	  TrackRunContinuousShake* config values above.
]]
function TrackRunVFXConfig.GetContinuousRunShakeCFrame(t: number): CFrame
	local mag = TrackRunVFXConfig.TrackRunContinuousShakeMagnitude
	local rotMag = math.rad(TrackRunVFXConfig.TrackRunContinuousShakeRotation)
	local baseFreq = TrackRunVFXConfig.TrackRunContinuousShakeFrequency * math.pi * 2

	local ox = math.sin(t * baseFreq * CONT_SHAKE_FREQ_X) * mag
	local oy = math.sin(t * baseFreq * CONT_SHAKE_FREQ_Y) * mag
	local oRot = math.sin(t * baseFreq * CONT_SHAKE_FREQ_ROT) * rotMag
	return CFrame.new(ox, oy, 0) * CFrame.Angles(oRot, oRot * 0.5, 0)
end

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
