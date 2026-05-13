# TrackChar Porting Spec — RaceThroughTime

**Audience:** A code-generation agent (Claude Opus) tasked with porting the
client-side `TrackChar` system from the **vfx_effects** test bed into the
production repository **`AZ9tumas/RaceThroughTime`** without regressing any
existing gameplay system (pets, stars, laps, world unlocks, data persistence,
multiplayer presentation, anti-exploit).

This document is the contract. Follow it to the letter. Do not invent
behaviour outside what is specified here. When in doubt, prefer the
**most conservative change** that satisfies the spec.

---

## 1. Why

The current production track-run loop attaches `AlignPosition` and
`AlignOrientation` to the **original** player character's
`HumanoidRootPart` and drives motion on the **client**, with the server
holding canonical kinematic parameters. The original character runs on
the actual track. The physical movement is capped at
`Stats.MaxPhysicalSpeed = 105` because higher values produce engine artefacts
(joint stretching, collision pop, network-owner desync, parts shearing off the
humanoid rig, jittery camera follow).

The product goal is to **uncap perceived speed**. To do that we need
`CanCollide = false`, `Massless = true`, and full body-mover control over
all three axes — but applying that to the *real* character would break
unrelated systems (pet welds, ragdoll, animations, character-touching
gameplay, replication of player position to other clients for the
spectator world, leaderboards / laps which rely on real character position).

The solution is a **client-only proxy character (`TrackChar`)** that is a
visual clone of the player. The real character stays anchored at the
arena centre throughout the run. The client camera, body movers, and
visual VFX follow `TrackChar`. Server logic remains the authority for
kinematics, fuel consumption, distance, rewards, and world unlocks.

---

## 2. Glossary

| Term | Meaning |
| --- | --- |
| **OriginalChar** | `player.Character` — the real, server-owned character. |
| **TrackChar** | Client-only `Model` cloned from OriginalChar at run start, parented to `workspace`, destroyed at run end. Never exists on the server. |
| **HRP** | `HumanoidRootPart`. |
| **Track surface Y** (`gateY`) | The world-space Y at which gate ground sits. Server computes it from `Track_Gates.Gate_*` part positions. |
| **`hrpToBottom`** | Distance from TrackChar HRP centre Y to the bottom of TrackChar's bounding box. Computed once at clone time via `Model:GetBoundingBox()`. |
| **`ClientTrackY`** | `gateY + hrpToBottom`. The Y the body movers should drive HRP to so the visual feet sit on track surface. |
| **`SetupTrackCharRun`** / **`TeardownTrackCharRun`** | Client lifecycle functions. |

---

## 3. Architectural contract

### 3.1. Authority split (anti-exploit)

| Concern | Owner | Rationale |
| --- | --- | --- |
| Track start eligibility (fuel, gate proximity, world ownership, debounce) | **Server** | Already enforced. Do not change. |
| Kinematic parameters (`initialSpeed`, `acceleration`, `maxSpeed`, `rampDuration`, `postRampAcceleration`, `totalTime`, `totalDistance`) | **Server** | Sent once via `TrackStarted` signal. |
| Run start time (`trackData.startTime`) | **Server** | Used by `EstimateDistanceTraveled` for VFX threshold checks and world-unlock checks. |
| Per-frame distance integration for VFX / world-unlock | **Server** | Already done by `EstimateDistanceTraveled` in heartbeat loop. **Never** read a client-written `NumberValue` for security-critical decisions. |
| `MaxDistanceTraveled` stat persistence, cash rewards, world unlock | **Server** | At `RequestTrackEnd`, server clamps `distanceTraveled` to `trackData.totalDistance`; never trust the raw client value. |
| TrackChar instantiation, body-mover control, camera | **Client** | Pure presentation. |
| Local hiding of OriginalChar | **Client** | `LocalTransparencyModifier` does not replicate, so other clients still see the real player at their spawn. |
| Anchoring OriginalChar's HRP locally so VFX (`Trail`, `CyberpunkAura`) follow TrackChar | **Client** | `Anchored` on a client is local-only; server's view of OriginalChar is unaffected. |
| Pet position during run | **Server** sends initial signal, **Client** drives same way as today | Pets must follow TrackChar visually but their server-side body movers stay where they are. See §6.3. |
| Lap percentage in `ReplicatedStorage.PlayerLaps` | **Server** (`LapService`) | Unchanged — already derived purely from server kinematics. |

