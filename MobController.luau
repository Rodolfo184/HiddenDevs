--!strict
-- roblox Username: RodolfoDev, discord username: _.rodolfo
-- Connected Discord-GitHub
--[[
	MobController -- the server-side combat brain of one hostile mob.

	The AI Director owns the Heartbeat loop and creates one controller per
	live mob. It calls step() on the archetype's decision interval and
	steer() on its faster movement interval, so nothing here may yield: a
	hundred mobs share one tick.

	  * A finite state machine. Each state is a plain table tagged with its
	    name (Types.State is a tagged union) with enter / step / exit
	    handlers in the States table. A handler never switches state itself:
	    it RETURNS the next state and the dispatcher in step() runs exit and
	    enter, so every side effect of a change lives in one place. Handlers
	    narrow the union with `::` because the dispatcher already matched
	    the tag.
	  * A blackboard: memory that outlives state changes -- who the target
	    is, where it was last seen, how worked up the mob is (aggression)
	    and the timestamps that gate attacks and guards.
	  * Swings, blocks and parries run through CombatController, the same
	    code path players use, so a mob obeys the same reach, posture, parry
	    window and animation rules a player does.

	The Director is handed in through setDirector() instead of being
	required, because Director requires this module (a require cycle
	otherwise).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local CombatController = require(ReplicatedStorage.Modules.CombatController)
local Janitor = require(ReplicatedStorage.Modules.Icon.Packages.Janitor)
local Perception = require(ServerScriptService.Modules.AI.Perception)
local Types = require(ReplicatedStorage.Modules.AI.Types)

-- Tuning shared by every archetype. Per-mob numbers (reach, speeds, timings,
-- chances) live in the archetype config so designers can tune a mob without
-- touching this file.
local STALK_START_AGGRESSION = 0.5 -- fraction of engageThreshold on first sight
local STALK_RESET_AGGRESSION = 0.6 -- aggression is capped here after two whiffs
local FIRST_STRAFE_DELAY = 0.5 -- beat before the first sidestep, reads as noticing
local STRAFE_FLIP_CHANCE = 0.35 -- chance to reverse orbit direction per sidestep
local STRAFE_STEP = 3 -- studs to close or back off per sidestep
local STRAFE_SIDE_STEP = 2 -- lateral studs mixed into a close/back-off step
local STRAFE_ORBIT_STEP = 4 -- pure lateral studs when already at standoff
local STANDOFF_INNER_SLACK = 2 -- back off when closer than standoff - this
local STANDOFF_OUTER_SLACK = 3 -- close in when farther than standoff + this
local DEFEND_REACH_SLACK = 1 -- guards react a stud outside attack reach
local PARRY_HOLD = 0.3 -- how long a parry stays up after the telegraph
local DEFEND_COOLDOWN = 0.35 -- gap between reactive guards
local HOLD_BLOCK_CHECK_INTERVAL = 0.5 -- the hold-block roll runs at most 2x/s
local WHIFFS_BEFORE_RESET = 2 -- misses in a row before backing off to stalk
local SWING_ANIM_GRACE = 1 -- hard cap on waiting for a swing track to end
local WAYPOINT_REACHED_SQ = 4 -- 2 studs, squared (compared without a sqrt)
local FACE_EPSILON_SQ = 0.0004 -- 0.02 studs, squared: closer than this, don't aim

-- Combat states in which the rig keeps turning toward its target. AttackActive
-- is left out on purpose: the swing animation owns the rotation there.
local FACE_TARGET_STATES: { [Types.StateTag]: boolean } = table.freeze({
	Engaging = true,
	AttackWindup = true,
	Recovery = true,
	Defending = true,
})

local rng = Random.new()

local Controller = {}
Controller.__index = Controller

-- The slice of CombatController a mob touches. Typing the dependency
-- structurally keeps this file honest about what it uses and decoupled from
-- the combat module's internals.
type CombatHandle = {
	State: string,
	ActiveAttackTrack: AnimationTrack?,
	doM1: (self: CombatHandle, tool: Tool) -> (),
	doCrit: (self: CombatHandle, tool: Tool) -> (),
	doFistM1: (self: CombatHandle) -> (),
	guardPressed: (self: CombatHandle, tool: Tool) -> (),
	fistGuardPressed: (self: CombatHandle) -> (),
	guardReleased: (self: CombatHandle) -> (),
}

-- What the Director exposes back to a controller: the shared pathfinding
-- queue, and the per-target "swing slot" that stops a crowd of mobs from all
-- landing hits on the same player in the same instant.
type DirectorApi = {
	requestPath: (ctrl: Controller, from: Vector3, to: Vector3) -> (),
	clearPath: (ctrl: Controller) -> (),
	tryClaimSwingSlot: (target: Model, owner: Model, now: number, window: number) -> boolean,
}

type ControllerFields = {
	mob: Model,
	humanoid: Humanoid,
	hrp: BasePart,
	combat: CombatHandle,
	archetype: Types.ArchetypeConfig,
	director: DirectorApi,
	replicateState: boolean,
	blackboard: Types.Blackboard,
	state: Types.State,
	lastPercept: Types.PerceptionResult,
	guardRaised: boolean,
	-- scheduling, owned by the Director's tick loop
	nextDecisionAt: number,
	nextSteerAt: number,
	nextRepathAt: number,
	lastStepAt: number,
	-- the current path, filled in asynchronously by the Director
	waypoints: { PathWaypoint }?,
	waypointIdx: number,
	alive: boolean,
	janitor: typeof(Janitor.new()),
}

export type Controller = typeof(setmetatable({} :: ControllerFields, Controller))

-- enter and exit are optional so states without setup or teardown don't need
-- placeholder functions.
type Handlers = {
	enter: ((ctrl: Controller, state: Types.State, now: number) -> ())?,
	exit: ((ctrl: Controller, state: Types.State, now: number) -> ())?,
	step: (ctrl: Controller, state: Types.State, now: number, elapsed: number) -> Types.State,
}

local States: { [Types.StateTag]: Handlers } = {}

local director: DirectorApi? = nil

local function setDirector(api: DirectorApi)
	director = api
end

local function getEquippedTool(mob: Model): Tool?
	return mob:FindFirstChildOfClass("Tool")
end

local function rootPartOf(model: Model): BasePart?
	local root = model:FindFirstChild("HumanoidRootPart")
	return if root and root:IsA("BasePart") then root else nil
end

-- A target is only worth acting on while it is still in the world with a
-- living humanoid. Every state re-checks this because a player can die,
-- respawn or leave between two decision ticks.
local function liveTarget(ctrl: Controller): Model?
	local target = ctrl.blackboard.target
	if not target or not target.Parent then
		return nil
	end
	local humanoid = target:FindFirstChildWhichIsA("Humanoid")
	if not humanoid or humanoid.Health <= 0 then
		return nil
	end
	return target
end

local function liveTargetRoot(ctrl: Controller): (Model?, BasePart?)
	local target = liveTarget(ctrl)
	if not target then
		return nil, nil
	end
	return target, rootPartOf(target)
end

-- Squared distance: every reach test compares against a squared reach so the
-- hot path never pays for a square root.
local function distanceSq(a: Vector3, b: Vector3): number
	local delta = b - a
	return delta:Dot(delta)
end

-- Horizontal (XZ) offset from one point to another. Aiming, cone tests and
-- waypoint checks all ignore height on purpose: the rig only ever yaws (see
-- faceTowards), so measuring in the plane it turns in is what keeps the arc
-- test honest when a player stands on a ledge above or below the mob.
local function flatOffset(from: Vector3, to: Vector3): Vector3
	return Vector3.new(to.X - from.X, 0, to.Z - from.Z)
end

-- Which way to circle, chosen fresh each time stalking starts so the orbit
-- direction is not predictable.
local function pickStrafeDir(): number
	return if rng:NextInteger(0, 1) == 0 then 1 else -1
end

-- Guard calls run inside the shared Director tick, so a bug in one rig's
-- animation set must not abort every other mob's update for that frame:
-- fence it and report it instead of letting it propagate.
local function guarded(fn: () -> ())
	local ok, err = pcall(fn)
	if not ok then
		warn("[MobController]", err)
	end
end

-- Swinging flips on the moment a move begins (windup included) while State
-- only turns "attacking" once the swing itself starts; reading both gives the
-- earliest possible tell that a hit is coming.
local function isMidSwing(target: Model): boolean
	if target:GetAttribute("Swinging") == true then
		return true
	end
	local combat = CombatController.fromCharacter(target) :: CombatHandle?
	return combat ~= nil and combat.State == "attacking"
end

-- Locks the closest visible player into the blackboard and returns its
-- character, or nil when nothing is in view.
local function acquireVisibleTarget(ctrl: Controller, now: number): Model?
	local player = ctrl.lastPercept.closestVisible
	local character = if player then player.Character else nil
	local root = if character then rootPartOf(character) else nil
	if not character or not root then
		return nil
	end
	local bb = ctrl.blackboard
	bb.target = character
	bb.targetPlayer = player
	bb.lastSeen = now
	bb.lastKnownPos = root.Position
	return character
end

-- Refreshes the memory of where the target is, but only while the mob can
-- actually see it -- otherwise it would "know" where a hidden player went.
-- Returns whether the target was in view this tick.
local function refreshSighting(ctrl: Controller, root: BasePart, now: number): boolean
	local player = ctrl.blackboard.targetPlayer
	local seen = player ~= nil and table.find(ctrl.lastPercept.visible, player) ~= nil
	if seen then
		ctrl.blackboard.lastSeen = now
		ctrl.blackboard.lastKnownPos = root.Position
	end
	return seen
end

-- Transition builders. Each returns its concrete state type (a member of the
-- Types.State union), so the literal's tag is checked at the definition and
-- no handler has to spell the record out inline.
local function toIdle(): Types.StateIdle
	return { tag = "Idle" }
end

local function toEngaging(target: Model): Types.StateEngaging
	return { tag = "Engaging", target = target }
end

local function toStalking(target: Model, nextStrafeAt: number): Types.StateStalking
	return {
		tag = "Stalking",
		target = target,
		nextStrafeAt = nextStrafeAt,
		strafeDir = pickStrafeDir(),
	}
end

-- Head to `at` (default: wherever the target was last seen, else stay put) and
-- give up after the archetype's memory window.
local function toSearching(ctrl: Controller, now: number, at: Vector3?): Types.StateSearching
	return {
		tag = "Searching",
		lastKnown = at or ctrl.blackboard.lastKnownPos or ctrl.hrp.Position,
		endsAt = now + ctrl.archetype.memoryDuration,
	}
end

local function toAttackWindup(target: Model, endsAt: number): Types.StateAttackWindup
	return { tag = "AttackWindup", target = target, endsAt = endsAt }
end

local function toAttackActive(target: Model, endsAt: number): Types.StateAttackActive
	return { tag = "AttackActive", target = target, endsAt = endsAt, hitFired = false }
end

local function toDefending(raiseAt: number, endsAt: number, isParry: boolean): Types.StateDefending
	return { tag = "Defending", raiseAt = raiseAt, endsAt = endsAt, isParry = isParry }
end

local function toRecovery(ctrl: Controller, now: number, didHit: boolean): Types.StateRecovery
	return {
		tag = "Recovery",
		endsAt = now + ctrl.archetype.recoveryDuration,
		didHit = didHit,
	}
end

-- Where to step next while stalking: back off inside the standoff band, close
-- in outside it, otherwise orbit sideways. `side` is the XZ perpendicular of
-- the direction to the target, signed by the current orbit direction.
local function strafeGoal(ctrl: Controller, targetPos: Vector3, sign: number): Vector3
	local pos = ctrl.hrp.Position
	local standoff = ctrl.archetype.standoff
	local flat = flatOffset(pos, targetPos)
	local dist = flat.Magnitude
	local forward = if dist > 0.001 then flat / dist else Vector3.zAxis
	local side = Vector3.new(-forward.Z, 0, forward.X) * sign
	if dist < standoff - STANDOFF_INNER_SLACK then
		return pos - forward * STRAFE_STEP + side * STRAFE_SIDE_STEP
	end
	if dist > standoff + STANDOFF_OUTER_SLACK then
		return pos + forward * STRAFE_STEP + side * STRAFE_SIDE_STEP
	end
	return pos + side * STRAFE_ORBIT_STEP
end

-- Yaw-only cone test. The rig is aimed with a flat lookAt (its LookVector has
-- no pitch), so the arc has to be measured in the horizontal plane too:
-- dotting the full 3D offset would shrink the cosine whenever the player is
-- above or below, and fail the arc more the closer the mob gets.
local function inYawCone(hrp: BasePart, point: Vector3, halfArcRad: number): boolean
	local flat = flatOffset(hrp.Position, point)
	local cosine = flat:Dot(hrp.CFrame.LookVector) / math.max(flat.Magnitude, 1e-4)
	return cosine >= math.cos(halfArcRad)
end

-- Does the swing volume in front of the rig actually contain the target? The
-- box query is the most expensive geometric test here, so it runs last.
local function overlapsTarget(hrp: BasePart, arch: Types.ArchetypeConfig, target: Model): boolean
	local parts = Perception.overlapForward(hrp, arch.attackReach, arch.attackOverlapHalfWidth)
	for _, part in ipairs(parts) do
		if part:IsDescendantOf(target) then
			return true
		end
	end
	return false
end

-- Fists are always available; M1 and Crit are weapon swings, so the caller
-- has already made sure a tool is in hand before this runs.
local function performSwing(combat: CombatHandle, kind: Types.AttackKind, tool: Tool?)
	if kind == "Fist" then
		combat:doFistM1()
	elseif tool and kind == "Crit" then
		combat:doCrit(tool)
	elseif tool then
		combat:doM1(tool)
	end
end

--[[
	The moment of truth for an attack. Every check is a cheap reject before a
	more expensive one, so the raycast and the box overlap only run when the
	geometry already says a hit is plausible:
	  1. the mob can physically perform this attack kind (weapon in hand),
	  2. the target is alive, has a root part and is a player character,
	  3. it is inside reach and inside the yaw cone the rig is aiming in,
	  4. nothing solid is in the way -- a FRESH raycast; the perception
	     cache is fine for "can I see you" but too stale for "will I hit you",
	  5. the swing volume actually contains a part of the target,
	  6. the Director grants this mob the target's swing slot for the window.
	Returns true when a swing was started.
]]
local function tryFireSwing(ctrl: Controller, now: number): boolean
	local arch = ctrl.archetype
	local tool = getEquippedTool(ctrl.mob)
	if arch.attackKind ~= "Fist" and not tool then
		return false
	end
	local target, root = liveTargetRoot(ctrl)
	if not target or not root or not Players:GetPlayerFromCharacter(target) then
		return false
	end
	if distanceSq(ctrl.hrp.Position, root.Position) > arch.attackReach * arch.attackReach then
		return false
	end
	if not inYawCone(ctrl.hrp, root.Position, arch.attackArcHalfRad) then
		return false
	end
	if not Perception.losCheckFresh(ctrl.hrp, root) then
		return false
	end
	if not overlapsTarget(ctrl.hrp, arch, target) then
		return false
	end
	if not ctrl.director.tryClaimSwingSlot(target, ctrl.mob, now, arch.swingSlotWindow) then
		return false
	end
	-- doM1/doCrit yield while they wire up animation marker signals; a fresh
	-- thread lets that happen without stalling the Director's Heartbeat, and
	-- fences any error inside the swing away from every other mob's update.
	task.spawn(performSwing, ctrl.combat, arch.attackKind, tool)
	return true
end

--[[
	Reactive defence. When the target is mid-swing and close enough, choose
	between a parry (raised after a short, readable telegraph so the parry
	window lines up with the incoming hit) and a block (raised now, held for
	a random spell). Returns the Defending state to enter, or nil when the
	mob should carry on with what it was doing.
]]
local function tryReactiveGuard(
	ctrl: Controller,
	target: Model,
	distSq: number,
	now: number
): Types.StateDefending?
	local arch = ctrl.archetype
	if not (arch.canBlock or arch.canParry) or now < ctrl.blackboard.nextDefendReady then
		return nil
	end
	local reach = arch.attackReach + DEFEND_REACH_SLACK
	if distSq > reach * reach or not isMidSwing(target) then
		return nil
	end
	if arch.canParry and rng:NextNumber() < arch.parryChance then
		local raiseAt = now + arch.reactDelay
		return toDefending(raiseAt, raiseAt + PARRY_HOLD, true)
	end
	if arch.canBlock then
		local hold = rng:NextNumber(arch.blockTimeMin, arch.blockTimeMax)
		return toDefending(now, now + hold, false)
	end
	return nil
end

-- Occasionally raise a sustained guard while in range and uncommitted. The
-- roll is throttled so holdBlockChance keeps meaning "per half second" no
-- matter how short the archetype's decision interval is.
local function tryHoldBlock(ctrl: Controller, distSq: number, now: number): Types.StateDefending?
	local arch = ctrl.archetype
	local bb = ctrl.blackboard
	if not arch.canBlock or arch.holdBlockChance <= 0 then
		return nil
	end
	local reach = arch.attackReach + DEFEND_REACH_SLACK
	if now < bb.nextHoldBlockReady or now < bb.nextHoldBlockCheck or distSq > reach * reach then
		return nil
	end
	bb.nextHoldBlockCheck = now + HOLD_BLOCK_CHECK_INTERVAL
	if rng:NextNumber() >= arch.holdBlockChance then
		return nil
	end
	local hold = rng:NextNumber(arch.holdBlockMin, arch.holdBlockMax)
	return toDefending(now, now + hold, false)
end

-- Only ask the Director for a path when there is none, or when the target has
-- moved far enough from where the current path was aimed that following it
-- would walk the mob to empty ground. Pathfinding is the most expensive thing
-- a mob does; this and the Director's cooldown are what keep it rare.
local function requestPathIfStale(ctrl: Controller, from: Vector3, to: Vector3)
	local aimedAt = ctrl.blackboard.lastPathTarget
	local stale = ctrl.waypoints == nil
		or (aimedAt ~= nil and (aimedAt - to).Magnitude > ctrl.archetype.repathDistThreshold)
	if not stale then
		return
	end
	ctrl.director.requestPath(ctrl, from, to)
	ctrl.blackboard.lastPathTarget = to
end

-- Weapon and fist guards are different moves in CombatController, so pick by
-- what is in hand at the moment the guard comes up, not when it was decided.
local function raiseGuard(ctrl: Controller)
	local tool = getEquippedTool(ctrl.mob)
	guarded(function()
		if tool then
			ctrl.combat:guardPressed(tool)
		else
			ctrl.combat:fistGuardPressed()
		end
	end)
	ctrl.guardRaised = true
end

-- Planting (WalkSpeed 0, AutoRotate off) is how the windup and guard states
-- hold still while steer() keeps aiming the rig with CFrame -- AutoRotate
-- would fight that aim. Any pending path is dropped: the mob is committing
-- to this spot.
local function plant(ctrl: Controller)
	ctrl.humanoid.WalkSpeed = 0
	ctrl.humanoid.AutoRotate = false
	ctrl.director.clearPath(ctrl)
end

local function unplant(ctrl: Controller)
	ctrl.humanoid.WalkSpeed = ctrl.archetype.runSpeed
	ctrl.humanoid.AutoRotate = true
end

-- Yaw the rig toward a point without tilting it: the target's height is
-- discarded so a player on a ledge does not pitch the mob over. Skipped when
-- the mob is standing on the point -- lookAt has no defined heading for a
-- zero-length direction.
local function faceTowards(hrp: BasePart, point: Vector3)
	local flat = flatOffset(hrp.Position, point)
	if flat:Dot(flat) <= FACE_EPSILON_SQ then
		return
	end
	hrp.CFrame = CFrame.lookAt(hrp.Position, hrp.Position + flat)
end

-- Advance along the Director-supplied waypoints. A waypoint counts as reached
-- on horizontal distance only, so a step or slope under the mob never leaves
-- it circling a point it can not get "close enough" to. When the list runs
-- out the path is dropped and Engaging asks for a new one.
local function followPath(self: Controller)
	local waypoints = self.waypoints
	if not waypoints then
		return
	end
	local waypoint = waypoints[self.waypointIdx]
	if waypoint then
		local flat = flatOffset(self.hrp.Position, waypoint.Position)
		if flat:Dot(flat) < WAYPOINT_REACHED_SQ then
			self.waypointIdx += 1
			waypoint = waypoints[self.waypointIdx]
		end
	end
	if not waypoint then
		self.waypoints = nil
		return
	end
	self.humanoid:MoveTo(waypoint.Position)
end

--[[
	Idle: wander speed, waiting for perception to hand over a target. Seeing a
	player starts a stalk (or a straight engage for archetypes that don't
	stalk); merely hearing footsteps sends the mob to investigate the noise.
]]
States.Idle = {
	enter = function(ctrl)
		ctrl.humanoid.WalkSpeed = ctrl.archetype.walkSpeed
	end,
	step = function(ctrl, state, now)
		local target = acquireVisibleTarget(ctrl, now)
		if target and ctrl.archetype.useStalking then
			-- start part-way to the engage threshold: the mob is already
			-- interested, stalking only decides how quickly it commits
			ctrl.blackboard.aggression = ctrl.archetype.engageThreshold * STALK_START_AGGRESSION
			return toStalking(target, now + FIRST_STRAFE_DELAY)
		end
		if target then
			return toEngaging(target)
		end
		local heard = ctrl.lastPercept.heard
		if #heard > 0 then
			return toSearching(ctrl, now, heard[1])
		end
		return state
	end,
}

--[[
	Stalking: circle the player at standoff range while aggression builds.
	Aggression rises only while the mob can see its target and decays in
	step(), so a player who breaks line of sight cools the mob down again.
	Two whiffed swings also drop the mob back here (see Recovery), which is
	what makes a fight feel like probing rather than a wall of attacks.
]]
States.Stalking = {
	enter = function(ctrl)
		ctrl.humanoid.WalkSpeed = ctrl.archetype.walkSpeed
		ctrl.director.clearPath(ctrl)
	end,
	step = function(ctrl, state, now, elapsed)
		local arch = ctrl.archetype
		local target, root = liveTargetRoot(ctrl)
		if not target or not root then
			return toSearching(ctrl, now)
		end
		if refreshSighting(ctrl, root, now) then
			ctrl.blackboard.aggression += arch.aggressionPerSec * elapsed
		end
		if ctrl.blackboard.aggression >= arch.engageThreshold then
			return toEngaging(target)
		end
		-- the dispatcher matched the tag, so narrowing the union is safe here
		local stalking = state :: Types.StateStalking
		if now < stalking.nextStrafeAt then
			return state
		end
		stalking.nextStrafeAt = now + rng:NextNumber(arch.strafeIntervalLo, arch.strafeIntervalHi)
		if rng:NextNumber() < STRAFE_FLIP_CHANCE then
			stalking.strafeDir = -stalking.strafeDir
		end
		ctrl.humanoid:MoveTo(strafeGoal(ctrl, root.Position, stalking.strafeDir))
		return state
	end,
}

--[[
	Engaging: close in along a Director path and fight. The order of the
	checks is the priority order: reacting to an incoming swing beats starting
	our own, which beats the opportunistic hold-block, which beats re-pathing
	-- a mob that is about to be hit should not be asking for a new path.
]]
States.Engaging = {
	enter = function(ctrl)
		ctrl.humanoid.WalkSpeed = ctrl.archetype.runSpeed
	end,
	exit = function(ctrl)
		ctrl.director.clearPath(ctrl)
	end,
	step = function(ctrl, state, now)
		local arch = ctrl.archetype
		local target, root = liveTargetRoot(ctrl)
		if not target or not root then
			return toSearching(ctrl, now)
		end
		refreshSighting(ctrl, root, now)
		local pos = ctrl.hrp.Position
		local distSq = distanceSq(pos, root.Position)
		local reaction = tryReactiveGuard(ctrl, target, distSq, now)
		if reaction then
			return reaction
		end
		local inReach = distSq <= arch.attackReach * arch.attackReach
		if inReach and now >= ctrl.blackboard.nextAttackAt then
			return toAttackWindup(target, now + arch.windupDuration)
		end
		local holdBlock = tryHoldBlock(ctrl, distSq, now)
		if holdBlock then
			return holdBlock
		end
		requestPathIfStale(ctrl, pos, root.Position)
		return state
	end,
}

--[[
	AttackWindup: the telegraph. The mob plants so steer() can aim it precisely
	while the player still has a moment to react. Committing here rather than
	in Engaging is what gives every attack a readable start-up.
]]
States.AttackWindup = {
	enter = plant,
	exit = unplant,
	step = function(ctrl, state, now)
		if not liveTarget(ctrl) then
			return toRecovery(ctrl, now, false)
		end
		local windup = state :: Types.StateAttackWindup
		if now < windup.endsAt then
			return state
		end
		return toAttackActive(windup.target, now + ctrl.archetype.activeDuration)
	end,
}

--[[
	AttackActive: the one tick where the swing is attempted, then a hold until
	the swing animation really ends. Recovery's MoveTo would rotate the rig
	mid-animation and warp the swing arc, so the state waits for the track to
	clear -- with a hard cap in case a track never reports stopping.
]]
States.AttackActive = {
	step = function(ctrl, state, now)
		local active = state :: Types.StateAttackActive
		local bb = ctrl.blackboard
		if not active.hitFired then
			active.hitFired = true
			bb.nextAttackAt = now + ctrl.archetype.attackCooldown
			-- whiffs are counted so a mob that keeps missing backs off to
			-- stalk instead of swinging at air forever
			bb.whiffCount = if tryFireSwing(ctrl, now) then 0 else bb.whiffCount + 1
		end
		local trackDone = ctrl.combat.ActiveAttackTrack == nil
		local timedOut = now >= active.endsAt + SWING_ANIM_GRACE
		if (now >= active.endsAt and trackDone) or timedOut then
			return toRecovery(ctrl, now, bb.whiffCount == 0)
		end
		return state
	end,
}

--[[
	Recovery: the post-swing pause. steer() keeps the mob walking at the
	target during it, so the pause reads as follow-through, not freezing.
	When it ends, two misses in a row send a stalking archetype back to
	circling with its aggression trimmed; otherwise the mob re-engages.
]]
States.Recovery = {
	enter = function(ctrl)
		ctrl.humanoid.WalkSpeed = ctrl.archetype.walkSpeed
	end,
	step = function(ctrl, state, now)
		local recovery = state :: Types.StateRecovery
		if now < recovery.endsAt then
			return state
		end
		local target = liveTarget(ctrl)
		if not target then
			return toSearching(ctrl, now)
		end
		local arch = ctrl.archetype
		local bb = ctrl.blackboard
		if bb.whiffCount < WHIFFS_BEFORE_RESET then
			return toEngaging(target)
		end
		bb.whiffCount = 0
		if not arch.useStalking then
			return toEngaging(target)
		end
		bb.aggression = math.min(bb.aggression, arch.engageThreshold * STALK_RESET_AGGRESSION)
		return toStalking(target, now)
	end,
}

--[[
	Searching: walk to the last known position and look around. Anything seen
	on the way is engaged immediately (no stalking -- the mob was already
	committed). When the memory window runs out the blackboard is wiped and
	the mob returns to Idle.
]]
States.Searching = {
	enter = function(ctrl, state)
		local searching = state :: Types.StateSearching
		ctrl.humanoid.WalkSpeed = ctrl.archetype.walkSpeed
		ctrl.humanoid:MoveTo(searching.lastKnown)
	end,
	step = function(ctrl, state, now)
		local target = acquireVisibleTarget(ctrl, now)
		if target then
			return toEngaging(target)
		end
		local searching = state :: Types.StateSearching
		if now < searching.endsAt then
			return state
		end
		local bb = ctrl.blackboard
		bb.target = nil
		bb.targetPlayer = nil
		bb.lastKnownPos = nil
		bb.aggression = 0
		return toIdle()
	end,
}

--[[
	Defending: plant, keep facing the attacker (steer() does the turning) and
	raise the guard at raiseAt -- immediately for a block, after the telegraph
	for a parry -- then hold until endsAt. Raising and releasing go through
	CombatController so the guard has the same posture, parry window and
	animations as a player's. Both cooldowns are armed on exit so a mob can
	never chain guards back to back.
]]
States.Defending = {
	enter = function(ctrl)
		plant(ctrl)
		ctrl.guardRaised = false
	end,
	exit = function(ctrl, _state, now)
		if ctrl.guardRaised then
			guarded(function()
				ctrl.combat:guardReleased()
			end)
			ctrl.guardRaised = false
		end
		unplant(ctrl)
		ctrl.blackboard.nextDefendReady = now + DEFEND_COOLDOWN
		ctrl.blackboard.nextHoldBlockReady = now + ctrl.archetype.holdBlockCooldown
	end,
	step = function(ctrl, state, now)
		local target = liveTarget(ctrl)
		if not target then
			return toSearching(ctrl, now)
		end
		local defending = state :: Types.StateDefending
		if not ctrl.guardRaised and now >= defending.raiseAt then
			raiseGuard(ctrl)
		end
		if now >= defending.endsAt then
			return toEngaging(target)
		end
		return state
	end,
}

-- The one place a state change happens: the old state's exit, the new state's
-- enter, then the tag is mirrored for clients.
local function transition(self: Controller, from: Types.State, to: Types.State, now: number)
	local exit = States[from.tag].exit
	if exit then
		exit(self, from, now)
	end
	local enter = States[to.tag].enter
	if enter then
		enter(self, to, now)
	end
	if self.replicateState then
		-- attributes replicate only to clients streaming this mob, and a mob
		-- changes state a couple of times a second at most, so this is the
		-- cheapest downlink for client VFX and debug overlays
		self.humanoid:SetAttribute("AIState", to.tag)
	end
end

--[[
	Builds a controller for a rig, or returns nil when the rig is not
	combat-capable (no Humanoid or root part, or CombatController never
	registered it). replicateState mirrors the FSM tag to an attribute so
	clients can drive VFX and debug UI from it.
]]
function Controller.new(
	mob: Model,
	archetype: Types.ArchetypeConfig,
	replicateState: boolean
): Controller?
	local humanoid = mob:FindFirstChildWhichIsA("Humanoid")
	local root = rootPartOf(mob)
	-- narrow the registry lookup to the slice this module actually uses
	local combat = CombatController.fromCharacter(mob) :: CombatHandle?
	if not humanoid or not root or not combat then
		return nil
	end
	local api = assert(director, "MobController.setDirector must be called before new")

	-- The server must own the root's physics: MoveTo and the CFrame aiming in
	-- steer() are only authoritative for the owner, and a nearby client being
	-- handed ownership would fight every correction the AI makes.
	if root:CanSetNetworkOwnership() then
		root:SetNetworkOwner(nil)
	end

	local fields: ControllerFields = {
		mob = mob,
		humanoid = humanoid,
		hrp = root,
		combat = combat,
		archetype = archetype,
		director = api,
		replicateState = replicateState,
		blackboard = {
			lastSeen = 0,
			aggression = 0,
			whiffCount = 0,
			nextAttackAt = 0,
			pathCookie = 0,
			nextDefendReady = 0,
			nextHoldBlockReady = 0,
			nextHoldBlockCheck = 0,
		},
		state = toIdle(),
		lastPercept = Perception.newResult(),
		guardRaised = false,
		nextDecisionAt = 0,
		nextSteerAt = 0,
		nextRepathAt = 0,
		lastStepAt = os.clock(),
		waypointIdx = 1,
		alive = true,
		janitor = Janitor.new(),
	}
	local self = setmetatable(fields, Controller)
	if replicateState then
		humanoid:SetAttribute("AIState", "Idle")
	end

	-- Both ways a mob can stop existing funnel into destroy(); the Janitor
	-- owns the connections so destroy() can never leak them.
	self.janitor:Add(mob.Destroying:Connect(function()
		self:destroy()
	end))
	self.janitor:Add(humanoid.Died:Connect(function()
		self:destroy()
	end))
	return self
end

--[[
	One decision tick, called by the Director on the archetype's decision
	interval (or sooner, when the current state has a deadline). Memory upkeep
	runs first so every state sees a consistent blackboard: aggression cools,
	and a target that has been out of sight longer than the memory window is
	dropped -- but its last known position is kept so Searching still has
	somewhere to walk. Then perception, then the state handler, then the
	transition through the one choke point.
]]
function Controller.step(self: Controller, now: number, elapsed: number)
	if not self.alive then
		return
	end
	local arch = self.archetype
	local bb = self.blackboard
	if bb.aggression > 0 then
		bb.aggression = math.max(0, bb.aggression - arch.aggressionDecayPerSec * elapsed)
	end
	if bb.target and now - bb.lastSeen > arch.memoryDuration then
		bb.target = nil
		bb.targetPlayer = nil
	end
	-- the result table is handed back in and refilled, so perception in
	-- steady state allocates nothing per tick
	self.lastPercept = Perception.query(self.mob, self.hrp, arch, now, self.lastPercept)

	local current = self.state
	local nextState = States[current.tag].step(self, current, now, elapsed)
	if nextState.tag ~= current.tag then
		transition(self, current, nextState, now)
	end
	self.state = nextState
end

--[[
	Movement tick, run more often than step() and independently of it. Two
	jobs: keep the rig aimed at the target while fighting, and walk the
	current path one waypoint at a time. Aiming writes the root CFrame directly
	instead of relying on Humanoid AutoRotate: the windup and guard states
	switch AutoRotate off, and a MoveTo would turn the body along the path
	rather than at the target.
]]
function Controller.steer(self: Controller)
	if not self.alive then
		return
	end
	local tag = self.state.tag
	local target = self.blackboard.target
	local root = if target then rootPartOf(target) else nil
	if root and FACE_TARGET_STATES[tag] then
		faceTowards(self.hrp, root.Position)
	end
	if tag == "Recovery" and root then
		-- follow-through: keep pressing toward the target between swings
		self.humanoid:MoveTo(root.Position)
	elseif tag == "Engaging" then
		-- the only state that ever asks the Director for a path
		followPath(self)
	end
end

-- Idempotent teardown: the Director, the Destroying signal and Died can all
-- race to call it. Once alive is false the Director skips the controller and
-- drops it on its next tick.
function Controller.destroy(self: Controller)
	if not self.alive then
		return
	end
	self.alive = false
	Perception.dropCacheFor(self.mob)
	self.janitor:Destroy()
	self.waypoints = nil
end

local MobController = {
	new = Controller.new,
	setDirector = setDirector,
}

return MobController
