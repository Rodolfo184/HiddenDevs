--!strict
-- roblox Username: RodolfoDev, discord username: _.rodolfo
-- Connected Discord-GitHub

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Modules = ReplicatedStorage.Modules
local CombatConfig = require(Modules.CombatConfig)
local EnemyConfig = require(Modules.Enemy.EnemyConfig)
local HudConfig = require(Modules.HudConfig)
local Motion = require(Modules.Motion)
local NetCombat = require(Modules.NetCombat)
local PartyConfig = require(Modules.PartyConfig)
local SettingsConfig = require(Modules.SettingsConfig)
local ShopConfig = require(Modules.ShopConfig)
local SkillTreeConfig = require(Modules.SkillTreeConfig)

local PULL_STOP_DISTANCE = 3 -- stop pulling inside this range
local REPUTATION_CAP = 0.18 -- max rep bonus (18%)
local HITBOX_PADDING = 0.25 -- hitbox edge leniency
local TIMER_SLACK = 0.01
local BASE_WALK_SPEED = 16
local FLAT = Vector3.new(1, 0, 1)

-- distance a strength 1 knockback covers, used to convert pulls
local PULL_REACH = Motion.travel({
	speed = 1,
	time = CombatConfig.knockback.time,
	taper = CombatConfig.knockback.taper,
}, CombatConfig.knockback.time)

type Modifiers = {
	power: number?,
	crit: number?,
	critDmg: number?,
	charge: number?,
	basicHit: boolean?,
	origin: CFrame?,
	valid: (() -> boolean)?,
}

-- config tables inherit from their skill through __index, hence rawget for optional keys
type SkillData = { [string]: any }
type IgnoreFilter = (Model) -> boolean
type HitList = { [Instance]: boolean }

type Cast = {
	character: Model,
	humanoid: Humanoid,
	skill: SkillData,
	ignore: IgnoreFilter?,
	modifiers: Modifiers?,
	-- client input, untrusted until point() checks it
	pointFunction: (() -> any)?,
	isLocked: boolean,
	lockedOrigin: CFrame?,
	aimSpot: Vector3?,
}

local SkillCombat = {}

-- aggro listens to this, so all damage has to go through strike()
SkillCombat.hit = Instance.new("BindableEvent")

local hitTracks: { [Animator]: { [string]: AnimationTrack } } = {}
-- weak keys so destroyed models dont stick around
local slowUntil = setmetatable({} :: { [Model]: number }, { __mode = "k" })
local stunUntil = setmetatable({} :: { [Model]: number }, { __mode = "k" })

local function getHumanoid(model: Model): Humanoid?
	return model:FindFirstChildOfClass("Humanoid") :: Humanoid?
end

local function getRootPart(model: Model): BasePart?
	return model:FindFirstChild("HumanoidRootPart") :: BasePart?
end

local function flatOffset(from: Vector3, to: Vector3): Vector3
	return (to - from) * FLAT
end

-- only the newest timer gets to clear it
local function isLatestTimer(timers: { [Model]: number }, model: Model): boolean
	return (timers[model] or 0) <= os.clock() + TIMER_SLACK
end

-- skills run off timers, recheck the caster every step
local function getCastRoot(cast: Cast): BasePart?
	if not cast.character.Parent or cast.humanoid.Health <= 0 then
		return nil
	end
	local valid = if cast.modifiers then cast.modifiers.valid else nil
	if valid and not valid() then
		return nil
	end
	return getRootPart(cast.character)
end

-- locked skills keep their cast position even if you move
local function getCastOrigin(cast: Cast, root: BasePart): CFrame
	if cast.isLocked and not cast.lockedOrigin then
		cast.lockedOrigin = root.CFrame
	end
	return if cast.isLocked then cast.lockedOrigin :: CFrame else root.CFrame
end