**Hard rule:** No reward, distance, lap, or unlock decision may depend on
*any* client-supplied number that exceeds the analytical maximum derived
from the server-issued kinematic parameters. The existing 10% tolerance
clamp in `RequestTrackEnd` already enforces this; keep it.

### 3.2. Network surface (signals & remote functions)

Only one wire-format change is required:

* `TrackService.Client.TrackStarted` payload must include the new field
  `gateY: number` (the raw track surface Y). Existing field
  `trackY: number` stays for backwards compatibility but is no longer
  consumed by the new client renderer.

Everything else stays as-is: `TrackEnded`, `Overdrive`,
`EarlyWorldUnlock`, `RequestTrackStart`, `RequestTrackEnd`,
`CancelTrackRun`, `RequestOverdrive`.

### 3.3. Replication ground rules

* `TrackChar` is **never** parented on the server. It lives only in
  `workspace` on the local client. Other clients will not see it.
* OriginalChar stays at the arena centre on the server. Other clients
  see the real character idling at spawn — this is the intentional
  multiplayer-presentation trade-off for this iteration. (A future
  iteration may server-replicate TrackChar via a streamed accessory
  model; out of scope here.)

---

## 4. Implementation plan

Follow these steps in order. Each step is independently verifiable.

### Step 1 — Add `gateY` to the `TrackStarted` payload

**File:** `src/ServerScriptService/Services/TrackService.luau`

In `RequestTrackStart`, the block that fires `TrackStarted`:

```lua
TrackService.Client.TrackStarted:Fire(player, {
    -- … existing fields …
    trackCenter = center,
    trackY = trackY,
    gateY = gateY,                     -- ADD THIS LINE
    maxPhysicalSpeed = Stats.MaxPhysicalSpeed,
    -- … existing fields …
})
```

`gateY` is already computed earlier in `RequestTrackStart` via
`GetGateGroundY(worldName)`. Just propagate it.

### Step 2 — Require the body-movers template on the client

**File:** `src/StarterPlayer/StarterPlayerScripts/Controllers/TrackController.luau`

Near the existing top-of-file requires, add:

```lua
local BodyMoversTemplate = ReplicatedStorage:WaitForChild("Assets"):WaitForChild("BodyMovers")
```

The server already requires this same template. The client uses
`BodyMoversTemplate.AlignPosition:Clone()` and
`BodyMoversTemplate.AlignOrientation:Clone()` so the constraint
configuration (MaxForce, MaxVelocity, RigidityEnabled, Responsiveness,
Mode) lives in one editor-managed place. Do **not** hard-code these
properties — read them from the template clones.

### Step 3 — Add TrackChar state to the controller

In the controller's private state block, add:

```lua
local TrackChar: Model? = nil
local TrackCharHRP: BasePart? = nil
local TrackCharYOffset: number = 0
local OriginalHRPWasAnchored: boolean = false
local OriginalLocalTransparencies: { [BasePart]: number } = {}
local ClientTrackY: number = 0
```

### Step 4 — Add TrackChar helper functions

Insert these helper functions in the controller, between
`UpdateCircularPosition` and the existing fire/smoke section (i.e. after
the world-helper section).

