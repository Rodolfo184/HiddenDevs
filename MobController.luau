-- roblox Username: RodolfoDev, discord username: _.rodolfo
-- Connected Discord-GitHub
--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local ServerScriptService = game:GetService("ServerScriptService")

local Types = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("AI"):WaitForChild("Types"))
local Perception = require(ServerScriptService:WaitForChild("Modules"):WaitForChild("AI"):WaitForChild("Perception"))
local CombatController = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("CombatController"))
local Janitor = require(ReplicatedStorage.Modules.Icon.Packages.Janitor)

local Director: any = nil
local function setDirector(d: any) Director = d end

local Controller = {}
Controller.__index = Controller

type Handlers = {
	enter: (ctrl: any, st: Types.State) -> (),
	exit: (ctrl: any, st: Types.State) -> (),
	step: (ctrl: any, st: Types.State, now: number, elapsed: number) -> Types.State,
}

local States: { [string]: Handlers } = {}

local function getEquippedTool(mob: Model): Tool?
	for _, c in ipairs(mob:GetChildren()) do
		if c:IsA("Tool") then return c end
	end
	return nil
end

local function precondM1(mob: Model): boolean return getEquippedTool(mob) ~= nil end
local function precondCrit(mob: Model): boolean return getEquippedTool(mob) ~= nil end
local function precondFist(_mob: Model): boolean return true end

local ATTACK_PRECONDITION: { [string]: (mob: Model) -> boolean } = table.freeze({
	M1 = precondM1,
	Crit = precondCrit,
	Fist = precondFist,
})

local function dispatchM1(combat: any, mob: Model)
	local tool = getEquippedTool(mob)
	if tool then pcall(combat.doM1, combat, tool) end
end

local function dispatchCrit(combat: any, mob: Model)
	local tool = getEquippedTool(mob)
	if tool then pcall(combat.doCrit, combat, tool) end
end

local function dispatchFist(combat: any, _mob: Model)
	pcall(combat.doFistM1, combat)
end

local ATTACK_DISPATCH: { [string]: (combat: any, mob: Model) -> () } = table.freeze({
	M1 = dispatchM1,
	Crit = dispatchCrit,
	Fist = dispatchFist,
})

local function targetHRP(ctrl: any): BasePart?
	local t = ctrl.blackboard.target
	if not t or not t.Parent then return nil end
	local h = t:FindFirstChild("HumanoidRootPart")
	return (h and h:IsA("BasePart")) and h or nil
end

local function targetAlive(target: Model?): boolean
	if not target or not target.Parent then return false end
	local h = target:FindFirstChildWhichIsA("Humanoid")
	return h ~= nil and h.Health > 0
end

local function distSq(a: Vector3, b: Vector3): number
	local dx, dy, dz = a.X - b.X, a.Y - b.Y, a.Z - b.Z
	return dx * dx + dy * dy + dz * dz
end

local function isVisible(p: Types.PerceptionResult?, pl: Player?): boolean
	if not p or not pl then return false end
	for i = 1, #p.visible do
		if p.visible[i] == pl then return true end
	end
	return false
end

local function pickStrafeDir(): number
	return if math.random() > 0.5 then 1 else -1
end

local function setAIState(ctrl: any, tag: string)
	-- per-streamed-client downlink (replicates to every client streaming this mob); <=2 transitions/sec/mob
	if ctrl.replicateState then
		ctrl.humanoid:SetAttribute("AIState", tag)
	end
end

