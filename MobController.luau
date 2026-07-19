--!strict
-- roblox Username: RodolfoDev, discord username: _.rodolfo
-- Connected Discord-GitHub

-- this module drives a single mob's ai loop: perception in, a small state machine in the
-- middle, humanoid movement out. it is instantiated once per mob and ticked externally by
-- a director script that owns the heartbeat and batches all mobs' step/steer calls together

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local ServerScriptService = game:GetService("ServerScriptService")

local Types = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("AI"):WaitForChild("Types"))
local Perception = require(ServerScriptService:WaitForChild("Modules"):WaitForChild("AI"):WaitForChild("Perception"))
local CombatController = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("CombatController"))
local Janitor = require(ReplicatedStorage.Modules.Icon.Packages.Janitor)

-- the director is injected after this module loads, rather than required directly, because
-- the director itself requires this module to spawn controllers. requiring each other directly
-- would create a circular require, so we break the cycle with a setter instead
local Director = nil
local function setDirector(d)
	Director = d
end

local Controller = {}
Controller.__index = Controller

local States = {}

local function getEquippedTool(mob)
	-- mobs only ever hold one tool at a time, so the first one we find is the equipped one
	for _, c in ipairs(mob:GetChildren()) do
		if c:IsA("Tool") then
			return c
		end
	end
	return nil
end

local function precondM1(mob)
	return getEquippedTool(mob) ~= nil
end

local function precondCrit(mob)
	return getEquippedTool(mob) ~= nil
end

local function precondFist(_mob)
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

local function dispatchM1(combat, mob)
	local tool = getEquippedTool(mob)
	if tool then
		pcall(combat.doM1, combat, tool)
	end
end

local function dispatchCrit(combat, mob)
	local tool = getEquippedTool(mob)
	if tool then
		pcall(combat.doCrit, combat, tool)
	end
end

local function dispatchFist(combat, _mob)
	pcall(combat.doFistM1, combat)
end

-- mirrors ATTACK_PRECONDITION: same table-driven approach so precondition and dispatch for a
-- given attack kind stay next to each other conceptually, even though they live in two tables
local ATTACK_DISPATCH = table.freeze({
	M1 = dispatchM1,
	Crit = dispatchCrit,
	Fist = dispatchFist,
})

local function targetHrp(ctrl)
	local t = ctrl.blackboard.target
	if not t or not t.Parent then
		return nil
	end
	local h = t:FindFirstChild("HumanoidRootPart")
	return (h and h:IsA("BasePart")) and h or nil
end

local function isTargetAlive(target)
	if not target or not target.Parent then
		return false
	end
	local h = target:FindFirstChildWhichIsA("Humanoid")
	return h ~= nil and h.Health > 0
end

local function distSq(a, b)
	-- squared distance avoids a sqrt call on every comparison; callers only need it for
	-- threshold checks, so the square root is never actually needed
	local dx, dy, dz = a.X - b.X, a.Y - b.Y, a.Z - b.Z
	return dx * dx + dy * dy + dz * dz
end

local function isVisible(p, pl)
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

local function pickStrafeDir()
	-- just a coin flip between orbiting left or right around the target
	return if math.random() > 0.5 then 1 else -1
end

local function setAIState(ctrl, tag)
	-- this attribute is what clients read to drive animations and debug visuals, so it's only
	-- written for mobs flagged as replicated. writing it for every mob regardless of whether
	-- anyone is watching would be wasted replication traffic, capped here at roughly
	-- two transitions per second per mob by virtue of how rarely states actually change
	if ctrl.replicateState then
		ctrl.humanoid:SetAttribute("AIState", tag)
	end
end

local function extractVisibleTarget(percept)
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

local function computeStrafeGoal(originPos, targetPos, standoff, strafeDir)
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

local function tryFireSwing(ctrl, now)
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
	local thrp = target:FindFirstChild("HumanoidRootPart")
	if not thrp or not thrp:IsA("BasePart") then
		return false
	end
	if not Players:GetPlayerFromCharacter(target) then
		return false
	end

	local pos = ctrl._hrp.Position
	local tx, ty, tz = thrp.Position.X - pos.X, thrp.Position.Y - pos.Y, thrp.Position.Z - pos.Z
	local d2 = tx * tx + ty * ty + tz * tz
	if d2 > arch.attackReach * arch.attackReach then
		return false
	end

	-- reject targets outside the attack's forward arc so a mob can't land a hit on
	-- someone standing behind it, even if they're technically within reach
	local f = ctrl._hrp.CFrame.LookVector
	local invD = 1 / math.sqrt(d2)
	if (tx * f.X + ty * f.Y + tz * f.Z) * invD < math.cos(arch.attackArcHalfRad) then
		return false
	end

	-- a fresh raycast here, rather than trusting the cached perception line-of-sight, because
	-- the perception cache has a ttl and can go stale enough at the moment of committing to a
	-- swing that a target who has since ducked behind cover would otherwise still get hit
	if not Perception.losCheckFresh(ctrl._hrp, thrp) then
		return false
	end

	local parts = Perception.overlapForward(ctrl._hrp, arch.attackReach, arch.attackOverlapHalfWidth)
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