```lua
local function HideOriginalCharacterLocally(character: Model)
    OriginalLocalTransparencies = {}
    for _, d in character:GetDescendants() do
        if d:IsA("BasePart") then
            OriginalLocalTransparencies[d] = d.LocalTransparencyModifier
            d.LocalTransparencyModifier = 1
        end
    end
end

local function ShowOriginalCharacterLocally()
    for part, t in pairs(OriginalLocalTransparencies) do
        if part and part.Parent then
            part.LocalTransparencyModifier = t
        end
    end
    OriginalLocalTransparencies = {}
end

local function BuildTrackChar(original: Model): (Model?, BasePart?, number)
    local clone = original:Clone()
    clone.Name = "TrackChar"

    -- Strip embedded scripts so nothing fights us.
    for _, d in clone:GetDescendants() do
        if d:IsA("BaseScript") then d:Destroy() end
    end

    local hum = clone:FindFirstChildOfClass("Humanoid")
    if hum then
        -- Disable every state so the engine can't override AlignPosition.
        for _, state in {
            Enum.HumanoidStateType.Climbing,
            Enum.HumanoidStateType.FallingDown,
            Enum.HumanoidStateType.Freefall,
            Enum.HumanoidStateType.GettingUp,
            Enum.HumanoidStateType.Jumping,
            Enum.HumanoidStateType.Landed,
            Enum.HumanoidStateType.Ragdoll,
            Enum.HumanoidStateType.Running,
            Enum.HumanoidStateType.RunningNoPhysics,
            Enum.HumanoidStateType.Seated,
            Enum.HumanoidStateType.StrafingNoPhysics,
            Enum.HumanoidStateType.Swimming,
        } do
            hum:SetStateEnabled(state, false)
        end
        hum:ChangeState(Enum.HumanoidStateType.Physics)
        hum.PlatformStand = true
        hum.AutoRotate = false
        hum.WalkSpeed = 0
        hum.JumpPower = 0
    end

    -- Non-colliding, massless parts — physics engine cannot brake the rig.
    for _, d in clone:GetDescendants() do
        if d:IsA("BasePart") then
            d.CanCollide = false
            d.CanQuery = false
            d.CanTouch = false
            d.Massless = true
        end
    end

    clone.Parent = workspace

    local hrp = clone:FindFirstChild("HumanoidRootPart") :: BasePart?
    if not hrp then
        clone:Destroy()
        return nil, nil, 0
    end

    -- Bounding-box-based offset works for R6, R15, custom rigs.
    local cf, size = clone:GetBoundingBox()
    local bottomY = cf.Y - size.Y / 2
    local hrpToBottom = hrp.Position.Y - bottomY

    return clone, hrp, hrpToBottom
end

local function AttachBodyMoversTo(hrp: BasePart)
    local attachment = Instance.new("Attachment")
    attachment.Name = "TrackAttachment"
    attachment.Parent = hrp

    local alignPos = BodyMoversTemplate.AlignPosition:Clone()
    alignPos.Attachment0 = attachment
    alignPos.Position = hrp.Position
    alignPos.Parent = hrp

    local alignOri = BodyMoversTemplate.AlignOrientation:Clone()
    alignOri.Attachment0 = attachment
    alignOri.CFrame = hrp.CFrame
    alignOri.Parent = hrp
end

local function SetupTrackCharRun(originalChar: Model, trackData: any)
    local originalHRP = originalChar:FindFirstChild("HumanoidRootPart")
    if not originalHRP or not originalHRP:IsA("BasePart") then return end

    local clone, cloneHRP, hrpToBottom = BuildTrackChar(originalChar)
    if not clone or not cloneHRP then return end

    TrackChar = clone
    TrackCharHRP = cloneHRP
    TrackCharYOffset = hrpToBottom

    -- Client-side trackY = gate ground + bounding-box HRP offset.
    -- Fall back to (trackY - hrpToBottom) if a server is old enough to
    -- not have shipped gateY yet (defensive only; remove after rollout).
    local gateY = trackData.gateY or (trackData.trackY - hrpToBottom)
    ClientTrackY = gateY + hrpToBottom

    -- Visual continuity: seed at the original's current CFrame.
    cloneHRP.CFrame = (originalHRP :: BasePart).CFrame

    AttachBodyMoversTo(cloneHRP)

    -- Anchor the OriginalChar HRP locally. Two effects:
    --   1. Body movers attached server-side to the original HRP cannot
    --      drag it around.
    --   2. We can rewrite its CFrame each renderstep so the trail / aura
    --      VFX, which are parented to the original, follow TrackChar.
    OriginalHRPWasAnchored = (originalHRP :: BasePart).Anchored
    ;(originalHRP :: BasePart).Anchored = true

    HideOriginalCharacterLocally(originalChar)

    local camera = workspace.CurrentCamera
    local cloneHum = clone:FindFirstChildOfClass("Humanoid")
    if camera then
        camera.CameraType = Enum.CameraType.Custom
        camera.CameraSubject = cloneHum or cloneHRP
    end
end

local function TeardownTrackCharRun()
    ShowOriginalCharacterLocally()

    local originalChar = player.Character
    local originalHRP = originalChar and originalChar:FindFirstChild("HumanoidRootPart")
    if originalHRP and originalHRP:IsA("BasePart") then
        (originalHRP :: BasePart).Anchored = OriginalHRPWasAnchored
    end

    if TrackChar then
        TrackChar:Destroy()
    end
    TrackChar = nil
    TrackCharHRP = nil
    TrackCharYOffset = 0
    ClientTrackY = 0
end
```