local function tryFireSwing(ctrl: any, now: number): boolean
	local arch = ctrl.archetype
	local kind = arch.attackKind
	local precond = ATTACK_PRECONDITION[kind]
	if not precond or not precond(ctrl.mob) then return false end

	local target = ctrl.blackboard.target
	if not targetAlive(target) then return false end
	local thrp = target:FindFirstChild("HumanoidRootPart")
	if not thrp or not thrp:IsA("BasePart") then return false end
	if not Players:GetPlayerFromCharacter(target) then return false end

	local pos = ctrl.hrp.Position
	local tx, ty, tz = thrp.Position.X - pos.X, thrp.Position.Y - pos.Y, thrp.Position.Z - pos.Z
	local d2 = tx * tx + ty * ty + tz * tz
	if d2 > arch.attackReach * arch.attackReach then return false end

	local f = ctrl.hrp.CFrame.LookVector
	local invD = 1 / math.sqrt(d2)
	if (tx * f.X + ty * f.Y + tz * f.Z) * invD < math.cos(arch.attackArcHalfRad) then return false end

	-- fresh raycast; perception cache TTL leaks lateral motion at the commit boundary
	if not Perception.losCheckFresh(ctrl.hrp, thrp) then return false end

	local parts = Perception.overlapForward(ctrl.hrp, arch.attackReach, arch.attackOverlapHalfWidth)
	local overlapped = false
	for i = 1, #parts do
		if parts[i]:IsDescendantOf(target) then overlapped = true; break end
	end
	if not overlapped then return false end

	if not Director.tryClaimSwingSlot(target, ctrl.mob, now, arch.swingSlotWindow) then return false end

	local fire = ATTACK_DISPATCH[kind]
	if not fire then return false end
	-- doM1/doCrit yield on marker-signal setup; isolate from Director Heartbeat
	task.spawn(fire, ctrl.combat, ctrl.mob)
	return true
end

States.Idle = {
	enter = function(ctrl)
		ctrl.humanoid.WalkSpeed = ctrl.archetype.walkSpeed
	end,
	exit = function() end,
	step = function(ctrl, s, now)
		local p = ctrl.lastPercept
		if p and p.closestVisible then
			local char = p.closestVisible.Character
			local hrp = char and char:FindFirstChild("HumanoidRootPart")
			if char and hrp and hrp:IsA("BasePart") then
				ctrl.blackboard.target = char
				ctrl.blackboard.targetPlayer = p.closestVisible
				ctrl.blackboard.lastSeen = now
				ctrl.blackboard.lastKnownPos = hrp.Position
				if ctrl.archetype.useStalking then
					ctrl.blackboard.aggression = ctrl.archetype.engageThreshold * 0.5
					return { tag = "Stalking", target = char, nextStrafeAt = now + 0.5, strafeDir = pickStrafeDir() } :: Types.State
				end
				return { tag = "Engaging", target = char } :: Types.State
			end
		end
		if p and #p.heard > 0 then
			return {
				tag = "Searching",
				lastKnown = p.heard[1],
				endsAt = now + ctrl.archetype.memoryDuration,
			} :: Types.State
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
		local thrp = targetHRP(ctrl)
		if not thrp or not targetAlive(ctrl.blackboard.target) then
			return {
				tag = "Searching",
				lastKnown = ctrl.blackboard.lastKnownPos or ctrl.hrp.Position,
				endsAt = now + arch.memoryDuration,
			} :: Types.State
		end
		if isVisible(ctrl.lastPercept, ctrl.blackboard.targetPlayer) then
			ctrl.blackboard.lastSeen = now
			ctrl.blackboard.lastKnownPos = thrp.Position
			ctrl.blackboard.aggression += arch.aggressionPerSec * elapsed
		end

		if ctrl.blackboard.aggression >= arch.engageThreshold then
			return { tag = "Engaging", target = ctrl.blackboard.target } :: Types.State
		end

		local ss = s :: Types.StateStalking
		if now >= ss.nextStrafeAt then
			ss.nextStrafeAt = now + (arch.strafeIntervalLo + math.random() * (arch.strafeIntervalHi - arch.strafeIntervalLo))
			if math.random() < 0.35 then ss.strafeDir = -ss.strafeDir end
			local pos = ctrl.hrp.Position
			local toX, toZ = thrp.Position.X - pos.X, thrp.Position.Z - pos.Z
			local d = math.sqrt(toX * toX + toZ * toZ)
			local fx, fz = if d > 0.001 then toX / d else 0, if d > 0.001 then toZ / d else 1
			local rx, rz = -fz, fx
			local sign = ss.strafeDir
			local goal: Vector3
			if d < arch.standoff - 2 then
				goal = pos + Vector3.new(-fx * 3 + rx * sign * 2, 0, -fz * 3 + rz * sign * 2)
			elseif d > arch.standoff + 3 then
				goal = pos + Vector3.new(fx * 3 + rx * sign * 2, 0, fz * 3 + rz * sign * 2)
			else
				goal = pos + Vector3.new(rx * sign * 4, 0, rz * sign * 4)
			end
			ctrl.humanoid:MoveTo(goal)
		end
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
		local thrp = targetHRP(ctrl)
		if not thrp or not targetAlive(ctrl.blackboard.target) then
			return {
				tag = "Searching",
				lastKnown = ctrl.blackboard.lastKnownPos or ctrl.hrp.Position,
				endsAt = now + arch.memoryDuration,
			} :: Types.State
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
			} :: Types.State
		end

		local lt = ctrl.blackboard.lastPathTarget
		local needsRepath = (not ctrl.waypoints)
			or (lt ~= nil and (lt - thrp.Position).Magnitude > arch.repathDistThreshold)
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
		if not targetAlive(ctrl.blackboard.target) then
			return { tag = "Recovery", endsAt = now + arch.recoveryDuration, didHit = false } :: Types.State
		end
		local sw = s :: Types.StateAttackWindup
		if now >= sw.endsAt then
			return {
				tag = "AttackActive",
				target = sw.target,
				endsAt = now + arch.activeDuration,
				hitFired = false,
			} :: Types.State
		end
		return s
	end,
}