-- cached per animator, no LoadAnimation spam during combos
local function getHitTrack(animator: Animator, key: string, animationId: string): AnimationTrack?
	local tracks = hitTracks[animator]
	if not tracks then
		tracks = {}
		hitTracks[animator] = tracks
		animator.Destroying:Connect(function()
			hitTracks[animator] = nil
		end)
	end
	if tracks[key] then
		return tracks[key]
	end

	local animation = Instance.new("Animation")
	animation.AnimationId = animationId
	-- can throw if the rig is getting removed
	local ok, result = pcall(animator.LoadAnimation, animator, animation)
	if not ok or not result then
		return nil
	end
	local track = result :: AnimationTrack
	track.Priority = Enum.AnimationPriority.Action3
	track.Looped = false
	tracks[key] = track
	return track
end

-- big knockback = launch anim, otherwise normal flinch
local function playHitAnimation(model: Model, knockback: number?)
	local humanoid = getHumanoid(model)
	if not humanoid or humanoid.Health <= 0 or not CombatConfig.hitAnim then
		return
	end
	local animator = humanoid:FindFirstChildOfClass("Animator") :: Animator?
	if not animator then
		return
	end
	local isLaunch = knockback ~= nil and knockback >= (CombatConfig.knockbackAnimMin or math.huge)
	local key = if isLaunch then "launch" else "hit"
	-- fall back to the flinch if theres no launch anim
	local launchId = CombatConfig.knockbackAnim or CombatConfig.hitAnim
	local track = getHitTrack(animator, key, if isLaunch then launchId else CombatConfig.hitAnim)
	if not track then
		return
	end

	-- stop the flinch or it twitches under the launch
	for otherKey, otherTrack in pairs(hitTracks[animator]) do
		if otherKey ~= key and otherTrack.IsPlaying then
			otherTrack:Stop(0.05)
		end
	end
	-- restart so every hit gets its own flinch
	if track.IsPlaying then
		track:Stop(0)
	end
	track:Play(if isLaunch then CombatConfig.knockbackFade else CombatConfig.hitFade)
end

local function endSlow(model: Model)
	if not model.Parent or not isLatestTimer(slowUntil, model) then
		return
	end
	slowUntil[model] = nil
	model:SetAttribute(CombatConfig.slowAttribute, false)
	-- only reset if nothing else changed the speed meanwhile
	local humanoid = getHumanoid(model)
	local slow = CombatConfig.hitSlow
	if not humanoid or humanoid.Health <= 0 or humanoid.WalkSpeed ~= slow.walkSpeed then
		return
	end
	-- blocking has its own walkspeed
	local base = if model:GetAttribute(CombatConfig.blockAttribute)
		then BASE_WALK_SPEED * CombatConfig.block.walkSpeedMultiplier
		else slow.restore
	humanoid.WalkSpeed = base * (model:GetAttribute(SkillTreeConfig.attributes.speed) or 1)
end

-- slows only ever extend, never shorten
local function applySlow(model: Model, seconds: number?)
	local slow = CombatConfig.hitSlow
	if not slow or not seconds or seconds <= 0 then
		return
	end
	local humanoid = getHumanoid(model)
	local expiresAt = os.clock() + seconds
	if not humanoid or humanoid.Health <= 0 or (slowUntil[model] or 0) >= expiresAt then
		return
	end
	slowUntil[model] = expiresAt
	-- flag first so speed listeners already see it
	model:SetAttribute(CombatConfig.slowAttribute, true)
	humanoid.WalkSpeed = slow.walkSpeed
	task.delay(seconds, endSlow, model)
end

-- buffs are attributes on server time so clients can read them too
local function getBuff(model: Model?, kind: string): number?
	local name = if model then CombatConfig.buffAttributes[kind] else nil
	if not model or not name then
		return nil
	end
	if workspace:GetServerTimeNow() >= (model:GetAttribute(name .. "Until") or 0) then
		return nil
	end
	return model:GetAttribute(name)
end

