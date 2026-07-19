--!strict
-- roblox Username: RodolfoDev, discord username: _.rodolfo
-- Connected Discord-GitHub

-- this module drives a single mob's ai loop: perception in, a small state machine in the
-- middle, humanoid movement out. it is instantiated once per mob and ticked externally by
-- a director script that owns the heartbeat and batches all mobs' step/steer calls together

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local ServerScriptService = game:GetService("ServerScriptService")

-- Root references for consistent, replication-safe indexing
local Modules = ReplicatedStorage:WaitForChild("Modules")
local AIServiceModules = ServerScriptService:WaitForChild("Modules"):WaitForChild("AI")

local Types = require(AIServiceModules:WaitForChild("Types"))
local Perception = require(AIServiceModules:WaitForChild("Perception"))
local CombatController = require(Modules:WaitForChild("CombatController"))
local Janitor = require(Modules:WaitForChild("Icon"):WaitForChild("Packages"):WaitForChild("Janitor"))

-- Export explicit types for strict typing mode definitions
export type Blackboard = {
	target: Model?,
	targetPlayer: Player?,
	lastSeen: number,
	lastKnownPos: Vector3?,
	aggression: number,
	whiffCount: number,
	nextAttackAt: number,
	pathCookie: number,
	lastPathTarget: Vector3?,
}

export type StateTable = {
	tag: string,
	target: Model?,
	nextStrafeAt: number?,
	strafeDir: number?,
	lastKnown: Vector3?,
	endsAt: number?,
	didHit: boolean?,
	hitFired: boolean?,
}

export type ControllerType = {
	mob: Model,
	humanoid: Humanoid,
	hrp: BasePart,
	combat: any,
	archetype: any,
	replicateState: boolean,
	blackboard: Blackboard,
	state: StateTable,
	lastPercept: any,
	nextDecisionAt: number,
	nextSteerAt: number,
	nextRepathAt: number,
	lastStepAt: number,
	waypoints: table?,
	waypointIdx: number,
	isAlive: boolean,
	janitor: any,
	setupJanitor: (self: any) -> (),
	decayAggression: (self: any, elapsed: number) -> (),
	expireStaleTarget: (self: any, now: number) -> (),
	runStateMachine: (self: any, now: number, elapsed: number) -> (),
	step: (self: any, now: number, elapsed: number) -> (),
	updateFacing: (self: any, tag: string, thrp: BasePart?) -> (),
	followTargetDuringRecovery: (self: any, thrp: BasePart?) -> (),
	followWaypoints: (self: any) -> (),
	steer: (self: any, now: number) -> (),
	destroy: (self: any) -> (),
}

local Director: any = nil
local function setDirector(d: any)
	Director = d
end

local Controller = {}
Controller.__index = Controller

local States: { [string]: { enter: (ctrl: any, s: any) -> (), exit: (ctrl: any, s: any) -> (), step: (ctrl: any, s: any, now: number, elapsed: number?) -> StateTable } } = {}

local function getEquippedTool(mob: Model): Tool?
	-- mobs only ever hold one tool at a time, so the first one we find is the equipped one
	for _, c in ipairs(mob:GetChildren()) do
		if c:IsA("Tool") then
			return c
		end
	end
	return nil
end

local function precondM1(mob: Model): boolean
	return getEquippedTool(mob) ~= nil
end

local function precondCrit(mob: Model): boolean
	return getEquippedTool(mob) ~= nil
end

local function precondFist(_mob: Model): boolean
	-- fist attacks never require a tool, so this archetype can always throw one
	return true
end

-- table-driven instead of an if/elseif chain, so adding a new attack kind later is a one-line
-- addition here rather than a new branch threaded through every place attacks are checked
local ATTACK_PRECONDITION = table.freeze({
	M1 = precondM1,
	Crit = precondCrit,
	Fist = precondFist,
})

local function dispatchM1(combat: any, mob: Model)
	local tool = getEquippedTool(mob)
	if tool then
		pcall(combat.doM1, combat, tool)
	end
end