States.AttackActive = {
	enter = function() end,
	exit = function() end,
	step = function(ctrl, s, now)
		local arch = ctrl.archetype
		local sa = s :: Types.StateAttackActive
		if not sa.hitFired then
			sa.hitFired = true
			local swingFired = tryFireSwing(ctrl, now)
			ctrl.blackboard.nextAttackAt = now + arch.attackCooldown
			if swingFired then
				ctrl.blackboard.whiffCount = 0
			else
				ctrl.blackboard.whiffCount += 1
			end
		end
		-- hold AttackActive until the swing animation truly ends; Recovery's MoveTo rotates the rig and would warp the swing arc mid-anim. 1s hard cap as safety.
		local trackDone = ctrl.combat.ActiveAttackTrack == nil
		if (now >= sa.endsAt and trackDone) or now >= sa.endsAt + 1.0 then
			return { tag = "Recovery", endsAt = now + arch.recoveryDuration, didHit = sa.hitFired } :: Types.State
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
		local sr = s :: Types.StateRecovery
		if now < sr.endsAt then return s end
		local arch = ctrl.archetype
		local tgt = ctrl.blackboard.target
		if not targetAlive(tgt) then
			return {
				tag = "Searching",
				lastKnown = ctrl.blackboard.lastKnownPos or ctrl.hrp.Position,
				endsAt = now + arch.memoryDuration,
			} :: Types.State
		end
		if ctrl.blackboard.whiffCount >= 2 then
			ctrl.blackboard.whiffCount = 0
			if arch.useStalking then
				ctrl.blackboard.aggression = math.min(ctrl.blackboard.aggression, arch.engageThreshold * 0.6)
				return {
					tag = "Stalking",
					target = tgt :: Model,
					nextStrafeAt = now,
					strafeDir = pickStrafeDir(),
				} :: Types.State
			end
		end
		return { tag = "Engaging", target = tgt :: Model } :: Types.State
	end,
}

States.Searching = {
	enter = function(ctrl, s)
		local ss = s :: Types.StateSearching
		ctrl.humanoid.WalkSpeed = ctrl.archetype.walkSpeed
		ctrl.humanoid:MoveTo(ss.lastKnown)
	end,
	exit = function() end,
	step = function(ctrl, s, now)
		local p = ctrl.lastPercept
		if p and p.closestVisible then
			local char = p.closestVisible.Character
			local hrp = char and char:FindFirstChild("HumanoidRootPart")
			if char and hrp and hrp:IsA("BasePart") then
				ctrl.blackboard.target = char
				ctrl.blackboard.targetPlayer = p.closestVisible
				ctrl.blackboard.lastSeen = now
				ctrl.blackboard.lastKnownPos = hrp.Position
				return { tag = "Engaging", target = char } :: Types.State
			end
		end
		local ss = s :: Types.StateSearching
		if now >= ss.endsAt then
			ctrl.blackboard.target = nil
			ctrl.blackboard.targetPlayer = nil
			ctrl.blackboard.lastKnownPos = nil
			ctrl.blackboard.aggression = 0
			return { tag = "Idle" } :: Types.State
		end
		return s
	end,
}