local function endStun(model: Model)
	if model.Parent and isLatestTimer(stunUntil, model) then
		stunUntil[model] = nil
		model:SetAttribute(CombatConfig.stunAttribute, false)
	end
end

-- slow outlasts the stun a bit so they cant instantly run off
local function applyStun(model: Model, seconds: number, _attacker: Model?, knockback: number?)
	if seconds <= 0 then
		return
	end
	playHitAnimation(model, knockback)
	applySlow(model, math.max(seconds, CombatConfig.hitSlow.minimum) + CombatConfig.hitSlow.tail)
	stunUntil[model] = math.max(stunUntil[model] or 0, os.clock() + seconds)
	model:SetAttribute(CombatConfig.stunAttribute, true)
	task.delay(seconds, endStun, model)
end

function SkillCombat.stunned(model: Model?): boolean
	return model ~= nil and (stunUntil[model] or 0) > os.clock()
end

local function hasPvpEnabled(player: Player): boolean
	local level = player:GetAttribute("Level") or 1
	return SettingsConfig.get("pvp", player) == true and level >= SettingsConfig.pvpLevel
end

-- is the other side outside this exam?
local function isExamOutsider(ownerId: number?, other: Player?, otherOwnerId: number?): boolean
	if not ownerId or (other and other.UserId == ownerId) then
		return false
	end
	return otherOwnerId ~= ownerId
end

local function canHurt(attacker: Model?, victim: Model?): boolean
	if not attacker or not victim then
		return true
	end
	local attackerPlayer = Players:GetPlayerFromCharacter(attacker)
	local victimPlayer = Players:GetPlayerFromCharacter(victim)

	-- pvp needs both players opted in, party members cant hit each other
	if attackerPlayer and victimPlayer then
		local optedIn = hasPvpEnabled(attackerPlayer) and hasPvpEnabled(victimPlayer)
		if attackerPlayer ~= victimPlayer and not optedIn then
			return false
		end
		if not PartyConfig.canHurt(attackerPlayer, victimPlayer) then
			return false
		end
	end
	-- players cant hurt story escorts
	if attackerPlayer and victim:GetAttribute("StoryEscort") then
		return false
	end

	-- exam npcs only fight their examinee, examinees only fight the exam
	local attackerExam = attacker:GetAttribute("ExamOwner")
	local victimExam = victim:GetAttribute("ExamOwner")
	if isExamOutsider(attackerExam, victimPlayer, victimExam) then
		return false
	end
	if isExamOutsider(victimExam, attackerPlayer, attackerExam) then
		return false
	end
	if attacker:GetAttribute("ExamActive") and not victimExam then
		return false
	end
	return not (victim:GetAttribute("ExamActive") and not attackerExam)
end

local function isValidTarget(
	attacker: Model?, model: Model, humanoid: Humanoid, ignore: IgnoreFilter?
): boolean
	if humanoid.Health <= 0 or (ignore and ignore(model)) then
		return false
	end
	return canHurt(attacker, model) and not model:GetAttribute(CombatConfig.invulnerableAttribute)
end

-- skip accessories/tools, only the actual body counts
local function bodyHit(part: BasePart): (Model?, Humanoid?)
	if part:FindFirstAncestorWhichIsA("Accessory") or part:FindFirstAncestorOfClass("Tool") then
		return nil, nil
	end
	local model = part:FindFirstAncestorOfClass("Model") :: Model?
	local humanoid = if model then getHumanoid(model) else nil
	if not humanoid then
		return nil, nil
	end
	return model, humanoid
end

-- bounds overreach on rotated limbs, so test the closest point instead
local function touches(origin: CFrame, boxSize: Vector3, part: BasePart): boolean
	local localCentre = part.CFrame:PointToObjectSpace(origin.Position)
	local half = part.Size / 2
	local closest = Vector3.new(
		math.clamp(localCentre.X, -half.X, half.X),
		math.clamp(localCentre.Y, -half.Y, half.Y),
		math.clamp(localCentre.Z, -half.Z, half.Z)
	)
	local offset = origin:PointToObjectSpace(part.CFrame:PointToWorldSpace(closest))
	local reach = boxSize / 2 + Vector3.one * HITBOX_PADDING
	return math.abs(offset.X) <= reach.X
		and math.abs(offset.Y) <= reach.Y
		and math.abs(offset.Z) <= reach.Z
