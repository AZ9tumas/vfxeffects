--[[
	TrackService (stripped for isolated VFX test bed)
	Handles track-run start/cancel/end and Overdrive.
	Hardcodes fuel + player MaxDistanceTraveled (no DataService / cash / rewards / pets).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Knit = require(ReplicatedStorage.Packages.Knit)
local Stats = require(ReplicatedStorage.Modules.Stats)
local BodyMoversTemplate = ReplicatedStorage:WaitForChild("Assets"):WaitForChild("BodyMovers")

-- ===== Hardcoded values (replaces player-data driven fuel + history) =====
local HARDCODED_FUEL = 10_000_000           -- "fuel" feeds CalculateTrackParameters → totalDistance
local HARDCODED_PLAYER_MAX_DISTANCE = 10_000_000 -- gates VFX (trail / aura / wormhole)
-- =========================================================================

local TrackService = Knit.CreateService({
	Name = "TrackService",
	Client = {
		TrackStarted = Knit.CreateSignal(),
		TrackEnded = Knit.CreateSignal(),
		Overdrive = Knit.CreateSignal(),
		EarlyWorldUnlock = Knit.CreateSignal(),
	},
})

local PlayersOnTrack = {}
local PlayerRequestDebounce = {}
local DEBOUNCE_COOLDOWN = 1
local HEARTBEAT_INTERVAL = 0.1 -- seconds between VFX threshold checks
local LastHeartbeatCheck = 0

local function Log(_message: string)
	--print(string.format("[TrackService]: %s", _message))
end

local function GetWorldFolder(worldName: string): Folder?
	return (Workspace:FindFirstChild(worldName) or Workspace:FindFirstChild("JurassicPeriod")) :: any
end

local function GetSpawnLocationForWorld(worldName: string): BasePart?
	local worldFolder = GetWorldFolder(worldName)
	if worldFolder then
		local spawn = worldFolder:FindFirstChild("SpawnLocation")
		if spawn and spawn:IsA("BasePart") then return spawn end
	end
	-- Fallback: any SpawnLocation in workspace
	for _, v in Workspace:GetDescendants() do
		if v:IsA("SpawnLocation") then return v end
	end
	return nil
end

local function GetTrackGatesForWorld(worldName: string): Folder?
	local worldFolder = GetWorldFolder(worldName)
	if worldFolder then
		local trackSystem = worldFolder:FindFirstChild("Track_System")
		if trackSystem then
			return trackSystem:FindFirstChild("Track_Gates") :: any
		end
	end
	return nil
end

local function GetTrackCenterForWorld(worldName: string): Vector3?
	local arenaCenter = Stats.GetArenaCenter(worldName)
	if arenaCenter then return arenaCenter end
	local spawnLocation = GetSpawnLocationForWorld(worldName)
	if spawnLocation then return spawnLocation.Position end
	return nil
end

local function GetGatePositionsForWorld(worldName: string): { [string]: Vector3 }
	local gates = {}
	local trackGates = GetTrackGatesForWorld(worldName)
	if not trackGates then return gates end

	for i = 0, Stats.MaxGateIndex do
		local gateName = "Gate_" .. i
		local gate = trackGates:FindFirstChild(gateName)
		if gate then
			if gate:IsA("BasePart") then
				gates[gateName] = gate.Position
			elseif gate:IsA("Model") then
				local primaryPart = gate.PrimaryPart or gate:FindFirstChildWhichIsA("BasePart")
				if primaryPart then gates[gateName] = primaryPart.Position end
			end
		end
	end
	return gates
end

local function FindClosestGate(playerPosition: Vector3, worldName: string): (string?, Vector3?, number?)
	local gates = GetGatePositionsForWorld(worldName)
	local closestGate, closestPosition, closestDistance = nil, nil, math.huge

	for gateName, gatePosition in pairs(gates) do
		local distance = (playerPosition - gatePosition).Magnitude
		if distance < closestDistance then
			closestDistance = distance
			closestGate = gateName
			closestPosition = gatePosition
		end
	end

	return closestGate, closestPosition, closestDistance
end

local function CalculateInitialAngle(position: Vector3, center: Vector3): number
	local dx = position.X - center.X
	local dz = position.Z - center.Z
	return math.atan2(dz, dx)
end

local function CalculateTrackParameters(_player: Player, worldName: string)
	-- Hardcoded fuel, no launcher / potion / rebirth multipliers.
	return Stats.CalculateTrackParameters(HARDCODED_FUEL, worldName, 1)
end

local function GetGateGroundY(worldName: string): number?
	local gates = GetGatePositionsForWorld(worldName)
	local totalY, count = 0, 0
	for _, position in pairs(gates) do
		totalY = totalY + position.Y
		count = count + 1
	end
	if count == 0 then return nil end
	return totalY / count
end

local function GetCharacterHeightOffset(character: Model): number
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if humanoid and rootPart and rootPart:IsA("BasePart") then
		return humanoid.HipHeight + rootPart.Size.Y / 2
	end
	return 3
end

local function CleanupBodyMovers(character: Model)
	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if not rootPart then return end

	local distanceValue = rootPart:FindFirstChild("TrackDistanceTraveled")
	if distanceValue then distanceValue:Destroy() end

	local alignPos = rootPart:FindFirstChild("AlignPosition")
	if alignPos then alignPos:Destroy() end

	local alignOri = rootPart:FindFirstChild("AlignOrientation")
	if alignOri then alignOri:Destroy() end

	local attachment = rootPart:FindFirstChild("TrackAttachment")
	if attachment then attachment:Destroy() end
end

local function SetupBodyMoversForPlayer(player: Player)
	local character = player.Character
	if not character then return end
	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if not rootPart or not rootPart:IsA("BasePart") then return end

	local attachment = Instance.new("Attachment")
	attachment.Name = "TrackAttachment"
	attachment.CFrame = CFrame.new()
	attachment.Parent = rootPart

	local alignPos = BodyMoversTemplate.AlignPosition:Clone()
	alignPos.Attachment0 = attachment
	alignPos.Position = rootPart.Position
	alignPos.Parent = rootPart

	local alignOri = BodyMoversTemplate.AlignOrientation:Clone()
	alignOri.Attachment0 = attachment
	alignOri.CFrame = rootPart.CFrame
	alignOri.Parent = rootPart
end

local function CleanupTrackRun(player: Player)
	local character = player.Character
	if character then CleanupBodyMovers(character) end

	local ok, TrackVFXService = pcall(Knit.GetService, "TrackVFXService")
	if ok and TrackVFXService then
		TrackVFXService:CleanupAllVFX(player)
	end

	PlayersOnTrack[player.UserId] = nil
end

local function ResetPlayerCamera(player: Player)
	local character = player.Character
	if not character then return end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local newCamera = Instance.new("Camera")
	newCamera.FieldOfView = 70
	newCamera.CameraType = Enum.CameraType.Custom
	if humanoid then newCamera.CameraSubject = humanoid end
	newCamera.Parent = Workspace
end

function TrackService:IsPlayerOnTrack(player: Player): boolean
	return PlayersOnTrack[player.UserId] ~= nil
end

function TrackService:GetPlayerTrackData(player: Player)
	return PlayersOnTrack[player.UserId]
end

function TrackService:EndTrackRun(player: Player, clientDistanceTraveled: number?, _worldUnlocked: boolean?)
	local userId = player.UserId
	local trackData = PlayersOnTrack[userId]
	if not trackData then return end

	local maxPossibleDistance = trackData.totalDistance
	local distanceTraveled = clientDistanceTraveled or maxPossibleDistance
	distanceTraveled = math.clamp(distanceTraveled, 0, maxPossibleDistance)

	Log(string.format("Player %s ended track run, distance: %.2f", player.Name, distanceTraveled))

	CleanupTrackRun(player)

	TrackService.Client.TrackEnded:Fire(player, {
		distanceTraveled = distanceTraveled,
		cashEarned = 0,
		percentageToNextWorld = 0,
	})

	-- Teleport back to spawn
	local spawnLocation = GetSpawnLocationForWorld(trackData.worldName)
	local character = player.Character
	if spawnLocation and character then
		local rootPart = character:FindFirstChild("HumanoidRootPart")
		if rootPart and rootPart:IsA("BasePart") then
			rootPart.CFrame = spawnLocation.CFrame + Vector3.new(0, 5, 0)
		end
	end

	ResetPlayerCamera(player)
end

function TrackService:RemovePlayerFromTrack(player: Player)
	self:EndTrackRun(player)
end

function TrackService.Client:RequestTrackStart(player: Player): (boolean, string?)
	local userId = player.UserId
	local currentTime = tick()

	local lastRequestTime = PlayerRequestDebounce[userId]
	if lastRequestTime and (currentTime - lastRequestTime) < DEBOUNCE_COOLDOWN then
		local remainingTime = DEBOUNCE_COOLDOWN - (currentTime - lastRequestTime)
		return false, string.format("Request too fast, wait %.1f seconds", remainingTime)
	end
	PlayerRequestDebounce[userId] = currentTime

	if PlayersOnTrack[userId] then
		return false, "Already on track"
	end

	local character = player.Character
	if not character then return false, "No character" end
	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if not rootPart or not rootPart:IsA("BasePart") then return false, "No HumanoidRootPart" end

	local worldName = "JurassicPeriod"
	local radius = Stats.GetTrackRadius(worldName)
	if not radius then return false, "No track radius found for world (missing 1_Central_Arena)" end

	local playerPosition = rootPart.Position
	local closestGate, gatePosition, gateDistance = FindClosestGate(playerPosition, worldName)
	if not closestGate or not gatePosition then return false, "No gates found" end

	local gateProximityDistance = Stats.GateProximityDistance
	if gateDistance and gateDistance > gateProximityDistance then
		return false, string.format("Must be within %d studs of a gate (currently %.1f studs away)", gateProximityDistance, gateDistance)
	end

	local center = GetTrackCenterForWorld(worldName)
	if not center then return false, "No track center found for world" end

	local gateY = GetGateGroundY(worldName)
	if not gateY then return false, "No gates found for height calculation" end
	local trackY = gateY + GetCharacterHeightOffset(character)

	local initialAngle = CalculateInitialAngle(playerPosition, center)

	SetupBodyMoversForPlayer(player)

	local distanceValue = rootPart:FindFirstChild("TrackDistanceTraveled")
	if not distanceValue then
		distanceValue = Instance.new("NumberValue")
		distanceValue.Name = "TrackDistanceTraveled"
		distanceValue.Value = 0
		distanceValue.Parent = rootPart
	end

	local trackParams = CalculateTrackParameters(player, worldName)

	-- TODO: Create a new "track character"
	--[[
		1. Character will be named as the "TrackChar"
		2. All baseparts.CanCollide = false and Anchored = false
		3. Y-axis control as well by body movers (full control)
		3.1 Calculate the correct Y axis offset value using bounds, etc. Has to be proper so it works for all characters.
		Idea: This allows us to simulate much higher physical speeds
	]]

	PlayersOnTrack[userId] = {
		player = player,
		worldName = worldName,
		startTime = tick(),
		gateIndex = tonumber(closestGate:match("%d+")),
		totalDistance = trackParams.totalDistance,
		currentAngle = initialAngle,
		startAngle = initialAngle,
		initialSpeed = trackParams.initialSpeed,
		acceleration = trackParams.acceleration,
		maxSpeed = trackParams.maxSpeed,
		totalTime = trackParams.totalTime,
		rampDuration = trackParams.rampDuration,
		postRampAcceleration = trackParams.postRampAcceleration,
		distanceTraveled = 0,
		elapsedTime = 0,
		lapCount = 0,
		overdriveUsed = false,
	}

	TrackService.Client.TrackStarted:Fire(player, {
		gateName = closestGate,
		totalDistance = trackParams.totalDistance,
		initialSpeed = trackParams.initialSpeed,
		acceleration = trackParams.acceleration,
		maxSpeed = trackParams.maxSpeed,
		totalTime = trackParams.totalTime,
		rampDuration = trackParams.rampDuration,
		postRampAcceleration = trackParams.postRampAcceleration,
		startAngle = initialAngle,
		worldName = worldName,
		worldRadius = radius,
		trackCenter = center,
		trackY = trackY,
		gateY = gateY,
		maxPhysicalSpeed = Stats.MaxPhysicalSpeed,
		nextWorld = nil,
		unlockRequirement = nil,
		rebirthRequirement = nil,
		playerMaxDistance = HARDCODED_PLAYER_MAX_DISTANCE,
	})

	return true, nil
end

function TrackService.Client:CancelTrackRun(player: Player): (boolean, string?)
	local userId = player.UserId
	local trackData = PlayersOnTrack[userId]
	if not trackData then return false, "Not currently on track" end

	local distanceTraveled = trackData.distanceTraveled or 0
	local worldName = trackData.worldName

	Log(string.format("Player %s cancelled track run, distance: %.2f", player.Name, distanceTraveled))

	CleanupTrackRun(player)

	local spawnLocation = GetSpawnLocationForWorld(worldName)
	local character = player.Character
	if spawnLocation and character then
		local rootPart = character:FindFirstChild("HumanoidRootPart")
		if rootPart and rootPart:IsA("BasePart") then
			rootPart.CFrame = spawnLocation.CFrame + Vector3.new(0, 5, 0)
		end
	end

	ResetPlayerCamera(player)

	TrackService.Client.TrackEnded:Fire(player, {
		distanceTraveled = distanceTraveled,
		cashEarned = 0,
		cancelled = true,
	})

	return true, nil
end

-- Client request to activate Overdrive (speed boost)
function TrackService.Client:RequestOverdrive(player: Player): (boolean, string?)
	local userId = player.UserId
	local trackData = PlayersOnTrack[userId]
	if not trackData then return false, "Not currently on track" end
	if trackData.overdriveUsed then return false, "Overdrive already used" end

	local elapsed = tick() - trackData.startTime
	if elapsed > Stats.OverdriveTimeframe then
		return false, "Overdrive timeframe expired"
	end

	trackData.overdriveUsed = true

	local multiplier = Stats.OverdriveSpeedMultiplier
	trackData.initialSpeed = trackData.initialSpeed * multiplier
	trackData.maxSpeed = trackData.maxSpeed * multiplier
	trackData.acceleration = trackData.acceleration * multiplier

	Log(string.format("Player %s activated Overdrive (x%.1f)", player.Name, multiplier))

	TrackService.Client.Overdrive:Fire(player, {
		initialSpeed = trackData.initialSpeed,
		maxSpeed = trackData.maxSpeed,
		acceleration = trackData.acceleration,
		duration = Stats.OverdriveDuration,
		multiplier = multiplier,
	})

	task.delay(Stats.OverdriveDuration, function()
		local currentTrackData = PlayersOnTrack[userId]
		if currentTrackData and currentTrackData == trackData then
			currentTrackData.initialSpeed = currentTrackData.initialSpeed / multiplier
			currentTrackData.maxSpeed = currentTrackData.maxSpeed / multiplier
			currentTrackData.acceleration = currentTrackData.acceleration / multiplier
		end
	end)

	return true, nil
end

function TrackService.Client:RequestTrackEnd(player: Player, distanceTraveled: number, worldUnlocked: boolean): (boolean, string?)
	local userId = player.UserId
	local trackData = PlayersOnTrack[userId]
	if not trackData then return false, "Not currently on track" end

	if type(distanceTraveled) ~= "number" or distanceTraveled < 0 then
		distanceTraveled = 0
	end

	TrackService:EndTrackRun(player, distanceTraveled, worldUnlocked)
	return true, nil
end

local function OnPlayerRemoving(player: Player)
	if PlayersOnTrack[player.UserId] then
		CleanupTrackRun(player)
	end
	PlayerRequestDebounce[player.UserId] = nil
end

local function EstimateDistanceTraveled(trackData): number
	local elapsed = tick() - trackData.startTime
	local v0 = trackData.initialSpeed
	local a1 = trackData.acceleration
	local maxSpeed = trackData.maxSpeed
	local rampDur = trackData.rampDuration or Stats.RampDuration
	local a2 = trackData.postRampAcceleration or 0
	local vRampEnd = v0 + a1 * rampDur
	local tPostRampToMax: number = (a2 > 0 and vRampEnd < maxSpeed) and ((maxSpeed - vRampEnd) / a2) or 0
	local tMaxSpeed = rampDur + tPostRampToMax
	if elapsed <= rampDur then
		return v0 * elapsed + 0.5 * a1 * elapsed * elapsed
	end
	local dRamp = v0 * rampDur + 0.5 * a1 * rampDur * rampDur
	local tAfterRamp = elapsed - rampDur
	if a2 > 0 and elapsed <= tMaxSpeed then
		return dRamp + vRampEnd * tAfterRamp + 0.5 * a2 * tAfterRamp * tAfterRamp
	end
	local dPostRamp = vRampEnd * tPostRampToMax + 0.5 * a2 * tPostRampToMax * tPostRampToMax
	return dRamp + dPostRamp + maxSpeed * (elapsed - tMaxSpeed)
end

function TrackService:KnitInit()
	Players.PlayerRemoving:Connect(OnPlayerRemoving)
end

function TrackService:KnitStart()
	Log("TrackService started")

	-- Heartbeat: drive TrackVFXService threshold checks (trail/aura/wormhole)
	RunService.Heartbeat:Connect(function()
		local currentTime = tick()
		if currentTime - LastHeartbeatCheck < HEARTBEAT_INTERVAL then return end
		LastHeartbeatCheck = currentTime

		local TrackVFXService = Knit.GetService("TrackVFXService")

		for _, trackData in pairs(PlayersOnTrack) do
			local player = trackData.player
			if not player or not player:IsDescendantOf(Players) then continue end

			local currentDistance = EstimateDistanceTraveled(trackData)

			local elapsedTime = currentTime - trackData.startTime
			TrackVFXService:UpdateVFX(player, currentDistance, HARDCODED_PLAYER_MAX_DISTANCE, elapsedTime)
		end
	end)
end

return TrackService
