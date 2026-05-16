--[[
	AfterImagesVFX — continuous Sandevistan-style ghost-trail of the TrackChar.

	Public API:
		AfterImagesVFX.Activate(trackChar)        -- begin spawning ghosts
		AfterImagesVFX.Deactivate()               -- stop + destroy pool
		AfterImagesVFX.IsActive()                 -- bool
		AfterImagesVFX.SetRateMultiplier(mult)    -- runtime tuning shortcut

	Design notes:
	  - Spawn cadence is a fixed interval (see TrackRunVFXConfig.AfterImages
	    .SpawnInterval), matching the upstream Sandevistan repo's simple
	    timer-based loop. RateMultiplier scales it at runtime.
	  - The Humanoid is REMOVED from the template before pre-building the
	    clone pool. Without a Humanoid the engine doesn't treat each ghost
	    as a "character" — this prevents the camera popper / zoom system
	    from being thrown off by ghost rigs co-located with the runner.
	    Motor6Ds still pose the rig correctly without a Humanoid present.
	  - Every clone part is Anchored = true and CanCollide/CanQuery/CanTouch
	    = false (no PhysicsService groups, per project requirement).
	  - The template is built from the TrackChar (the client-side clone),
	    NOT the original character. Joint transforms are sampled live from
	    the TrackChar on each spawn so the ghost matches the current pose.
	  - All visual emitters that would multiply per-ghost (Trails,
	    ParticleEmitters, Beams) and all body movers (AlignPosition,
	    AlignOrientation, AngularVelocity, the "TrackAttachment") are
	    stripped from the template.
]]

local RunService = game:GetService("RunService")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Modules = ReplicatedStorage:WaitForChild("Modules")

local TrackRunVFXConfig = require(Modules:WaitForChild("TrackRunVFXConfig"))
local Trove = require(Modules:WaitForChild("Trove"))
local ripple = require(Modules:WaitForChild("ripple"))

local AfterImagesVFX = {}

type TransparencyMap = { [Instance]: number }
type CacheRecord = {
	inUse: boolean,
	model: Model,
	highlight: Highlight,
	descendants: { Instance },
	transparencyMap: TransparencyMap,
	motion: ripple.Motion<number>,
	effectTrove: any,
}

-- =========================================================================
-- Module state
-- =========================================================================
local isActive = false
local runtimeRateMultiplier: number? = nil -- nil = use config value

local activeTrackChar: Model? = nil
local cloneCacheList: { CacheRecord } = {}
local originalJointsMap: { [string]: Motor6D } = {}
local afterImagesFolder: Folder? = nil

local startTime = 0
local lastCreationTime = -math.huge
local trove: any = nil

local highlightTemplate = Instance.new("Highlight")
highlightTemplate.DepthMode = Enum.HighlightDepthMode.Occluded
highlightTemplate.OutlineTransparency = 1

-- =========================================================================
-- Helpers
-- =========================================================================

-- Strip classes that should NOT be duplicated onto every ghost copy.
local STRIP_VFX_CLASSES = {
	Trail = true,
	ParticleEmitter = true,
	Beam = true,
	Smoke = true,
	Fire = true,
	Sparkles = true,
	Sound = true,
}
local STRIP_MOVER_CLASSES = {
	AlignPosition = true,
	AlignOrientation = true,
	AngularVelocity = true,
	BodyVelocity = true,
	BodyGyro = true,
	BodyPosition = true,
	LinearVelocity = true,
	VectorForce = true,
}

