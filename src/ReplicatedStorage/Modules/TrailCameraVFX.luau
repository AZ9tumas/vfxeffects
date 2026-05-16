--!strict
--[[
	TrailCameraVFX (client) — cinematic four-phase camera sequence that plays
	when the Trail VFX activates during a track run.

	Design notes for future maintainers
	-----------------------------------
	The default in-run camera (driven by TrackController) hugs the
	TrackChar's tangent vector, producing an immersive third-person view.
	When this module is active it OWNS the camera instead: TrackController
	checks `TrailCameraVFX.IsActive()` and skips its per-frame CFrame write,
	letting this module drive `workspace.CurrentCamera` through four
	scripted, named phases.

	The module deliberately does NOT mutate the existing CurrentCamera — it
	spawns its own scriptable `TrailVFXCamera`, seeds it with the previous
	camera's CFrame for visual continuity, then swaps `CurrentCamera` over.
	This mirrors the pattern used by `WormHoleVFX` and keeps responsibilities
	separated: each camera-owning system gets its own Camera instance and
	can be reasoned about / debugged independently.

	Phases (all durations configurable in TrackRunVFXConfig):
	  1. InitialCameraTurn   — Camera stays put but rotates so its LookVector
	                           matches the direction from the arena centre
	                           toward the TrackChar (it appears to "turn its
	                           head" away from the tangent to face the runner).
	  2. ReverseToCenter     — Camera dollies backward to the arena centre
	                           (XZ collapsed to centre, Y preserved) while
	                           continuing to look at the TrackChar.
	  3. FaceDown            — Camera holds position at the arena centre and
	                           rotates to look straight down.
	  4. AscendReverse       — Camera "reverses" along its own +LookVector
	                           (since LookVector points straight down, the
	                           world-space motion is straight up), revealing
	                           the full arena/track from above.
	  5. ReturnToCharacter   — (Triggered explicitly via RunReturnPhase, used
	                           right before WormHoleVFX takes over.) Camera
	                           interpolates from wherever phase 4 left it back
	                           to the in-run third-person tangent offset
	                           (right next to the runner), mirroring the intro
	                           in reverse.

	A subtle continuous shake (TrackRunVFXConfig.GetContinuousRunShakeCFrame)
	is multiplied onto the final camera CFrame every frame so the shake is
	preserved across all phases.

	All phase transitions use eased CFrame interpolation; each new phase
	captures the actual end-CFrame of the previous phase so the sequence is
	robust to frame-time jitter.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local TrackRunVFXConfig = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("TrackRunVFXConfig"))

local TrailCameraVFX = {}

-- =========================================================================
-- Phase identifiers — kept as a frozen table so other modules / debug tools
-- can reference phases without typo-prone string literals.
-- =========================================================================
local Phase = table.freeze({
	InitialCameraTurn  = "InitialCameraTurn",
	ReverseToCenter    = "ReverseToCenter",
	FaceDown           = "FaceDown",
	AscendReverse      = "AscendReverse",
	ReturnToCharacter  = "ReturnToCharacter",
	Finished           = "Finished",
})
TrailCameraVFX.Phase = Phase

-- =========================================================================
-- Internal state
-- =========================================================================
local isActive: boolean = false
local renderBound: boolean = false
local trailCamera: Camera? = nil
local previousCamera: Camera? = nil

local trackCharHRP: BasePart? = nil
local arenaCenter: Vector3 = Vector3.zero

-- Per-phase bookkeeping
local currentPhase: string = Phase.InitialCameraTurn
local phaseElapsed: number = 0
local phaseStartCFrame: CFrame = CFrame.new()   -- camera CFrame at the moment the active phase began
local phaseStartPosition: Vector3 = Vector3.zero -- convenience alias of phaseStartCFrame.Position
local ascendStartY: number = 0                  -- world Y captured at start of phase 4 for distance maths

-- BindableEvent used to signal completion of the ReturnToCharacter phase
-- so that RunReturnPhase() can yield until the cinematic actually finishes.
local returnPhaseCompleted: BindableEvent? = nil

-- =========================================================================
-- Helpers
-- =========================================================================

-- Smooth ease-in-out curve (cosine-based). Cheap and dependency-free.
local function easeInOut(alpha: number): number
	local t = math.clamp(alpha, 0, 1)
	return 0.5 - 0.5 * math.cos(t * math.pi)
end

local function getCharacterPosition(): Vector3?
	if trackCharHRP and trackCharHRP.Parent then
		return trackCharHRP.Position
	end
	return nil
end

-- Builds a CFrame positioned at `pos` whose LookVector points from the
-- arena centre toward the TrackChar. Used during phase 1 / phase 2 so the
-- camera tracks the runner even as the runner continues along the track.
local function lookAtCharFromCentre(pos: Vector3): CFrame
	local charPos = getCharacterPosition()
	if not charPos then
		return CFrame.new(pos)
	end
	local dir = (charPos - arenaCenter)
	if dir.Magnitude < 1e-4 then
		-- Degenerate: char is exactly at centre. Fall back to look-at char.
		return CFrame.new(pos, charPos + Vector3.new(0, 0, 1))
	end
	return CFrame.lookAt(pos, pos + dir.Unit)
end

-- Phase transition: snap bookkeeping to whatever the current camera CFrame
-- ACTUALLY is (vs. what we planned for it). This protects the next phase
-- from frame-time error and keeps motion continuous.
local function beginPhase(nextPhase: string)
	currentPhase = nextPhase
	phaseElapsed = 0
	local cam = trailCamera
	if cam then
		phaseStartCFrame = cam.CFrame
		phaseStartPosition = phaseStartCFrame.Position
	end
	if nextPhase == Phase.AscendReverse then
		ascendStartY = phaseStartPosition.Y
	end
end

-- =========================================================================
-- Phase 1: InitialCameraTurn
-- Hold position; rotate from the original (tangent-facing) orientation to
-- one whose LookVector matches the centre→character ray.
-- =========================================================================
local function updateInitialCameraTurn(dt: number): boolean
	local duration = TrackRunVFXConfig.TrailCameraInitialTurnPeriod
	phaseElapsed = phaseElapsed + dt
	local alpha = easeInOut(phaseElapsed / math.max(duration, 1e-4))

	local cam = trailCamera
	if not cam then return true end

	local targetCFrame = lookAtCharFromCentre(phaseStartPosition)
	cam.CFrame = phaseStartCFrame:Lerp(targetCFrame, alpha)

	return phaseElapsed >= duration
end

-- =========================================================================
-- Phase 2: ReverseToCenter
-- Dolly the camera from its phase-1 position to (centre.X, originalY, centre.Z)
-- while continuing to face the runner.
-- =========================================================================
local function updateReverseToCenter(dt: number): boolean
	local duration = TrackRunVFXConfig.TrailCameraReverseToCenterPeriod
	phaseElapsed = phaseElapsed + dt
	local alpha = easeInOut(phaseElapsed / math.max(duration, 1e-4))

	local cam = trailCamera
	if not cam then return true end

	local endPos = Vector3.new(arenaCenter.X, phaseStartPosition.Y, arenaCenter.Z)
	local pos = phaseStartPosition:Lerp(endPos, alpha)
	cam.CFrame = lookAtCharFromCentre(pos)

	return phaseElapsed >= duration
end

-- =========================================================================
-- Phase 3: FaceDown
-- Rotate the camera in place from "looking at runner" to "looking straight
-- down". Position is locked to whatever phase 2 left us at.
-- =========================================================================
local function updateFaceDown(dt: number): boolean
	local duration = TrackRunVFXConfig.TrailCameraFaceDownPeriod
	phaseElapsed = phaseElapsed + dt
	local alpha = easeInOut(phaseElapsed / math.max(duration, 1e-4))

	local cam = trailCamera
	if not cam then return true end

	-- Use a right-vector hint to avoid lookAt going degenerate when the
	-- look direction is colinear with the world up vector.
	local downTarget = CFrame.lookAt(
		phaseStartPosition,
		phaseStartPosition + Vector3.new(0, -1, 0),
		Vector3.new(0, 0, -1)
	)
	cam.CFrame = phaseStartCFrame:Lerp(downTarget, alpha)

	return phaseElapsed >= duration
end

-- =========================================================================
-- Phase 4: AscendReverse
-- Camera is now facing straight down. "Reversing" means moving along
-- -LookVector, which in world space is straight up. Final phase — at the
-- end we simply leave the camera at its high vantage point until something
-- external (track end, wormhole, etc.) tears us down.
-- =========================================================================
local function updateAscendReverse(dt: number): boolean
	local duration = TrackRunVFXConfig.TrailCameraAscendPeriod
	phaseElapsed = phaseElapsed + dt
	local alpha = easeInOut(phaseElapsed / math.max(duration, 1e-4))

	local cam = trailCamera
	if not cam then return true end

	local rise = TrackRunVFXConfig.TrailCameraAscendDistance * alpha
	local newPos = Vector3.new(phaseStartPosition.X, ascendStartY + rise, phaseStartPosition.Z)

	-- Preserve the face-down orientation captured at phase start.
	local rot = phaseStartCFrame - phaseStartCFrame.Position
	cam.CFrame = rot + newPos

	return phaseElapsed >= duration
end

-- =========================================================================
-- Phase 5 (explicit-trigger): ReturnToCharacter
-- Interpolates from wherever phase 4 (or whichever phase was active) left
-- the camera back to the in-run third-person tangent offset. Used as the
-- "pre-wormhole" camera lead-in so the wormhole always activates from the
-- familiar chase pose. Target is recomputed every frame from the live HRP
-- CFrame so the camera lands cleanly even as the runner continues moving.
-- =========================================================================
local function computeTangentOffsetCFrame(): CFrame?
	local hrp = trackCharHRP
	if not hrp or not hrp.Parent then return nil end
	local height = TrackRunVFXConfig.TrackCameraHeight
	local back = TrackRunVFXConfig.TrackCameraBack
	-- HRP.CFrame.LookVector is kept tangential by the body-mover AlignOrientation.
	return CFrame.new(hrp.Position, hrp.Position + hrp.CFrame.LookVector) * CFrame.new(0, height, back)
end

local function updateReturnToCharacter(dt: number): boolean
	local duration = TrackRunVFXConfig.TrailCameraReturnPeriod
	phaseElapsed = phaseElapsed + dt
	local alpha = easeInOut(phaseElapsed / math.max(duration, 1e-4))

	local cam = trailCamera
	if not cam then return true end

	local target = computeTangentOffsetCFrame()
	if not target then
		-- HRP gone; bail out of the phase rather than freezing.
		return true
	end
	cam.CFrame = phaseStartCFrame:Lerp(target, alpha)

	return phaseElapsed >= duration
end

-- =========================================================================
-- RenderStep driver
-- =========================================================================
local function onRenderStep(dt: number)
	if not isActive then return end
	local cam = trailCamera
	if not cam or not cam.Parent then
		TrailCameraVFX.Deactivate()
		return
	end

	-- Re-assert ownership in case something else swapped CurrentCamera.
	if workspace.CurrentCamera ~= cam then
		workspace.CurrentCamera = cam
	end

	local phaseDone = false
	if currentPhase == Phase.InitialCameraTurn then
		phaseDone = updateInitialCameraTurn(dt)
		if phaseDone then beginPhase(Phase.ReverseToCenter) end
	elseif currentPhase == Phase.ReverseToCenter then
		phaseDone = updateReverseToCenter(dt)
		if phaseDone then beginPhase(Phase.FaceDown) end
	elseif currentPhase == Phase.FaceDown then
		phaseDone = updateFaceDown(dt)
		if phaseDone then beginPhase(Phase.AscendReverse) end
	elseif currentPhase == Phase.AscendReverse then
		phaseDone = updateAscendReverse(dt)
		if phaseDone then currentPhase = Phase.Finished end
	elseif currentPhase == Phase.ReturnToCharacter then
		phaseDone = updateReturnToCharacter(dt)
		if phaseDone then
			currentPhase = Phase.Finished
			if returnPhaseCompleted then
				returnPhaseCompleted:Fire()
			end
		end
	end

	-- Continuous subtle shake applied on TOP of the phase's CFrame write.
	-- Multiplying in LOCAL space keeps the shake oriented to the camera so
	-- the same constants feel right whether the camera is looking forward,
	-- straight down, or anywhere in between.
	cam.CFrame = cam.CFrame * TrackRunVFXConfig.GetContinuousRunShakeCFrame(tick())
end

-- =========================================================================
-- Public API
-- =========================================================================

--[[
	Activate(hrp, centerPosition)
	  hrp            — the BasePart representing the TrackChar's root.
	                   Used to compute the centre→character look direction.
	  centerPosition — world position of the arena/map centre. Phase-2 dolly
	                   target and phase-1 / phase-2 look-direction anchor.

	The new TrailVFXCamera is seeded with the OUTGOING camera's exact CFrame,
	so the visual hand-off is continuous (no jerk / pop).
]]
function TrailCameraVFX.Activate(hrp: BasePart, centerPosition: Vector3)
	if isActive then return end

	local outgoing = workspace.CurrentCamera
	if not outgoing then
		warn("[TrailCameraVFX] No CurrentCamera at activation; aborting.")
		return
	end

	trackCharHRP = hrp
	arenaCenter = centerPosition
	previousCamera = outgoing

	local cam = Instance.new("Camera")
	cam.Name = "TrailVFXCamera"
	cam.CameraType = Enum.CameraType.Scriptable
	cam.FieldOfView = outgoing.FieldOfView
	cam.CFrame = outgoing.CFrame -- visual continuity: start exactly where the previous camera left off
	cam.Parent = workspace
	trailCamera = cam

	workspace.CurrentCamera = cam

	currentPhase = Phase.InitialCameraTurn
	phaseElapsed = 0
	phaseStartCFrame = cam.CFrame
	phaseStartPosition = phaseStartCFrame.Position

	isActive = true
	RunService:BindToRenderStep(
		"TrailCameraVFX_Drive",
		Enum.RenderPriority.Camera.Value + 2, -- run after TrackController's binding so we win the frame
		onRenderStep
	)
	renderBound = true
end

function TrailCameraVFX.Deactivate()
	if not isActive then return end
	isActive = false

	if renderBound then
		pcall(function()
			RunService:UnbindFromRenderStep("TrailCameraVFX_Drive")
		end)
		renderBound = false
	end

	if returnPhaseCompleted then
		-- Fire any pending waiters so they don't hang if Deactivate races
		-- with an in-progress RunReturnPhase() call.
		returnPhaseCompleted:Fire()
		returnPhaseCompleted:Destroy()
		returnPhaseCompleted = nil
	end

	if trailCamera then
		trailCamera:Destroy()
	end
	trailCamera = nil

	-- Intentionally do NOT touch workspace.CurrentCamera here. The caller
	-- (TrackController.OnTrackEnded → ResetCamera, or WormHoleVFX.Activate)
	-- owns the next camera transition and will assign CurrentCamera itself.
	-- Doing it here would race with those teardown paths.

	trackCharHRP = nil
	previousCamera = nil
	currentPhase = Phase.Finished
end

--[[
	RunReturnPhase()
	  Switches the active phase to ReturnToCharacter and YIELDS the calling
	  thread until the interpolation completes. Designed to be called right
	  before WormHoleVFX.Activate so the camera arrives back at the runner
	  with the in-run tangent offset, giving the wormhole a clean hand-off.

	  No-op (returns immediately) if the module is not active.
]]
function TrailCameraVFX.RunReturnPhase()
	if not isActive then return end

	-- Reset / create the completion event so multiple invocations don't
	-- inherit a previously-fired state.
	if returnPhaseCompleted then
		returnPhaseCompleted:Destroy()
	end
	returnPhaseCompleted = Instance.new("BindableEvent")

	beginPhase(Phase.ReturnToCharacter)
	returnPhaseCompleted.Event:Wait()
end

function TrailCameraVFX.IsActive(): boolean
	return isActive
end

function TrailCameraVFX.GetCurrentPhase(): string
	return currentPhase
end

return TrailCameraVFX