function Controller.new(mob: Model, arch: Types.ArchetypeConfig, replicateState: boolean): any?
	local hum = mob:FindFirstChildWhichIsA("Humanoid")
	local hrpInst = mob:FindFirstChild("HumanoidRootPart")
	if not hum or not hrpInst or not hrpInst:IsA("BasePart") then return nil end
	local combat = CombatController.fromCharacter(mob)
	if not combat then return nil end

	if hrpInst:CanSetNetworkOwnership() then
		pcall(hrpInst.SetNetworkOwner, hrpInst, nil)
	end

	local self = setmetatable({}, Controller) :: any
	self.mob = mob
	self.humanoid = hum
	self.hrp = hrpInst
	self.combat = combat
	self.archetype = arch
	self.replicateState = replicateState
	self.blackboard = {
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
	self.state = { tag = "Idle" } :: Types.State
	self.lastPercept = Perception.newResult()
	self.nextDecisionAt = 0
	self.nextSteerAt = 0
	self.nextRepathAt = 0
	self.lastStepAt = os.clock()
	self.waypoints = nil :: { PathWaypoint }?
	self.waypointIdx = 1
	self.alive = true

	if replicateState then hum:SetAttribute("AIState", "Idle") end

	local jan = Janitor.new()
	jan:Add(mob.Destroying:Connect(function() self:destroy() end))
	jan:Add(hum.Died:Connect(function() self:destroy() end))
	self.janitor = jan

	return self
end

function Controller:step(now: number, elapsed: number)
	if not self.alive then return end
	local arch = self.archetype
	local bb = self.blackboard
	if bb.aggression > 0 then
		bb.aggression = math.max(0, bb.aggression - arch.aggressionDecayPerSec * elapsed)
	end
	-- memory expiry: drop the target reference but preserve lastKnownPos so Searching has somewhere to walk
	if bb.target and (now - bb.lastSeen) > arch.memoryDuration then
		bb.target = nil
		bb.targetPlayer = nil
	end

	self.lastPercept = Perception.query(self.mob, self.hrp, arch, now, self.lastPercept)

	local prev = self.state
	local prevTag = prev.tag
	local nextState = States[prevTag].step(self, prev, now, elapsed)
	if nextState.tag ~= prevTag then
		States[prevTag].exit(self, prev)
		States[nextState.tag].enter(self, nextState)
		self.state = nextState
		setAIState(self, nextState.tag)
	elseif nextState ~= prev then
		self.state = nextState
	end
end

function Controller:steer(now: number)
	if not self.alive then return end
	local tag = self.state.tag
	local target = self.blackboard.target
	local thrp = target and target:FindFirstChild("HumanoidRootPart")

	-- face-track target during all combat states except AttackActive (lets swing animation arc play)
	if thrp and thrp:IsA("BasePart") and (tag == "Engaging" or tag == "AttackWindup" or tag == "Recovery") then
		local pos = self.hrp.Position
		local tx, tz = thrp.Position.X - pos.X, thrp.Position.Z - pos.Z
		if (tx * tx + tz * tz) > 0.0004 then
			self.hrp.CFrame = CFrame.lookAt(pos, pos + Vector3.new(tx, 0, tz))
		end
	end

	if tag == "Recovery" then
		if thrp and thrp:IsA("BasePart") then
			self.humanoid:MoveTo(thrp.Position)
		end
		return
	end

	if tag ~= "Engaging" and tag ~= "Searching" then return end
	local wps = self.waypoints
	if not wps then return end
	local idx = self.waypointIdx
	local wp = wps[idx]
	if not wp then
		self.waypoints = nil
		return
	end
	local pos = self.hrp.Position
	local dx, dz = pos.X - wp.Position.X, pos.Z - wp.Position.Z
	if (dx * dx + dz * dz) < 4 then
		idx += 1
		self.waypointIdx = idx
		wp = wps[idx]
		if not wp then
			self.waypoints = nil
			return
		end
	end
	self.humanoid:MoveTo(wp.Position)
end

function Controller:destroy()
	if not self.alive then return end
	self.alive = false
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