### Step 5 — Call `SetupTrackCharRun` in `OnTrackStarted`

Right after the existing `BlackScreenTransition.Play(...)` call and
before the FOV tween:

```lua
local originalChar = player.Character
if originalChar then
    SetupTrackCharRun(originalChar, trackData)
end
```

### Step 6 — Redirect the render-step body movers to TrackChar

In the existing `RunService:BindToRenderStep(RENDER_STEP_BINDING, …)`
loop:

**6a.** At the top of the loop body, replace the OriginalChar lookup:

```lua
-- BEFORE
local character = player.Character
if not character then return end
local rootPart = character:FindFirstChild("HumanoidRootPart")
if not rootPart or not rootPart:IsA("BasePart") then return end

local radius = TrackData.worldRadius
local center = TrackData.trackCenter
local trackY = TrackData.trackY
```

with:

```lua
-- AFTER
if not TrackCharHRP or not TrackCharHRP.Parent then return end
local originalChar = player.Character
local originalHRP = originalChar and originalChar:FindFirstChild("HumanoidRootPart")

local radius = TrackData.worldRadius
local center = TrackData.trackCenter
local trackY = ClientTrackY
```

**6b.** **Delete** the block that writes the client-reported distance
to `rootPart.TrackDistanceTraveled`:

```lua
-- REMOVE
local distanceValue = rootPart:FindFirstChild("TrackDistanceTraveled")
if distanceValue and distanceValue:IsA("NumberValue") then
    distanceValue.Value = DistanceTraveled
end
```

The server already runs `EstimateDistanceTraveled` (analytical
integration of its own kinematic parameters) and never needed this
NumberValue. Removing it eliminates an exploit surface where a client
could write arbitrary values.

**6c.** Replace the final body-mover write block:

```lua
-- BEFORE
local targetCFrame, targetPosition = UpdateCircularPosition(center, radius, CurrentAngle, trackY)
local alignPos = rootPart:FindFirstChild("AlignPosition")
local alignOri = rootPart:FindFirstChild("AlignOrientation")
if alignPos then alignPos.Position = targetPosition end
if alignOri then alignOri.CFrame = targetCFrame end
```

with:

```lua
-- AFTER
local targetCFrame, targetPosition = UpdateCircularPosition(center, radius, CurrentAngle, trackY)
local alignPos = TrackCharHRP:FindFirstChild("AlignPosition")
local alignOri = TrackCharHRP:FindFirstChild("AlignOrientation")
if alignPos then (alignPos :: AlignPosition).Position = targetPosition end
if alignOri then (alignOri :: AlignOrientation).CFrame = targetCFrame end

-- Mirror to original HRP (anchored, local-only) so Trail / Aura VFX
-- attached server-side to the original character follow visually.
if originalHRP and originalHRP:IsA("BasePart") then
    (originalHRP :: BasePart).CFrame = targetCFrame
end
```

### Step 7 — Call `TeardownTrackCharRun` in `OnTrackEnded`

Add the teardown call **before** `ResetCamera()` so the camera reset
falls back to OriginalChar's humanoid:

```lua
task.spawn(function() WormHoleVFX.Deactivate() end)
TeardownTrackCharRun()    -- ADD THIS
ResetCamera()
```

Also call `TeardownTrackCharRun()` from `TrackController:StopTrack()`
(the public hard-stop API) so any external caller gets the same cleanup.

### Step 8 — Server-side `SetupBodyMoversForPlayer` & `TrackDistanceTraveled`

Keep `SetupBodyMoversForPlayer(player)` in `RequestTrackStart`. The
constraints will sit idle on the anchored OriginalChar HRP and cause no
movement, but:

* They preserve the cleanup path (`CleanupBodyMovers` deletes them).
* They make TrackChar / non-TrackChar code paths interoperable during
  the rollout phase.

**Delete** the `TrackDistanceTraveled` NumberValue creation block —
nothing reads it any more. Also remove the cleanup in
`CleanupBodyMovers` that destroys it. Search the repo for any other
reader; there should be none after this change.

### Step 9 — Pets

`PetController` already follows the player's HRP. With OriginalChar
HRP anchored at the arena centre and rewritten each frame to
TrackChar's CFrame, the pet follow code automatically works
unchanged.