-- each state owns three small functions: enter (one-time setup when transitioning in),
-- exit (one-time cleanup when transitioning out), and step (the per-tick logic that either
-- returns the same state table to stay put, or a new state table to transition)

States.Idle = {
	enter = function(ctrl)
		ctrl.humanoid.WalkSpeed = ctrl.archetype.walkSpeed
	end,
	exit = function() end,
	step = function(ctrl, s, now)
		local char, player = extractVisibleTarget(ctrl.lastPercept)
		if char and player then
			local hrp = char:FindFirstChild("HumanoidRootPart")
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
	enter = function(ctrl)
		ctrl.humanoid.WalkSpeed = ctrl.archetype.walkSpeed
		Director.clearPath(ctrl)
	end,
	exit = function() end,
	step = function(ctrl, s, now, elapsed)
		local arch = ctrl.archetype
		local thrp = targetHrp(ctrl)
		if not thrp or not isTargetAlive(ctrl.blackboard.target) then
			return {
				tag = "Searching",
				lastKnown = ctrl.blackboard.lastKnownPos or ctrl._hrp.Position,
				endsAt = now + arch.memoryDuration,
			}
		end

		if isVisible(ctrl.lastPercept, ctrl.blackboard.targetPlayer) then
			ctrl.blackboard.lastSeen = now
			ctrl.blackboard.lastKnownPos = thrp.Position
			-- aggression only builds while the target is actually visible, so a mob that's
			-- stalking someone who ducks out of sight stops closing in on the decision to engage
			ctrl.blackboard.aggression += arch.aggressionPerSec * elapsed
		end

		if ctrl.blackboard.aggression >= arch.engageThreshold then
			return { tag = "Engaging", target = ctrl.blackboard.target }
		end

		local ss = s
		if now < ss.nextStrafeAt then
			return s
		end

		-- time to pick the next strafe move; the next one is scheduled somewhere inside the
		-- configured interval window so the movement doesn't fall into an obvious, repeating rhythm
		ss.nextStrafeAt = now + (arch.strafeIntervalLo + math.random() * (arch.strafeIntervalHi - arch.strafeIntervalLo))
		if math.random() < 0.35 then
			-- occasionally reverse orbit direction so the strafing reads as deliberate
			-- circling rather than a mob stuck looping the same path around the target
			ss.strafeDir = -ss.strafeDir
		end

		local goal = computeStrafeGoal(ctrl._hrp.Position, thrp.Position, arch.standoff, ss.strafeDir)
		ctrl.humanoid:MoveTo(goal)
		return s
	end,
}

States.Engaging = {
	enter = function(ctrl)
		ctrl.humanoid.WalkSpeed = ctrl.archetype.runSpeed
	end,
	exit = function(ctrl)
		Director.clearPath(ctrl)
	end,
	step = function(ctrl, s, now)
		local arch = ctrl.archetype
		local thrp = targetHrp(ctrl)
		if not thrp or not isTargetAlive(ctrl.blackboard.target) then
			return {
				tag = "Searching",
				lastKnown = ctrl.blackboard.lastKnownPos or ctrl._hrp.Position,
				endsAt = now + arch.memoryDuration,
			}
		end

		if isVisible(ctrl.lastPercept, ctrl.blackboard.targetPlayer) then
			ctrl.blackboard.lastSeen = now
			ctrl.blackboard.lastKnownPos = thrp.Position
		end

		local pos = ctrl._hrp.Position
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
		local needsRepath = (not ctrl._waypoints) or (lt ~= nil and (lt - thrp.Position).Magnitude > arch.repathDistThreshold)
		if needsRepath then
			Director.requestPath(ctrl, pos, thrp.Position)
			ctrl.blackboard.lastPathTarget = thrp.Position
		end

		return s
	end,
}

States.AttackWindup = {
	enter = function(ctrl)
		ctrl.humanoid.WalkSpeed = 0
		ctrl.humanoid.AutoRotate = false
		Director.clearPath(ctrl)
	end,
	exit = function(ctrl)
		ctrl.humanoid.WalkSpeed = ctrl.archetype.runSpeed
		ctrl.humanoid.AutoRotate = true
	end,
	step = function(ctrl, s, now)
		local arch = ctrl.archetype
		if not isTargetAlive(ctrl.blackboard.target) then
			-- target died mid-windup, so skip straight to recovery without ever landing a hit
			return { tag = "Recovery", endsAt = now + arch.recoveryDuration, didHit = false }
		end

		local sw = s
		if now >= sw.endsAt then
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
	step = function(ctrl, s, now)
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
		if (now >= sa.endsAt and trackDone) or now >= sa.endsAt + 1.0 then
			return { tag = "Recovery", endsAt = now + arch.recoveryDuration, didHit = sa.hitFired }
		end

		return s
	end,
}

