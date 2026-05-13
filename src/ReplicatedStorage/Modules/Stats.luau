--[[
	Stats (slim port) — track-run constants and pure helper functions only.
	Stripped of egg/pet/star/rebirth/world-progression data; this place hosts
	a single hardcoded "JurassicPeriod" world for isolated VFX testing.
]]

local Workspace = game:GetService("Workspace")

local Stats = {}

-- Movement
Stats.NormalWalkSpeed = 16
Stats.BaseSpeed = 50
Stats.MaxTrackTime = 45
Stats.RampDuration = 15
Stats.InitialSpeed = 150
Stats.RampTargetSpeed = 1_650
Stats.MaxPhysicalSpeed =  2500
Stats.BaseAcceleration = 150

-- Overdrive
Stats.OverdriveTimeframe = 5
Stats.OverdriveSpeedMultiplier = 25
Stats.OverdriveDuration = 10

-- Track / gate
Stats.TrackWidth = 35
Stats.GateProximityDistance = 30
Stats.MaxGateIndex = 3

-- World metadata kept minimal (single-world test bed)
Stats.WorldDisplayNames = { JurassicPeriod = "Jurassic Period" }
Stats.WorldOrder = { "JurassicPeriod" }
Stats.WorldCashRates = { JurassicPeriod = 150, Main = 150 }

-- World unlock helpers retained but always return nil (no progression in this test bed)
function Stats.GetWorldDistanceRequirement(_worldName: string): number?
	return nil
end

function Stats.GetWorldRebirthRequirement(_worldName: string): number?
	return nil
end

-- 1_Central_Arena cylinder lookup (cylinder diameter = Size.Y = Size.Z)
local function GetCentralArenaPart(worldName: string): BasePart?
	local worldFolder = Workspace:FindFirstChild(worldName) or Workspace:FindFirstChild("JurassicPeriod")
	if not worldFolder then return nil end
	local part = worldFolder:FindFirstChild("1_Central_Arena")
	if part and part:IsA("BasePart") then
		return part
	end
	return nil
end

function Stats.GetArenaRadius(worldName: string): number?
	local arena = GetCentralArenaPart(worldName)
	if not arena then return nil end
	return arena.Size.Y / 2
end

function Stats.GetTrackRadius(worldName: string): number?
	local arenaRadius = Stats.GetArenaRadius(worldName)
	if not arenaRadius then return nil end
	return arenaRadius + Stats.TrackWidth
end

function Stats.GetArenaCenter(worldName: string): Vector3?
	local arena = GetCentralArenaPart(worldName)
	if not arena then return nil end
	return arena.Position
end

function Stats.CalculateMultipliers(_rebirthSpeedMultiplier: number?): number
	return 1.0
end

-- Two-phase acceleration model: ramp from InitialSpeed → RampTargetSpeed over RampDuration,
-- then post-ramp acceleration to cover the remaining distance in ≤ MaxTrackTime.
function Stats.CalculateTrackParameters(fuel: number, _worldName: string?, launcherMultiplier: number?):
	{ initialSpeed: number, acceleration: number, maxSpeed: number, totalTime: number, totalDistance: number, rampDuration: number, postRampAcceleration: number }

	local totalDistance = fuel * Stats.CalculateMultipliers() * (launcherMultiplier or 1)

	if totalDistance <= 0 then
		return {
			initialSpeed = 0, acceleration = 0, maxSpeed = 0,
			totalTime = 0, totalDistance = 0, rampDuration = 0, postRampAcceleration = 0,
		}
	end

	local rampDur = Stats.RampDuration
	local initSpd = Stats.InitialSpeed
	local targetSpd = Stats.RampTargetSpeed
	local maxTime = Stats.MaxTrackTime

	local rampAccel = (targetSpd - initSpd) / rampDur
	local rampDistance = initSpd * rampDur + 0.5 * rampAccel * rampDur * rampDur

	local postRampAccel = 0
	local totalTime: number
	local maxSpeed: number

	if totalDistance <= rampDistance then
		if rampAccel > 0 then
			local discriminant = initSpd * initSpd + 2 * rampAccel * totalDistance
			totalTime = (-initSpd + math.sqrt(discriminant)) / rampAccel
		else
			totalTime = if initSpd > 0 then totalDistance / initSpd else 0
		end
		maxSpeed = initSpd + rampAccel * totalTime
	else
		local remainingDistance = totalDistance - rampDistance
		local maxRemainingTime = maxTime - rampDur
		local timeAtConstant = remainingDistance / targetSpd

		if timeAtConstant <= maxRemainingTime then
			totalTime = rampDur + timeAtConstant
			postRampAccel = 0
			maxSpeed = targetSpd
		else
			local t2 = maxRemainingTime
			postRampAccel = math.max(2 * (remainingDistance - targetSpd * t2) / (t2 * t2), 0)
			totalTime = maxTime
			maxSpeed = targetSpd + postRampAccel * t2
		end
	end

	return {
		initialSpeed = initSpd,
		acceleration = rampAccel,
		maxSpeed = maxSpeed,
		totalTime = totalTime,
		totalDistance = totalDistance,
		rampDuration = math.min(rampDur, totalTime),
		postRampAcceleration = postRampAccel,
	}
end

function Stats.CalculateCurrentSpeed(
	initialSpeed: number,
	acceleration: number,
	maxSpeed: number,
	elapsedTime: number,
	rampDuration: number?,
	postRampAcceleration: number?
): number
	local rampDur = rampDuration or Stats.RampDuration
	local postAccel = postRampAcceleration or 0
	local speed: number
	if elapsedTime <= rampDur then
		speed = initialSpeed + acceleration * elapsedTime
	else
		local speedAtRampEnd = initialSpeed + acceleration * rampDur
		speed = speedAtRampEnd + postAccel * (elapsedTime - rampDur)
	end
	return math.min(speed, maxSpeed)
end

function Stats.LinearSpeedToAngularVelocity(linearSpeed: number, radius: number): number
	if radius <= 0 then return 0 end
	return linearSpeed / radius
end

function Stats.PolarToCartesian(centerX: number, centerZ: number, radius: number, angle: number): (number, number)
	return centerX + radius * math.cos(angle), centerZ + radius * math.sin(angle)
end

return Stats