**Verification step:** confirm `PetController:SetOnTrack(true)` does
not branch on `Humanoid.MoveDirection` or similar, since those are
zero on an anchored rig.

If pet body movers (`SetupPetBodyMoversForTrack`) are attached
server-side to pet HRPs and driven by the client today, leave that
code path intact. The pets continue to follow `targetCFrame` exactly
as today — TrackChar does not affect them.

### Step 10 — Camera fallback after WormHole

`WormHoleVFX.Deactivate()` already restores
`workspace.CurrentCamera.CameraSubject` to `player.Character.Humanoid`
(OriginalChar). Because `OnTrackEnded` calls `TeardownTrackCharRun()`
**before** `ResetCamera()`, the `Camera.CameraSubject` is correctly
pointed at the original humanoid by the end of the frame.

Verify there is no race: `WormHoleVFX.Deactivate()` runs in a
`task.spawn`. If the player wormholes and the run ends before the
deactivate task completes, the deactivate task's
`CameraSubject = humanoid` write may run after `ResetCamera()` — both
target OriginalChar's humanoid, so the result is identical.

### Step 11 — Cancel / Skip / EarlyWorldUnlock paths

* `CancelTrackRun` (client → server → `TrackEnded` fired) flows through
  the same `OnTrackEnded` handler. TrackChar teardown happens there.
* `SkipWorld` / `RequestTrackEnd(worldUnlocked=true)` — same handler.
* `EarlyWorldUnlock` — server fires `TrackEnded` after teleporting the
  player. The `Character` reference may briefly be `nil` on the new
  world. `TeardownTrackCharRun()` guards every access with `nil`
  checks; ensure that remains true when integrating.

### Step 12 — Server-side spawn teleport

In `EndTrackRun` / `CancelTrackRun` the server teleports OriginalChar's
HRP via `rootPart.CFrame = spawnCFrame`. Because the client anchored
OriginalChar HRP locally during the run, the server's CFrame write
**will** replicate the new spawn position because by then the client
has already called `TeardownTrackCharRun()` which restored
`originalHRP.Anchored = OriginalHRPWasAnchored` (typically `false`).
Order of operations in production today:

1. Server `EndTrackRun`: teleports HRP, then fires `TrackEnded`.
2. Client receives `TrackEnded`: runs `OnTrackEnded` →
   `TeardownTrackCharRun()`.

⚠️ With the new flow, step 1's CFrame write hits the still-anchored
HRP on the client. The local Anchored=true means the server's CFrame
replication writes the new position normally (replicated CFrames on
anchored parts still apply — anchored only stops physics simulation).
Verify in Studio that the player ends up at the spawn after a run.

If a discrepancy appears, change ordering server-side: fire `TrackEnded`
first, `task.wait()` a frame, then teleport. Document the choice in
the PR.

---

## 5. Testing checklist

Run each of these in Studio with the production place file. Each
checkbox is a hard requirement before merging.

* [ ] Press the run button next to a gate → black screen plays →
      TrackChar appears at the gate, original character invisible
      locally.
* [ ] Camera follows TrackChar smoothly through laps.
* [ ] Trail VFX appears at the configured distance threshold and
      visibly follows TrackChar (not floating at spawn).
* [ ] CyberpunkAura emitters appear at the configured threshold and
      track TrackChar body parts.
* [ ] Wormhole camera activation, lap boost, deactivation all behave
      identically to the pre-TrackChar build.
* [ ] On run end (natural, cancel, skip, early unlock): TrackChar is
      destroyed, original character becomes visible, camera resnaps
      to original humanoid.
* [ ] Pets follow TrackChar visually during the run and reset to
      OriginalChar after.
* [ ] Cash rewards, `MaxDistanceTraveled` updates, world unlocks
      match the pre-TrackChar build for the same fuel / multipliers.
* [ ] `Stats.MaxPhysicalSpeed` can be raised to e.g. `500` and the
      run remains smooth — no joint stretching, no camera judder.
      (This is the product win that motivated the work.)
* [ ] Open a second client and verify the first client's player is
      rendered idle at the arena centre during their run — multiplayer
      presentation is intentionally idle for this iteration; document
      this.
* [ ] Exploit dry-run: try editing the `DistanceTraveled` local in
      the client controller to a giant number — `RequestTrackEnd` still
      clamps to `trackData.totalDistance` and rewards are correct.