local function createCharacterTemplate(source: Model): Model?
	local wasArchivable = source.Archivable
	source.Archivable = true
	local templ: Model? = source:Clone()
	source.Archivable = wasArchivable
	if not templ then return nil end

	-- Remove the Humanoid entirely. With no Humanoid the model isn't
	-- treated as a character by the engine, which keeps the camera popper
	-- / zoom system from reacting to ghost rigs co-located with the runner.
	-- Motor6Ds continue to pose the rig correctly without a Humanoid.
	local hum = templ:FindFirstChildOfClass("Humanoid")
	if hum then hum:Destroy() end

	for _, child in ipairs(templ:GetDescendants()) do
		if child:IsA("BaseScript") then
			child:Destroy()
		elseif STRIP_VFX_CLASSES[child.ClassName] then
			child:Destroy()
		elseif STRIP_MOVER_CLASSES[child.ClassName] then
			child:Destroy()
		elseif child:IsA("Attachment") and child.Name == "TrackAttachment" then
			child:Destroy()
		elseif child:IsA("BasePart") then
			child.Anchored = true
			child.CanCollide = false
			child.CanQuery = false
			child.CanTouch = false
			child.CastShadow = false
			child.Massless = true
		elseif child:IsA("Motor6D") then
			child.Transform = CFrame.identity
		end
	end

	-- Leave Archivable = true so we can :Clone() pool copies from it.
	templ.Archivable = true
	return templ
end

local function createCacheRecord(characterTemplate: Model, parentTrove: any): CacheRecord
	local model = characterTemplate:Clone()
	model.Archivable = false

	local highlight = highlightTemplate:Clone()
	highlight.Parent = model

	local transparencyMap: TransparencyMap = {}
	local descendants = model:GetDescendants()
	for _, child in ipairs(descendants) do
		if child:IsA("BasePart") or child:IsA("Decal") then
			transparencyMap[child] = (child :: any).Transparency
		end
	end

	local motion = ripple.createMotion(0)
	motion:onStep(function(value)
		for part, originalTransparency in pairs(transparencyMap) do
			(part :: any).Transparency = (originalTransparency :: number) + (1 - (originalTransparency :: number)) * value
		end
		highlight.FillTransparency = TrackRunVFXConfig.AfterImages.HighlightBaseTransparency
			+ (1 - TrackRunVFXConfig.AfterImages.HighlightBaseTransparency) * value
	end)
	parentTrove:Add(motion.stop)

	local effectTrove = parentTrove:Extend()

	return {
		inUse = false,
		model = model,
		highlight = highlight,
		descendants = descendants,
		transparencyMap = transparencyMap,
		motion = motion,
		effectTrove = effectTrove,
	}
end

local function getEffectiveSpawnInterval(): number
	local cfg = TrackRunVFXConfig.AfterImages
	local mult = runtimeRateMultiplier or cfg.RateMultiplier or 1.0
	if mult <= 0 then return math.huge end
	local interval = cfg.SpawnInterval
	if interval <= 0 then return math.huge end
	return interval / mult
end

local function pickGradientColor(elapsed: number): Color3
	local cfg = TrackRunVFXConfig.AfterImages
	local gradients = cfg.Gradients
	local n = #gradients
	if n == 0 then return Color3.new(1, 1, 1) end
	if n == 1 then return gradients[1] end

	local cycle = cfg.GradientCycleTime
	if cycle <= 0 then return gradients[1] end

	local position = ((elapsed % cycle) / cycle) * n
	local index = math.floor(position) + 1
	local alpha = position - math.floor(position)
	local nextIndex = (index % n) + 1
	return gradients[index]:Lerp(gradients[nextIndex], alpha)
end

local function copyJointTransforms(record: CacheRecord)
	local trackChar = activeTrackChar
	if not trackChar then return end
	for _, child in ipairs(record.descendants) do
		if not child:IsA("Motor6D") then continue end
		local original = originalJointsMap[child.Name]
		if not original or not original.Parent then
			-- Re-scan TrackChar for this joint (accessories can load late)
			for _, j in ipairs(trackChar:GetDescendants()) do
				if j:IsA("Motor6D") and j.Name == child.Name then
					originalJointsMap[child.Name] = j
					original = j
					break
				end
			end
		end
		if original then
			(child :: Motor6D).Transform = original.Transform
		end
	end
end