local function dispatchCrit(combat: any, mob: Model)
	local tool = getEquippedTool(mob)
	if tool then
		pcall(combat.doCrit, combat, tool)
	end
end

local function dispatchFist(combat: any, _mob: Model)
	pcall(combat.doFistM1, combat)
end

-- mirrors ATTACK_PRECONDITION: same table-driven approach so precondition and dispatch for a
-- given attack kind stay next to each other conceptually, even though they live in two tables
local ATTACK_DISPATCH = table.freeze({
	M1 = dispatchM1,
	Crit = dispatchCrit,
	Fist = dispatchFist,
})

local function targetHrp(ctrl: ControllerType): BasePart?
	local t = ctrl.blackboard.target
	if not t or not t.Parent then
		return nil
	end
	local h = t:FindFirstChild("HumanoidRootPart")
	return (h and h:IsA("BasePart")) and h or nil
end

local function isTargetAlive(target: Model?): boolean
	if not target or not target.Parent then
		return false
	end
	local h = target:FindFirstChildWhichIsA("Humanoid")
	return h ~= nil and h.Health > 0
end

local function distSq(a: Vector3, b: Vector3): number
	-- squared distance avoids a sqrt call on every comparison; callers only need it for
	-- threshold checks, so the square root is never actually needed
	local dx, dy, dz = a.X - b.X, a.Y - b.Y, a.Z - b.Z
	return dx * dx + dy * dy + dz * dz
end

local function isVisible(p: any, pl: Player?): boolean
	if not p or not pl then
		return false
	end
	for i = 1, #p.visible do
		if p.visible[i] == pl then
			return true
		end
	end
	return false
end

local function pickStrafeDir(): number
	-- just a coin flip between orbiting left or right around the target
	return if math.random() > 0.5 then 1 else -1
end

local function setAIState(ctrl: ControllerType, tag: string)
	-- this attribute is what clients read to drive animations and debug visuals, so it's only
	-- written for mobs flagged as replicated. writing it for every mob regardless of whether
	-- anyone is watching would be wasted replication traffic, capped here at roughly
	-- two transitions per second per mob by virtue of how rarely states actually change
	if ctrl.replicateState then
		ctrl.humanoid:SetAttribute("AIState", tag)
	end
end

local function extractVisibleTarget(percept: any): (Model?, Player?)
	-- pulls a usable character + player pair out of whatever perception decided is the
	-- closest visible player this tick. returns nil, nil if there's nothing usable yet,
	-- so callers can treat "no target found" as a single early-return case
	if not percept or not percept.closestVisible then
		return nil, nil
	end
	local player = percept.closestVisible
	local char = player.Character
	if not char then
		return nil, nil
	end
	local hrp = char:FindFirstChild("HumanoidRootPart")
	if not hrp or not hrp:IsA("BasePart") then
		return nil, nil
	end
	return char, player
end

local function computeStrafeGoal(originPos: Vector3, targetPos: Vector3, standoff: number, strafeDir: number): Vector3
	-- works out a flat (xz-only) direction toward the target so strafing stays grounded
	-- instead of drifting up or down with any height difference between mob and target
	local towardX, towardZ = targetPos.X - originPos.X, targetPos.Z - originPos.Z
	local dist = math.sqrt(towardX * towardX + towardZ * towardZ)
	local forwardX = if dist > 0.001 then towardX / dist else 0
	local forwardZ = if dist > 0.001 then towardZ / dist else 1
	-- the sideways strafe direction is just the forward vector rotated ninety degrees
	local rightX, rightZ = -forwardZ, forwardX

	if dist < standoff - 2 then
		-- currently too close, so bias the step backward while still strafing sideways,
		-- which opens the gap back up without the mob looking like it's fleeing outright
		return originPos + Vector3.new(-forwardX * 3 + rightX * strafeDir * 2, 0, -forwardZ * 3 + rightZ * strafeDir * 2)
	end

	if dist > standoff + 3 then
		-- too far, so bias the step forward instead, closing the gap while still circling
		return originPos + Vector3.new(forwardX * 3 + rightX * strafeDir * 2, 0, forwardZ * 3 + rightZ * strafeDir * 2)
	end

	-- already sitting at a comfortable range, so just orbit sideways around the target
	return originPos + Vector3.new(rightX * strafeDir * 4, 0, rightZ * strafeDir * 4)