States.Recovery = {
	enter = function(ctrl)
		ctrl.humanoid.WalkSpeed = ctrl.archetype.walkSpeed
	end,
	exit = function() end,
	step = function(ctrl, s, now)
		local sr = s
		if now < sr.endsAt then
			return s
		end

		local arch = ctrl.archetype
		local tgt = ctrl.blackboard.target
		if not isTargetAlive(tgt) then
			return {
				tag = "Searching",
				lastKnown = ctrl.blackboard.lastKnownPos or ctrl._hrp.Position,
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
	enter = function(ctrl, s)
		local ss = s
		ctrl.humanoid.WalkSpeed = ctrl.archetype.walkSpeed
		ctrl.humanoid:MoveTo(ss.lastKnown)
	end,
	exit = function() end,
	step = function(ctrl, s, now)
		local char, player = extractVisibleTarget(ctrl.lastPercept)
		if char and player then
			local hrp = char:FindFirstChild("HumanoidRootPart")
			ctrl.blackboard.target = char
			ctrl.blackboard.targetPlayer = player
			ctrl.blackboard.lastSeen = now
			ctrl.blackboard.lastKnownPos = hrp.Position
			return { tag = "Engaging", target = char }
		end

		local ss = s
		if now >= ss.endsAt then
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

local function newBlackboard()
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

function Controller.new(mob, arch, replicateState)
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

	local self = setmetatable({}, Controller)
	self.mob = mob
	self.humanoid = hum
	self._hrp = hrpInst
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
	self._waypoints = nil
	self._waypointIdx = 1
	self._isAlive = true

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
	self._janitor = jan
end

function Controller:decayAggression(elapsed)
	local bb = self.blackboard
	if bb.aggression <= 0 then
		return
	end
	-- aggression bleeds off passively over time so a mob that loses sight of a target for a
	-- while gradually calms back down, rather than staying permanently keyed up to engage
	bb.aggression = math.max(0, bb.aggression - self.archetype.aggressionDecayPerSec * elapsed)
end

function Controller:expireStaleTarget(now)
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

function Controller:runStateMachine(now, elapsed)
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

function Controller:step(now, elapsed)
	if not self._isAlive then
		return
	end

	self:decayAggression(elapsed)
	self:expireStaleTarget(now)
	self.lastPercept = Perception.query(self.mob, self._hrp, self.archetype, now, self.lastPercept)
	self:runStateMachine(now, elapsed)
end

function Controller:updateFacing(tag, thrp)
	if not thrp then
		return
	end
	-- keep facing the target through every combat state except the active swing itself,
	-- since rotating mid-swing would visibly warp the attack animation's arc
	if tag ~= "Engaging" and tag ~= "AttackWindup" and tag ~= "Recovery" then
		return
	end

	local pos = self._hrp.Position
	local towardX, towardZ = thrp.Position.X - pos.X, thrp.Position.Z - pos.Z
	if (towardX * towardX + towardZ * towardZ) <= 0.0004 then
		-- close enough to already facing the target that a rotation update isn't worth it
		return
	end
	self._hrp.CFrame = CFrame.lookAt(pos, pos + Vector3.new(towardX, 0, towardZ))
end

function Controller:followTargetDuringRecovery(thrp)
	if not thrp then
		return
	end
	-- keeps drifting toward the target during recovery so the mob doesn't stand still and
	-- lose ground between swings while it waits for its next attack to come off cooldown
	self.humanoid:MoveTo(thrp.Position)
end

function Controller:followWaypoints()
	local wps = self._waypoints
	if not wps then
		return
	end

	local wp = wps[self._waypointIdx]
	if not wp then
		self._waypoints = nil
		return
	end

	local pos = self._hrp.Position
	local dx, dz = pos.X - wp.Position.X, pos.Z - wp.Position.Z
	local reachedWaypoint = (dx * dx + dz * dz) < 4
	if reachedWaypoint then
		-- close enough to this waypoint that we advance to the next one before moving again
		self._waypointIdx += 1
		wp = wps[self._waypointIdx]
		if not wp then
			self._waypoints = nil
			return
		end
	end

	self.humanoid:MoveTo(wp.Position)
end

function Controller:steer(now)
	if not self._isAlive then
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
	if not self._isAlive then
		return
	end
	self._isAlive = false

	-- drop this mob's cached perception state so the perception module doesn't keep holding
	-- onto data for a mob that no longer exists
	Perception.dropCacheFor(self.mob)

	if self._janitor then
		self._janitor:Destroy()
		self._janitor = nil
	end

	self.lastPercept = nil
	self._waypoints = nil
	self.blackboard.target = nil
	self.blackboard.targetPlayer = nil
	self.blackboard.lastKnownPos = nil
end

return { new = Controller.new, States = States, setDirector = setDirector }