local function spawnAfterImage()
	if not isActive then return end
	if not activeTrackChar or not activeTrackChar.Parent then return end
	if #cloneCacheList == 0 then return end

	-- Round-robin: take the head record (oldest spawn). If still in use,
	-- the pool is exhausted — skip this frame rather than allocate new.
	local record = cloneCacheList[1]
	if record.inUse then return end
	table.remove(cloneCacheList, 1)
	table.insert(cloneCacheList, record)

	record.inUse = true

	local cfg = TrackRunVFXConfig.AfterImages

	record.model:PivotTo(activeTrackChar:GetPivot())
	copyJointTransforms(record)

	local now = os.clock()
	record.highlight.FillColor = pickGradientColor(now - startTime)
	record.highlight.FillTransparency = cfg.HighlightBaseTransparency

	-- Spawn sequence (mirrors the reference Sandevistan):
	--   1. Snap to "fully invisible" (motion=1) before parenting so the
	--      clone never flashes at the runner's exact current position.
	--   2. Parent to the AfterImages folder.
	--   3. Wait HoldTime (lets the runner drift away from the spawn point).
	--   4. Snap to "fully visible" (motion=0) — the clone now appears
	--      slightly behind the runner.
	--   5. Hold for FadeOutTime, then spring back to invisible.
	--   6. After SpringDuration, unparent and recycle.
	record.motion:set(1)
	record.motion:forceStep()

	record.model.Parent = afterImagesFolder

	local effectTrove = record.effectTrove
	effectTrove:Clean()
	effectTrove:Add(task.spawn(function()
		task.wait(cfg.HoldTime)
		record.motion:set(0)
		record.motion:forceStep()

		task.wait(cfg.FadeOutTime)

		record.motion:spring(1, cfg.SpringParams)
		effectTrove:Add(task.delay(cfg.SpringDuration, function()
			record.model.Parent = nil
			record.inUse = false
			effectTrove:Clean()
		end))
	end))
end

-- =========================================================================
-- Public API
-- =========================================================================
function AfterImagesVFX.IsActive(): boolean
	return isActive
end

function AfterImagesVFX.SetRateMultiplier(mult: number?)
	runtimeRateMultiplier = mult
end

function AfterImagesVFX.Activate(trackChar: Model)
	if isActive then return end
	local cfg = TrackRunVFXConfig.AfterImages
	if not cfg.Enabled then return end
	if not trackChar or not trackChar.Parent then return end

	local templ = createCharacterTemplate(trackChar)
	if not templ then
		warn("[AfterImagesVFX] failed to build template from TrackChar")
		return
	end

	isActive = true
	activeTrackChar = trackChar
	startTime = os.clock()
	lastCreationTime = -math.huge

	trove = Trove.new()
	trove:Add(templ)

	table.clear(originalJointsMap)
	for _, j in ipairs(trackChar:GetDescendants()) do
		if j:IsA("Motor6D") then
			originalJointsMap[j.Name] = j
		end
	end

	local folder = workspace:FindFirstChild("AfterImages")
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "AfterImages"
		folder.Parent = workspace
	end
	afterImagesFolder = folder :: Folder
	trove:Add(function()
		if afterImagesFolder and afterImagesFolder.Parent then
			for _, child in ipairs(afterImagesFolder:GetChildren()) do
				child:Destroy()
			end
		end
	end)

	cloneCacheList = {}
	for _ = 1, cfg.CachedClones do
		table.insert(cloneCacheList, createCacheRecord(templ, trove))
	end

	-- Fixed-interval spawn loop (matches upstream Sandevistan repo).
	trove:Add(RunService.Heartbeat:Connect(function()
		if not isActive then return end
		local waitTime = getEffectiveSpawnInterval()
		local now = os.clock()
		if now - lastCreationTime < waitTime then return end
		lastCreationTime = now
		spawnAfterImage()
	end))
end

function AfterImagesVFX.Deactivate()
	if not isActive then return end
	isActive = false
	activeTrackChar = nil

	if trove then
		trove:Clean()
		trove = nil
	end
	cloneCacheList = {}
	table.clear(originalJointsMap)
	lastCreationTime = -math.huge

	if afterImagesFolder and afterImagesFolder.Parent then
		afterImagesFolder:Destroy()
	end
	afterImagesFolder = nil
end

return AfterImagesVFX