end

local function tryFireSwing(ctrl: ControllerType, now: number): boolean
	-- runs every gate an attack has to clear, in cheapest-first order, so a mob that fails
	-- an early cheap check (like simply not having a weapon) never pays for the expensive
	-- raycast and overlap checks further down
	local arch = ctrl.archetype
	local kind = arch.attackKind
	local precond = ATTACK_PRECONDITION[kind]
	if not precond or not precond(ctrl.mob) then
		return false
	end

	local target = ctrl.blackboard.target
	if not isTargetAlive(target) then
		return false
	end
	local thrp = (target :: Model):FindFirstChild("HumanoidRootPart")
	if not thrp or not thrp:IsA("BasePart") then
		return false
	end
	if not Players:GetPlayerFromCharacter(target) then
		return false
	end

	local pos = ctrl.hrp.Position
	local tx, ty, tz = thrp.Position.X - pos.X, thrp.Position.Y - pos.Y, thrp.Position.Z - pos.Z
	local d2 = tx * tx + ty * ty + tz * tz
	if d2 > arch.attackReach * arch.attackReach then
		return false
	end

	-- reject targets outside the attack's forward arc so a mob can't land a hit on
	-- someone standing behind it, even if they're technically within reach
	local f = ctrl.hrp.CFrame.LookVector
	local invD = 1 / math.sqrt(d2)
	if (tx * f.X + ty * f.Y + tz * f.Z) * invD < math.cos(arch.attackArcHalfRad) then
		return false
	end

	-- a fresh raycast here, rather than trusting the cached perception line-of-sight, because
	-- the perception cache has a ttl and can go stale enough at the moment of committing to a
	-- swing that a target who has since ducked behind cover would otherwise still get hit
	if not Perception.losCheckFresh(ctrl.hrp, thrp) then
		return false
	end

	local parts = Perception.overlapForward(ctrl.hrp, arch.attackReach, arch.attackOverlapHalfWidth)
	local overlapped = false
	for i = 1, #parts do
		if parts[i]:IsDescendantOf(target) then
			overlapped = true
			break
		end
	end
	if not overlapped then
		return false
	end

	-- multiple mobs can be swinging at the same target on the same tick, so we claim an
	-- exclusive slot on the target before actually firing, preventing two mobs from both
	-- landing a hit within the same short window and effectively double-hitting the player
	if not Director.tryClaimSwingSlot(target, ctrl.mob, now, arch.swingSlotWindow) then
		return false
	end

	local fire = ATTACK_DISPATCH[kind]
	if not fire then
		return false
	end
	-- doM1/doCrit yield internally while setting up hit markers, so this is spawned off
	-- rather than called inline, keeping that yield isolated from the director's heartbeat
	task.spawn(fire, ctrl.combat, ctrl.mob)
	return true
end

States.Idle = {
	enter = function(ctrl: ControllerType)
		ctrl.humanoid.WalkSpeed = ctrl.archetype.walkSpeed
	end,
	exit = function() end,
	step = function(ctrl: ControllerType, s: StateTable, now: number): StateTable
		local char, player = extractVisibleTarget(ctrl.lastPercept)
		if char and player then
			local hrp = char:FindFirstChild("HumanoidRootPart") :: BasePart
			ctrl.blackboard.target = char
			ctrl.blackboard.targetPlayer = player
			ctrl.blackboard.lastSeen = now
			ctrl.blackboard.lastKnownPos = hrp.Position

			if ctrl.archetype.useStalking then
				-- start at half the engage threshold rather than zero, so a stalking mob still
				-- needs a few seconds of sustained visibility before committing to a fight,
				-- instead of instantly deciding to attack the moment it spots someone
				ctrl.blackboard.aggression = ctrl.archetype.engageThreshold * 0.5
				return {
					tag = "Stalking",
					target = char,
					nextStrafeAt = now + 0.5,
					strafeDir = pickStrafeDir(),
				}
			end

			return { tag = "Engaging", target = char }
		end

		local p = ctrl.lastPercept
		if p and #p.heard > 0 then
			-- couldn't see anyone, but heard something: go investigate the noise
			return {
				tag = "Searching",
				lastKnown = p.heard[1],
				endsAt = now + ctrl.archetype.memoryDuration,
			}
		end

		return s
	end,
}