end

-- attacker side only, the victims defenses get applied in strike
local function getDamage(
	attacker: Model?, data: SkillData, modifiers: Modifiers?
): (number, Player?)
	local owner = if attacker then Players:GetPlayerFromCharacter(attacker) else nil
	local damage = data.damage * (if modifiers then modifiers.power or 1 else 1)
	-- npcs dont get rep or shop boosts
	if owner then
		local reputation = math.clamp(owner:GetAttribute("ReputationBonus") or 0, 0, REPUTATION_CAP)
		damage = damage * (1 + reputation) * (ShopConfig.boost(owner, "damage") or 1)
	end
	local crit = if modifiers then modifiers.crit or 0 else 0
	if crit > 0 and math.random() < crit then
		damage *= (modifiers :: Modifiers).critDmg or 1
	end
	if not attacker then
		return damage, owner
	end
	if attacker:GetAttribute(EnemyConfig.attribute) then
		damage *= EnemyConfig.damageScale
	end
	return damage * (attacker:GetAttribute(SkillTreeConfig.attributes.damage) or 1), owner
end

-- blocks only work from the front
local function isBlocking(model: Model, attacker: Model?): boolean
	if model:GetAttribute(CombatConfig.blockAttribute) ~= true then
		return false
	end
	local body = getRootPart(model)
	local from = if attacker then getRootPart(attacker) else nil
	local offset = if body and from then flatOffset(body.Position, from.Position) else Vector3.zero
	local facing = if body then body.CFrame.LookVector * FLAT else Vector3.zero
	-- cant tell the angle, count it as blocked
	if offset.Magnitude < 0.5 or facing.Magnitude < 0.01 then
		return true
	end
	local halfArc = math.rad(CombatConfig.block.arc / 2)
	return facing.Unit:Dot(offset.Unit) >= math.cos(halfArc) - 1e-3
end

-- away from the attacker, or their facing if theyre on top of each other
local function getKnockbackDirection(root: BasePart, attacker: Model?): Vector3
	local from = if attacker then getRootPart(attacker) else nil
	local base = if from then from.CFrame else root.CFrame
	local direction = flatOffset(base.Position, root.Position)
	if direction.Magnitude <= 0.1 then
		direction = base.LookVector * FLAT
	end
	return if direction.Magnitude > 0.1 then direction.Unit else Vector3.new(0, 0, -1)
end

local function applyHitReaction(
	attacker: Model?, model: Model, data: SkillData, modifiers: Modifiers?, centre: Vector3?
)
	local isBasic = modifiers ~= nil and modifiers.basicHit == true
	local player = Players:GetPlayerFromCharacter(model)
	-- basic hits use hitPush instead of knockback
	local knockback = if isBasic then 0 else data.knockback or 0

	-- extra hold on npcs for laggy combos, npc basic hits stun players less
	local stun = data.stun
	if isBasic and not player then
		stun += CombatConfig.npcComboGrace
	elseif isBasic and attacker and attacker:GetAttribute(EnemyConfig.attribute) then
		stun *= EnemyConfig.playerStunScale
	end
	applyStun(model, stun, attacker, knockback)

	local root = getRootPart(model)
	if not root then
		return
	end
	local direction = getKnockbackDirection(root, attacker)
	-- drag toward the middle, converted into a knockback strength
	local toCentre = if centre then flatOffset(root.Position, centre) else Vector3.zero
	local pull = data.pull or 0
	if knockback <= 0 and pull > 0 and toCentre.Magnitude > PULL_STOP_DISTANCE then
		direction, knockback = toCentre.Unit, toCentre.Magnitude * pull / PULL_REACH
	end

	-- client owns its character physics so it does the push itself
	if player then
		if knockback > 0 then
			NetCombat:FireClient(player, "knockback", direction, knockback)
		elseif isBasic then
			NetCombat:FireClient(player, "hitPush", direction)
		end
	elseif knockback > 0 then
		-- npc humanoids brake raw impulses, so use the tapered dash
		Motion.dash(root, direction, CombatConfig.knockback, nil, knockback)
	elseif isBasic then
		Motion.hitPush(root, direction, CombatConfig.hitPush)
	end
