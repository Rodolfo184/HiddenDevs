local Players           = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")

local NetConfig        = require(RS.Remotes:WaitForChild("NetConfig"))
local CC = require(RS.Modules:WaitForChild("CombatController"))
local remoteFolder     = RS:WaitForChild("Remotes")

local _acOk, _ACManager = pcall(function()
	return require(game:GetService("ServerScriptService"):WaitForChild("Modules"):WaitForChild("AntiCheat"):WaitForChild("Manager"))
end)
local _bpOk, _BypassManager = pcall(function()
	return require(game:GetService("ServerScriptService"):WaitForChild("Modules"):WaitForChild("AntiCheat"):WaitForChild("BypassManager"))
end)

local function cleanStaleRemotes()
	local stale = remoteFolder:FindFirstChild("CombatRemotes")
	if stale then stale:Destroy() end

	local function ensureType(name: string, className: string): Instance
		local existing = remoteFolder:FindFirstChild(name)
		if existing and not existing:IsA(className) then existing:Destroy(); existing = nil end
		if not existing then
			existing = Instance.new(className, remoteFolder)
			existing.Name = name
		end
		return existing
	end

	ensureType(NetConfig.BridgeName, "RemoteEvent")
	local folder = ensureType(NetConfig.FolderName, "Folder")

	for _, name in ipairs({ NetConfig.CombatSub1, NetConfig.CombatSub2, NetConfig.CombatSub3 }) do
		if name then
			local r = folder:FindFirstChild(name) or Instance.new("RemoteEvent", folder)
			r.Name = name
		end
	end
end
cleanStaleRemotes()

local bridge = remoteFolder:WaitForChild(NetConfig.BridgeName) :: RemoteEvent

--\\Actions//

local ACTION_COOLDOWNS = {
	M1           = 0.15,
	Crit         = 0.3,
	Parry        = 0.2,
	GuardDown    = 0.08,
	GuardUp      = 0.05,
	Feint        = 0.1,
	Equip        = 0.15,
	Unequip      = 0.15,
}
local DEFAULT_CD = 0.05

local ACTION_MAP: { [any]: string } = {
	[NetConfig.v1]  = "M1",
	[NetConfig.v2]  = "Crit",
	[NetConfig.v3]  = "Parry",
	[NetConfig.v5]  = "GuardDown",
	[NetConfig.v6]  = "GuardUp",
	[NetConfig.v7]  = "Feint",
	[NetConfig.v8]  = "Equip",
	[NetConfig.v9]  = "Unequip",
}

-- Per-player action timestamps:  playerCooldowns[player][actionName] = lastTime
local playerCooldowns: { [Player]: { [string]: number } } = {}

local function checkCooldown(player: Player, actionName: string): boolean
	local now = os.clock()
	local map = playerCooldowns[player]
	if not map then
		map = {}
		playerCooldowns[player] = map
	end
	local last = map[actionName] or 0
	local cd   = ACTION_COOLDOWNS[actionName] or DEFAULT_CD
	if now - last < cd then return false end
	map[actionName] = now
	return true
end

--\\Tool Validation//--

local function resolveToolForPlayer(player: Player, candidate: any): Tool?
	local character = player.Character
	if not character then return nil end

	local function owns(tool: Tool): boolean
		return tool:IsDescendantOf(character)
			or (player:FindFirstChild("Backpack") and tool:IsDescendantOf(player.Backpack))
	end

	-- Prefer explicitly-passed tool
	if typeof(candidate) == "Instance" and candidate:IsA("Tool") and owns(candidate) then
		return candidate
	end

	-- Fall back to currently held tool
	local held = character:FindFirstChildOfClass("Tool")
	if held and owns(held) then return held end

	return nil
end