States.Stalking = {
	enter = function(ctrl: ControllerType)
		ctrl.humanoid.WalkSpeed = ctrl.archetype.walkSpeed
		Director.clearPath(ctrl)
	end,
	exit = function() end,
	step = function(ctrl: ControllerType, s: StateTable, now: number, elapsed: number?): StateTable
		local arch = ctrl.archetype
		local thrp = targetHrp(ctrl)
		if not thrp or not isTargetAlive(ctrl.blackboard.target) then
			return {
				tag = "Searching",
				lastKnown = ctrl.blackboard.lastKnownPos or ctrl.hrp.Position,
				endsAt = now + arch.memoryDuration,
			}
		end

		if isVisible(ctrl.lastPercept, ctrl.blackboard.targetPlayer) then
			ctrl.blackboard.lastSeen = now
			ctrl.blackboard.lastKnownPos = thrp.Position
			-- aggression only builds while the target is actually visible, so a mob that's
			-- stalking someone who ducks out of sight stops closing in on the decision to engage
			ctrl.blackboard.aggression += arch.aggressionPerSec * (elapsed or 0)
		end

		if ctrl.blackboard.aggression >= arch.engageThreshold then
			return { tag = "Engaging", target = ctrl.blackboard.target }
		end

		local ss = s
		if now < (ss.nextStrafeAt or 0) then
			return s
		end

		-- time to pick the next strafe move; the next one is scheduled somewhere inside the
		-- configured interval window so the movement doesn't fall into an obvious, repeating rhythm
		ss.nextStrafeAt = now + (arch.strafeIntervalLo + math.random() * (arch.strafeIntervalHi - arch.strafeIntervalLo))
		if math.random() < 0.35 then
			-- occasionally reverse orbit direction so the strafing reads as deliberate
			-- circling rather than a mob stuck looping the same path around the target
			ss.strafeDir = -(ss.strafeDir or 1)
		end

		local goal = computeStrafeGoal(ctrl.hrp.Position, thrp.Position, arch.standoff, ss.strafeDir or 1)
		ctrl.humanoid:MoveTo(goal)
		return s
	end,
}

States.Engaging = {
	enter = function(ctrl: ControllerType)
		ctrl.humanoid.WalkSpeed = ctrl.archetype.runSpeed
	end,
	exit = function(ctrl: ControllerType)
		Director.clearPath(ctrl)
	end,
	step = function(ctrl: ControllerType, s: StateTable, now: number): StateTable
		local arch = ctrl.archetype
		local thrp = targetHrp(ctrl)
		if not thrp or not isTargetAlive(ctrl.blackboard.target) then
			return {
				tag = "Searching",
				lastKnown = ctrl.blackboard.lastKnownPos or ctrl.hrp.Position,
				endsAt = now + arch.memoryDuration,
			}
		end

		if isVisible(ctrl.lastPercept, ctrl.blackboard.targetPlayer) then
			ctrl.blackboard.lastSeen = now
			ctrl.blackboard.lastKnownPos = thrp.Position
		end

		local pos = ctrl.hrp.Position
		local d2 = distSq(pos, thrp.Position)

		if d2 <= arch.attackReach * arch.attackReach and now >= ctrl.blackboard.nextAttackAt then
			return {
				tag = "AttackWindup",
				target = ctrl.blackboard.target,
				endsAt = now + arch.windupDuration,
			}
		end

		-- only ask for a new path if we don't have one yet, or the target has moved far enough
		-- that the existing path no longer leads anywhere close to them. repathing on every
		-- small target movement would be both wasteful and cause visibly jittery navigation
		local lt = ctrl.blackboard.lastPathTarget
		local needsRepath = (not ctrl.waypoints) or (lt ~= nil and (lt - thrp.Position).Magnitude > arch.repathDistThreshold)
		if needsRepath then
			Director.requestPath(ctrl, pos, thrp.Position)
			ctrl.blackboard.lastPathTarget = thrp.Position
		end

		return s
	end,
}