end

-- all damage goes through here, false = target skipped
local function strike(
	attacker: Model?, model: Model, humanoid: Humanoid, part: BasePart, alreadyHit: HitList,
	data: SkillData, ignore: IgnoreFilter?, modifiers: Modifiers?, centre: Vector3?
): boolean
	if alreadyHit[humanoid] or not isValidTarget(attacker, model, humanoid, ignore) then
		return false
	end
	alreadyHit[humanoid] = true

	local damage, owner = getDamage(attacker, data, modifiers)
	local reduction = model:GetAttribute(SkillTreeConfig.attributes.reduction) or 0
	damage *= 1 - math.clamp(reduction, 0, SkillTreeConfig.reductionCap)
	damage *= 1 - math.clamp(getBuff(model, "resist") or 0, 0, 1)
	local blocked = isBlocking(model, attacker)
	if blocked then
		damage *= 1 - CombatConfig.block.damageReduction
	end
	if owner and Players:GetPlayerFromCharacter(model) then
		damage *= CombatConfig.pvpDamage
	end

	-- use actual health lost (forcefields, overkill)
	local before = humanoid.Health
	if damage > 0 then
		humanoid:TakeDamage(damage)
	end
	local dealt = math.max(0, before - humanoid.Health)
	if dealt <= 0 and not blocked then
		return true
	end
	if not blocked then
		applyHitReaction(attacker, model, data, modifiers, centre)
	end

	-- effect uses the defenders weapon on a block
	local _, weapon = CombatConfig.forCharacter(if blocked then model else attacker)
	local style = if not weapon or weapon == CombatConfig.Fists then "Fists" else "Weapon"
	local isBasic = modifiers ~= nil and modifiers.basicHit == true
	local effectPart = getRootPart(model) or part
	local wear = if blocked then HudConfig.blockWear(data) else nil
	ReplicatedStorage.Remotes.DamageFeedback:FireAllClients(model, dealt, blocked)
	NetCombat:FireAllClients("hit", effectPart, blocked, dealt, style, isBasic, attacker)
	SkillCombat.hit:Fire(attacker, model, dealt, blocked, humanoid.Health <= 0, wear)
	return true
end

-- shared alreadyHit so multi frame hitboxes only hit once
local function sample(
	attacker: Model, origin: CFrame, size: Vector3, alreadyHit: HitList, data: SkillData,
	ignore: IgnoreFilter?, modifiers: Modifiers?, radius: number?
)
	local box = if radius then Vector3.new(radius * 2, size.Y, radius * 2) else size
	local centre = origin.Position
	local params = OverlapParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { attacker }

	for _, part in ipairs(workspace:GetPartBoundsInBox(origin, box, params)) do
		local model, humanoid = bodyHit(part)
		if not model or not humanoid or alreadyHit[humanoid] then
			continue
		end
		-- radius checks ignore height
		local root = getRootPart(model)
		local isInside = if radius
			then root ~= nil and flatOffset(centre, root.Position).Magnitude <= radius
			else touches(origin, box, part)
		if isInside then
			strike(attacker, model, humanoid, part, alreadyHit, data, ignore, modifiers, centre)
		end
	end
end