* [ ] Exploit dry-run: try deleting TrackChar mid-run — render-step
      `if not TrackCharHRP or not TrackCharHRP.Parent then return end`
      guards prevent errors; server still ends the run on time.

---

## 6. Items that are explicitly out of scope

Do not include the following in the same PR:

1. **Server-replicated TrackChar.** A future PR may explore streaming a
   slim TrackChar accessory to other clients so spectators see the
   visual run. For now: client-only.
2. **Removing `Stats.MaxPhysicalSpeed`.** Keep the cap configurable so
   designers can tune. The TrackChar PR only unlocks the *capability*
   to raise it; do not change its current value.
3. **Refactoring pet logic.** Pets follow the OriginalChar HRP today;
   anchored + mirrored CFrame keeps them working unchanged.
4. **Removing the legacy AlignPosition setup on the OriginalChar HRP.**
   It is now inert but should remain until a follow-up cleanup PR.

---

## 7. Files expected to change

| File | Change |
| --- | --- |
| `src/ServerScriptService/Services/TrackService.luau` | Add `gateY` to `TrackStarted` payload. Remove `TrackDistanceTraveled` NumberValue creation (and matching cleanup in `CleanupBodyMovers`). |
| `src/StarterPlayer/StarterPlayerScripts/Controllers/TrackController.luau` | Add BodyMovers require, TrackChar state, TrackChar helpers, integrate into `OnTrackStarted` / `OnTrackEnded` / `StopTrack`, redirect render-step body movers to TrackCharHRP, mirror to OriginalChar HRP, remove client-side `TrackDistanceTraveled` writes. |

No other files require changes for this PR.

---

## 8. PR description template (use this verbatim)

```
TrackChar: client-only proxy character for high-speed track runs

Why
---
MaxPhysicalSpeed is capped at 105 because driving the real character
faster produces joint stretching / collision pop / network desync.
This PR introduces a client-only clone (TrackChar) that the body
movers drive. With CanCollide=false, Massless=true, and full body-
mover control over all three axes, the rig is immune to physics
artefacts and the cap can be raised without rewriting the run loop.

What
----
* Client clones the player character into `workspace.TrackChar` on
  TrackStarted, attaches AlignPosition/AlignOrientation cloned from
  ReplicatedStorage.Assets.BodyMovers.
* OriginalChar HRP is anchored locally (LocalTransparencyModifier
  hides the real character on this client only); each render-step
  the client mirrors TrackChar's CFrame to OriginalChar HRP so
  server-attached VFX (Trail, CyberpunkAura) follow visually.
* Y-axis offset is derived from Model:GetBoundingBox() so the rig
  bottom sits exactly on track surface for R6, R15, and custom rigs.
* On TrackEnded / cancel / early unlock: TrackChar is destroyed,
  OriginalChar is unhidden and unanchored, camera resnaps to original.

Anti-exploit
------------
* Server distance is analytical (EstimateDistanceTraveled) and is the
  only source of truth for VFX thresholds, world unlocks, and rewards.
* Removed the `rootPart.TrackDistanceTraveled` NumberValue surface
  entirely — nothing reads it.
* RequestTrackEnd still clamps client-supplied distance to
  trackData.totalDistance with the existing 10 % tolerance log.

Multiplayer
-----------
* TrackChar is client-only and is not replicated. Other clients see
  the runner's original character idling at the arena centre during
  the run. Replicating TrackChar is a follow-up.
```

---

## 9. Reference: identical implementation in vfx_effects test bed

The vfx_effects workspace (`/Users/az9umas/Desktop/vfx_effects`) ships a
working, build-clean reference of this design:

* [src/StarterPlayer/StarterPlayerScripts/Controllers/TrackController.luau](src/StarterPlayer/StarterPlayerScripts/Controllers/TrackController.luau)
  — search for `TrackChar`, `BuildTrackChar`, `SetupTrackCharRun`,
  `TeardownTrackCharRun`.
* [src/ServerScriptService/Services/TrackService.luau](src/ServerScriptService/Services/TrackService.luau)
  — see the `gateY` field in the `TrackStarted` payload and the
  `EstimateDistanceTraveled` heartbeat loop.

The vfx_effects build hardcodes fuel and player max distance for
isolated VFX testing; ignore those constants when porting and use the
production fuel / DataService values that already exist in
RaceThroughTime.