States.AttackWindup = {
	enter = function(ctrl: ControllerType)
		ctrl.humanoid.WalkSpeed = 0
		ctrl.humanoid.AutoRotate = false
		Director.clearPath(ctrl)
	end,
	exit = function(ctrl: ControllerType)
		ctrl.humanoid.WalkSpeed = ctrl.archetype.runSpeed
		ctrl.humanoid.AutoRotate = true
	end,
	step = function(ctrl: ControllerType, s: StateTable, now: number): StateTable
		local arch = ctrl.archetype
		if not isTargetAlive(ctrl.blackboard.target) then
			-- target died mid-windup, so skip straight to recovery without ever landing a hit
			return { tag = "Recovery", endsAt = now + arch.recoveryDuration, didHit = false }
		end

		local sw = s
		if now >= (sw.endsAt or 0) then
			return {
				tag = "AttackActive",
				target = sw.target,
				endsAt = now + arch.activeDuration,
				hitFired = false,
			}
		end

		return s
	end,
}

States.AttackActive = {
	enter = function() end,
	exit = function() end,
	step = function(ctrl: ControllerType, s: StateTable, now: number): StateTable
		local arch = ctrl.archetype
		local sa = s
		if not sa.hitFired then
			sa.hitFired = true
			local swingFired = tryFireSwing(ctrl, now)
			ctrl.blackboard.nextAttackAt = now + arch.attackCooldown
			if swingFired then
				ctrl.blackboard.whiffCount = 0
			else
				-- tracked separately from a landed hit, so recovery can decide to back off
				-- and re-stalk after enough consecutive whiffs instead of endlessly re-engaging
				ctrl.blackboard.whiffCount += 1
			end
		end

		-- stay in AttackActive until the swing animation genuinely finishes; letting Recovery's
		-- MoveTo start early would rotate the rig mid-swing and visibly warp the attack's arc
		-- the 1s hard cap exists purely as a safety net in case a track never reports as done
		local trackDone = ctrl.combat.ActiveAttackTrack == nil
		if (now >= (sa.endsAt or 0) and trackDone) or now >= (sa.endsAt or 0) + 1.0 then
			return { tag = "Recovery", endsAt = now + arch.recoveryDuration, didHit = sa.hitFired }
		end

		return s
	end,
}

States.Recovery = {
	enter = function(ctrl: ControllerType)
		ctrl.humanoid.WalkSpeed = ctrl.archetype.walkSpeed
	end,
	exit = function() end,
	step = function(ctrl: ControllerType, s: StateTable, now: number): StateTable
		local sr = s
		if now < (sr.endsAt or 0) then
			return s
		end

		local arch = ctrl.archetype
		local tgt = ctrl.blackboard.target
		if not isTargetAlive(tgt) then
			return {
				tag = "Searching",
				lastKnown = ctrl.blackboard.lastKnownPos or ctrl.hrp.Position,
				endsAt = now + arch.memoryDuration,
			}
		end

		if ctrl.blackboard.whiffCount >= 2 and arch.useStalking then
			-- two whiffs in a row suggests the mob is chasing something it can't actually
			-- land hits on, so back off into stalking rather than repeatedly swinging at air
			ctrl.blackboard.whiffCount = 0
			ctrl.blackboard.aggression = math.min(ctrl.blackboard.aggression, arch.engageThreshold * 0.6)
			return {
				tag = "Stalking",
				target = tgt,
				nextStrafeAt = now,
				strafeDir = pickStrafeDir(),
			}
		end

		return { tag = "Engaging", target = tgt }
	end,
}