bridge.OnServerEvent:Connect(function(player: Player, actionId: any, extraData: any)
	-- Basic sanity checks
	if not player:IsDescendantOf(Players) then return end
	local character = player.Character
	if not character then return end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 then return end

	local actionName = ACTION_MAP[actionId]
	if not actionName then return end
	if not checkCooldown(player, actionName) then return end

	-- Only create a controller if one already exists (creation happens in CharacterAdded)
	local controller = CC.fromCharacter(character)
	if not controller then return end

	local tool = resolveToolForPlayer(player, extraData)

	-- Dispatch
	if actionName == "M1" then
		if tool then controller:doM1(tool) end

	elseif actionName == "Crit" then
		if tool then controller:doCrit(tool) end

	elseif actionName == "GuardDown" then
		if tool then controller:guardPressed(tool) end

	elseif actionName == "GuardUp" then
		controller:guardReleased()

	elseif actionName == "Feint" then
		controller:doFeint()

	elseif actionName == "Equip" then
		if tool then controller:onEquip(tool) end

	elseif actionName == "Unequip" then
		controller:onUnequip()

	elseif actionName == "Parry" then
		if tool then
			controller:doParry(tool)
		end
	end
end)


local _legacyMove = remoteFolder:FindFirstChild("UpdateMovementState")
if _legacyMove then _legacyMove.Name = NetConfig.O.UpdateMovementState end
local updateRemote = remoteFolder:FindFirstChild(NetConfig.O.UpdateMovementState, true)
	or remoteFolder:WaitForChild(NetConfig.O.UpdateMovementState, 10)

if updateRemote then

	local MOVE_MIN_INTERVAL = 0.05   -- <= ~20 applied changes/sec PER KEY per player
	local moveDebounce = {}
	Players.PlayerRemoving:Connect(function(p) moveDebounce[p] = nil end)

	local function applyMoveState(player, attrName, value)
		local character = player.Character
		if not character then return end
		if character:GetAttribute(attrName) == value then return end   -- no-op coalescing
		if attrName == "IsDashing" and value == true and _acOk and _ACManager then
			if not _ACManager.onDashFlip(player, true) then return end   -- AC dash-cooldown gate
		end
		character:SetAttribute(attrName, value)
		local controller = CC.fromCharacter(character)
		if not controller then return end
		if not controller.Humanoid or controller.Humanoid.Health <= 0 then return end
		if attrName == "IsRunning" then
			controller:setRunning(value)
		elseif attrName ~= "Momentum" then
			controller:updateMovement()
		end
	end

	updateRemote.OnServerEvent:Connect(function(player: Player, attrName: string, value: any)
		if attrName ~= "IsRunning" and attrName ~= "IsDashing" and attrName ~= "CombatLegLean" and attrName ~= "Momentum" then return end
		if value ~= nil and typeof(value) ~= "boolean" then return end
		if not player.Character then return end

		local pmap = moveDebounce[player]
		if not pmap then pmap = {}; moveDebounce[player] = pmap end
		local st = pmap[attrName]
		if not st then st = { last = 0 }; pmap[attrName] = st end

		st.pending = value
		local now = os.clock()
		if now - st.last >= MOVE_MIN_INTERVAL then
			st.last = now
			applyMoveState(player, attrName, st.pending)
		elseif not st.scheduled then
			st.scheduled = true
			task.delay(MOVE_MIN_INTERVAL - (now - st.last), function()
				st.scheduled = false
				st.last = os.clock()
				applyMoveState(player, attrName, st.pending)   -- always the LATEST value (never lost)
			end)
		end
	end)
end


local function onCharacterAdded(character: Model)
	-- create controller so its ready before the first action fires
	CC.new(character)
end

local function onCharacterRemoving(character: Model)
	CC.remove(character)
end

local function onPlayerAdded(player: Player)
	playerCooldowns[player] = {}

	-- guard against characters that loaded before this script
	if player.Character then
		onCharacterAdded(player.Character)
	end

	player.CharacterAdded:Connect(onCharacterAdded)
	player.CharacterRemoving:Connect(onCharacterRemoving)
end

local function onPlayerRemoving(player: Player)
	playerCooldowns[player] = nil
end

-- handle players already in-game when the script starts
for _, player in ipairs(Players:GetPlayers()) do
	task.spawn(onPlayerAdded, player)
end

Players.PlayerAdded:Connect(onPlayerAdded)
Players.PlayerRemoving:Connect(onPlayerRemoving)