-- validate the client point, v ~= v catches NaN
function SkillCombat.point(root: BasePart, position: any, reach: number): Vector3?
	if typeof(position) ~= "Vector3" or position ~= position then
		return nil
	end
	local offset = flatOffset(root.Position, position)
	if offset.Magnitude <= reach then
		return position
	end

	-- too far, clamp it and snap to the ground
	local clamped = root.Position + offset.Unit * reach
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { root.Parent :: Instance }
	local above = clamped + Vector3.new(0, 60, 0)
	local ground = workspace:Raycast(above, Vector3.new(0, -400, 0), params)
	return if ground then ground.Position else clamped
end

-- new hit list each tick so the field keeps hurting
local function fieldTick(cast: Cast, field: SkillData)
	local root = getCastRoot(cast)
	if root then
		local cframe = getCastOrigin(cast, root) * CFrame.new(0, 0, -field.forward)
		sample(cast.character, cframe, field.size, {}, field, cast.ignore, cast.modifiers)
	end
end

-- atAim hits go on the target spot, the rest go in front
local function meleeStep(
	cast: Cast, data: SkillData, size: Vector3, radius: number?, alreadyHit: HitList
)
	local root = getCastRoot(cast)
	if not root then
		return
	end
	local target = if data.atAim then cast.aimSpot else nil
	if data.atAim and not target and cast.pointFunction then
		target = SkillCombat.point(root, cast.pointFunction(), cast.skill.aimReach)
	end
	local rise = rawget(data, "rise") or 0
	local cframe = if target
		then CFrame.new(target)
		else getCastOrigin(cast, root) * CFrame.new(0, rise, -data.forward)
	sample(cast.character, cframe, size, alreadyHit, data, cast.ignore, cast.modifiers, radius)
end

-- sampled across the window so fast targets dont slip through
local function scheduleMeleeHit(cast: Cast, data: SkillData)
	-- charge scales the hitbox, radius hits scale radius/height instead
	local charge = if cast.modifiers then cast.modifiers.charge or 1 else 1
	local size = data.size * charge
	local radius = rawget(data, "radius")
	if radius then
		radius *= charge
		size = Vector3.new(radius * 2, (rawget(data, "height") or data.size.Y) * charge, radius * 2)
	end
	local alreadyHit = {}
	local lastSample = math.max(data.samples - 1, 1)
	for i = 0, data.samples - 1 do
		local at = data.at + data.window * (i / lastSample)
		task.delay(at, meleeStep, cast, data, size, radius, alreadyHit)
	end
end

-- everything gets scheduled off the skills frame timings
function SkillCombat.run(
	character: Model, humanoid: Humanoid, skill: SkillData, ignore: IgnoreFilter?,
	_aimFunction: (() -> any)?, pointFunction: (() -> any)?, modifiers: Modifiers?
)
	local cast: Cast = {
		character = character,
		humanoid = humanoid,
		skill = skill,
		ignore = ignore,
		modifiers = modifiers,
		pointFunction = pointFunction,
		isLocked = if rawget(skill, "lock") then true else false,
	}

	-- locked skills keep the aim from cast time
	local root = getRootPart(character)
	if cast.isLocked and modifiers and typeof(modifiers.origin) == "CFrame" then
		cast.lockedOrigin = modifiers.origin
	end
	if cast.isLocked and pointFunction and root then
		cast.aimSpot = SkillCombat.point(root, pointFunction(), skill.aimReach)
	end

	local field = rawget(skill, "field")
	if field then
		for i = 0, math.max(1, math.floor(field.duration / field.tick)) do
			task.delay(field.at + i * field.tick, fieldTick, cast, field)
		end
	end
	for _, data in ipairs(rawget(skill, "hits") or {}) do
		scheduleMeleeHit(cast, data)
	end
end

SkillCombat.applySlow = applySlow
SkillCombat.applyStun = applyStun
SkillCombat.buffOf = getBuff
SkillCombat.bodyHit = bodyHit
SkillCombat.touches = touches
SkillCombat.strike = strike
SkillCombat.sample = sample

return SkillCombat