States.Searching = {
	enter = function(ctrl: ControllerType, s: StateTable)
		local ss = s
		ctrl.humanoid.WalkSpeed = ctrl.archetype.walkSpeed
		if ss.lastKnown then
			ctrl.humanoid:MoveTo(ss.lastKnown)
		end
	end,
	exit = function() end,
	step = function(ctrl: ControllerType, s: StateTable, now: number): StateTable
		local char, player = extractVisibleTarget(ctrl.lastPercept)
		if char and player then
			local hrp = char:FindFirstChild("HumanoidRootPart") :: BasePart
			ctrl.blackboard.target = char
			ctrl.blackboard.targetPlayer = player
			ctrl.blackboard.lastSeen = now
			ctrl.blackboard.lastKnownPos = hrp.Position
			return { tag = "Engaging", target = char }
		end

		local ss = s
		if now >= (ss.endsAt or 0) then
			-- gave up the search: fully clear the target memory instead of just the live
			-- reference, since there's nothing left worth remembering at this point
			ctrl.blackboard.target = nil
			ctrl.blackboard.targetPlayer = nil
			ctrl.blackboard.lastKnownPos = nil
			ctrl.blackboard.aggression = 0
			return { tag = "Idle" }
		end

		return s
	end,
}

local function newBlackboard(): Blackboard
	-- the blackboard is the mob's per-tick memory: everything the state machine reads and
	-- writes that needs to persist across state transitions lives here in one place, rather
	-- than scattered across individual state tables that come and go with each transition
	return {
		target = nil,
		targetPlayer = nil,
		lastSeen = 0,
		lastKnownPos = nil,
		aggression = 0,
		whiffCount = 0,
		nextAttackAt = 0,
		pathCookie = 0,
		lastPathTarget = nil,
	}
end

function Controller.new(mob: Model, arch: any, replicateState: boolean): ControllerType?
	local hum = mob:FindFirstChildWhichIsA("Humanoid")
	local hrpInst = mob:FindFirstChild("HumanoidRootPart")
	if not hum or not hrpInst or not hrpInst:IsA("BasePart") then
		return nil
	end

	local combat = CombatController.fromCharacter(mob)
	if not combat then
		return nil
	end

	if hrpInst:CanSetNetworkOwnership() then
		-- keeping the server as the sole network owner of the mob's root part stops an
		-- exploiting client from being able to shove the mob around via its own physics
		pcall(hrpInst.SetNetworkOwner, hrpInst, nil)
	end

	local self = setmetatable({}, Controller) :: any
	self.mob = mob
	self.humanoid = hum
	self.hrp = hrpInst
	self.combat = combat
	self.archetype = arch
	self.replicateState = replicateState
	self.blackboard = newBlackboard()
	self.state = { tag = "Idle" }
	self.lastPercept = Perception.newResult()
	self.nextDecisionAt = 0
	self.nextSteerAt = 0
	self.nextRepathAt = 0
	self.lastStepAt = os.clock()
	self.waypoints = nil
	self.waypointIdx = 1
	self.isAlive = true

	if replicateState then
		hum:SetAttribute("AIState", "Idle")
	end

	self:setupJanitor()

	return self
end

function Controller:setupJanitor()
	-- tears the ai loop down the instant the rig is removed or its humanoid dies, instead of
	-- relying on the director to eventually notice a dead mob and clean it up on its own
	local jan = Janitor.new()
	jan:Add(self.mob.Destroying:Connect(function()
		self:destroy()
	end))
	jan:Add(self.humanoid.Died:Connect(function()
		self:destroy()
	end))
	self.janitor = jan
end

function Controller:decayAggression(elapsed: number)
	local bb = self.blackboard
	if bb.aggression <= 0 then
		return
	end
	-- aggression bleeds off passively over time so a mob that loses sight of a target for a
	-- while gradually calms back down, rather than staying permanently keyed up to engage
	bb.aggression = math.max(0, bb.aggression - self.archetype.aggressionDecayPerSec * elapsed)
end

function Controller:expireStaleTarget(now: number)
	local bb = self.blackboard
	if not bb.target then
		return
	end
	if (now - bb.lastSeen) <= self.archetype.memoryDuration then
		return
	end
	-- memory has run out: drop the live target reference but leave lastKnownPos alone, since
	-- the Searching state still needs somewhere to walk toward even after memory expires
	bb.target = nil
	bb.targetPlayer = nil
end

function Controller:runStateMachine(now: number, elapsed: number)
	local prev = self.state
	local prevTag = prev.tag
	local nextState = States[prevTag].step(self, prev, now, elapsed)

	if nextState.tag ~= prevTag then
		-- run the old state's exit before the new state's enter so setup/teardown ordering
		-- is always predictable, even for states that touch the same humanoid properties
		States[prevTag].exit(self, prev)
		States[nextState.tag].enter(self, nextState)
		self.state = nextState
		setAIState(self, nextState.tag)
		return
	end

	if nextState ~= prev then
		self.state = nextState
	end
end

function Controller:step(now: number, elapsed: number)
	if not self.isAlive then
		return
	end

	self:decayAggression(elapsed)
	self:expireStaleTarget(now)
	self.lastPercept = Perception.query(self.mob, self.hrp, self.archetype, now, self.lastPercept)
	self:runStateMachine(now, elapsed)
end

function Controller:updateFacing(tag: string, thrp: BasePart?)
	if not thrp then
		return
	end
	-- keep facing the target through every combat state except the active swing itself,
	-- since rotating mid-swing would visibly warp the attack animation's arc
	if tag ~= "Engaging" and tag ~= "AttackWindup" and tag ~= "Recovery" then
		return
	end

	local pos = self.hrp.Position
	local towardX, towardZ = thrp.Position.X - pos.X, thrp.Position.Z - pos.Z
	if (towardX * towardX + towardZ * towardZ) <= 0.0004 then
		-- close enough to already facing the target that a rotation update isn't worth it
		return
	end
	self.hrp.CFrame = CFrame.lookAt(pos, pos + Vector3.new(towardX, 0, towardZ))
end

function Controller:followTargetDuringRecovery(thrp: BasePart?)
	if not thrp then
		return
	end
	-- keeps drifting toward the target during recovery so the mob doesn't stand still and
	-- lose ground between swings while it waits for its next attack to come off cooldown
	self.humanoid:MoveTo(thrp.Position)
end

function Controller:followWaypoints()
	local wps = self.waypoints
	if not wps then
		return
	end

	local wp = wps[self.waypointIdx]
	if not wp then
		self.waypoints = nil
		return
	end

	local pos = self.hrp.Position
	local dx, dz = pos.X - wp.Position.X, pos.Z - wp.Position.Z
	local reachedWaypoint = (dx * dx + dz * dz) < 4
	if reachedWaypoint then
		-- close enough to this waypoint that we advance to the next one before moving again
		self.waypointIdx += 1
		wp = wps[self.waypointIdx]
		if not wp then
			self.waypoints = nil
			return
		end
	end

	self.humanoid:MoveTo(wp.Position)
end

function Controller:steer(now: number)
	if not self.isAlive then
		return
	end

	local tag = self.state.tag
	local target = self.blackboard.target
	local thrpRaw = target and target:FindFirstChild("HumanoidRootPart")
	local thrp = (thrpRaw and thrpRaw:IsA("BasePart")) and thrpRaw or nil

	self:updateFacing(tag, thrp)

	if tag == "Recovery" then
		self:followTargetDuringRecovery(thrp)
		return
	end

	if tag ~= "Engaging" and tag ~= "Searching" then
		return
	end
	self:followWaypoints()
end

function Controller:destroy()
	if not self.isAlive then
		return
	end
	self.isAlive = false

	-- drop this mob's cached perception state so the perception module doesn't keep holding
	-- onto data for a mob that no longer exists
	Perception.dropCacheFor(self.mob)

	if self.janitor then
		self.janitor:Destroy()
		self.janitor = nil
	end

	self.lastPercept = nil
	self.waypoints = nil
	self.blackboard.target = nil
	self.blackboard.targetPlayer = nil
	self.blackboard.lastKnownPos = nil
end

return { new = Controller.new, States = States, setDirector = setDirector }
