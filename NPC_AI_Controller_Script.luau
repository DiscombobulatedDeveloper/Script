-- Connected Discord-GitHub | Discord Username: Discombobulationary | Roblox Username: progaming_master2

local PathfindingService = game:GetService('PathfindingService')
local RunService          = game:GetService('RunService')

-- Global configuration settings to easily tweak NPC behavior and movement variables in one place
local CONFIG = {
	WANDER_RADIUS    = 80,
	IDLE_MIN         = 0.5,
	IDLE_MAX         = 3.0,
	SPEED_MIN        = 9,
	SPEED_MAX        = 17,
	WAYPOINT_TIMEOUT = 4,
	WAYPOINT_REACHED = 2.0,
	PATH_RETRIES     = 4,
	MAP_HALF_SIZE    = 95,
	OBSTACLE_SCAN_DIST  = 4,
	OBSTACLE_MAX_HEIGHT = 5,
	JUMP_COOLDOWN       = 1.5,
	IDLE_TURN_SPEED  = 4,
	CURVE_SUBDIVIDE  = 3,
	CURVE_JITTER     = 1.5,

	AVOID_RADIUS     = 7,
	AVOID_FORCE      = 0.6,
}

local npcFolder = workspace:WaitForChild('NPCFolder', 10)

-- Global pause switch handling so the entire system can be toggled externally if needed
local NPCPausedValue = game:GetService('ReplicatedStorage'):WaitForChild('NPCPaused')
local function getNPCPaused() return NPCPausedValue.Value end

-- Generates a random point within a circular radius to calculate the wander target vector
local function randomWanderTarget(origin)
	local angle   = math.random() * math.pi * 2
	local radius = math.sqrt(math.random()) * CONFIG.WANDER_RADIUS 
	local x = math.clamp(origin.X + math.cos(angle) * radius, -CONFIG.MAP_HALF_SIZE, CONFIG.MAP_HALF_SIZE)
	local z = math.clamp(origin.Z + math.sin(angle) * radius, -CONFIG.MAP_HALF_SIZE, CONFIG.MAP_HALF_SIZE)
	return Vector3.new(x, origin.Y, z)
end

-- Uses raycasting to snap the target vector to the actual ground geometry surface
local function getGroundY(pos)
	local rp = RaycastParams.new()
	rp.FilterType = Enum.RaycastFilterType.Exclude
	if npcFolder then rp.FilterDescendantsInstances = { npcFolder } end
	local ray = workspace:Raycast(Vector3.new(pos.X, pos.Y + 10, pos.Z), Vector3.new(0, -50, 0), rp)
	return ray and ray.Position.Y or 0
end

-- Math formula for calculating smooth curves between paths
local function catmullRom(p0, p1, p2, p3, t)
	local t2, t3 = t*t, t*t*t
	return 0.5 * (
		(2*p1) + (-p0+p2)*t +
			(2*p0 - 5*p1 + 4*p2 - p3)*t2 +
			(-p0 + 3*p1 - 3*p2 + p3)*t3
	)
end

-- Adds variations and curves to standard path nodes to make NPC movements look less robotic
local function curveWaypoints(waypoints)
	if #waypoints < 2 then return waypoints end
	local ctrl = {}
	for i, wp in ipairs(waypoints) do
		local jx = (i == 1 or i == #waypoints) and 0 or (math.random()-0.5)*2*CONFIG.CURVE_JITTER
		local jz = (i == 1 or i == #waypoints) and 0 or (math.random()-0.5)*2*CONFIG.CURVE_JITTER
		ctrl[i] = Vector3.new(wp.Position.X+jx, wp.Position.Y, wp.Position.Z+jz)
	end
	local function getCtrl(i)
		if i < 1 then return ctrl[1]-(ctrl[2]-ctrl[1]) end
		if i > #ctrl then return ctrl[#ctrl]+(ctrl[#ctrl]-ctrl[#ctrl-1]) end
		return ctrl[i]
	end
	local result = {}
	for i = 1, #ctrl-1 do
		local p0,p1,p2,p3 = getCtrl(i-1),getCtrl(i),getCtrl(i+1),getCtrl(i+2)
		for s = 0, CONFIG.CURVE_SUBDIVIDE-1 do
			local interp = catmullRom(p0, p1, p2, p3, s/CONFIG.CURVE_SUBDIVIDE)
			table.insert(result, { Position=interp, Action=waypoints[i].Action })
		end
	end
	table.insert(result, { Position=ctrl[#ctrl], Action=waypoints[#waypoints].Action })
	return result
end

-- Raycasts ahead of the NPC to dynamically check for dynamic obstacles and decide to jump or recalculate
local function checkObstacleAhead(hrp, targetPos)
	local dir = (targetPos - hrp.Position)
	dir = Vector3.new(dir.X, 0, dir.Z)
	if dir.Magnitude < 0.1 then return nil end
	dir = dir.Unit

	local rp = RaycastParams.new()
	if npcFolder then
		rp.FilterDescendantsInstances = { npcFolder }
	else
		rp.FilterDescendantsInstances = { hrp.Parent }
	end
	rp.FilterType = Enum.RaycastFilterType.Exclude

	local hit = workspace:Raycast(hrp.Position + Vector3.new(0,0.5,0), dir * CONFIG.OBSTACLE_SCAN_DIST, rp)
	if not hit then return nil end
	local topCheck = workspace:Raycast(
		hit.Position + Vector3.new(0, CONFIG.OBSTACLE_MAX_HEIGHT+2, 0),
		Vector3.new(0, -(CONFIG.OBSTACLE_MAX_HEIGHT+4), 0), rp)
	if not topCheck then return nil end
	local height = topCheck.Position.Y - (hrp.Position.Y - 3)
	if height <= 0.3 then return nil
	elseif height <= CONFIG.OBSTACLE_MAX_HEIGHT then return 'jump'
	else return 'skip' end
end

-- Checks neighboring agents within a folder to apply separation vectors so NPCs do not clip through each other
local function getCrowdAvoidanceVector(myHrp)
	if not npcFolder then return Vector3.zero end
	local avoidanceField = Vector3.zero
	local count = 0

	for _, otherNpc in ipairs(npcFolder:GetChildren()) do
		if otherNpc:IsA('Model') and otherNpc ~= myHrp.Parent then
			local otherHrp = otherNpc:FindFirstChild('HumanoidRootPart')
			if otherHrp then
				local diff = myHrp.Position - otherHrp.Position
				local dist = diff.Magnitude
				if dist > 0.1 and dist < CONFIG.AVOID_RADIUS then
					local force = (CONFIG.AVOID_RADIUS - dist) / CONFIG.AVOID_RADIUS
					avoidanceField = avoidanceField + (diff.Unit * force)
					count = count + 1
				end
			end
		end
	end

	if count > 0 then
		return Vector3.new(avoidanceField.X, 0, avoidanceField.Z).Unit * CONFIG.AVOID_FORCE
	end
	return Vector3.zero
end

local ANIM_IDS = {
	idle  = { 'rbxassetid://180435571', 'rbxassetid://180435792' },
	walk  = { 'rbxassetid://180426354' },
	jump  = { 'rbxassetid://125750702' },
	fall  = { 'rbxassetid://180436148' },
}

-- Simple animation manager wrapper using Humanoid Animator objects
local function buildAnimDriver(humanoid)
	local animator = humanoid:FindFirstChildOfClass('Animator')
	if not animator then
		animator = Instance.new('Animator')
		animator.Parent = humanoid
	end
	local tracks = {}
	for name, ids in pairs(ANIM_IDS) do
		tracks[name] = {}
		for _, id in ipairs(ids) do
			local a = Instance.new('Animation')
			a.AnimationId = id
			local t = animator:LoadAnimation(a)
			t.Priority = Enum.AnimationPriority.Core
			table.insert(tracks[name], t)
		end
	end
	local curAnim, curTrack = '', nil
	local driver = {}
	function driver:play(name, fade)
		if curAnim == name then return end
		local list = tracks[name]
		if not list or #list == 0 then return end
		if curTrack then curTrack:Stop(fade or 0.15) end
		local t = list[math.random(1,#list)]
		if t then
			t:Play(fade or 0.15)
			curAnim, curTrack = name, t
		end
	end
	return driver
end

-- Core lifecycle setup loop for initialization of an individual agent model
local function createAgent(npc)
	local humanoid = npc:FindFirstChildOfClass('Humanoid')
	local hrp = npc:FindFirstChild('HumanoidRootPart')
	if not humanoid or not hrp then
		warn('[NPC AI] ' .. npc.Name .. ' missing parts') return
	end

	-- Randomized stats give NPCs slightly different movement speeds
	humanoid.WalkSpeed = math.random(CONFIG.SPEED_MIN, CONFIG.SPEED_MAX)
	humanoid.JumpPower = 50

	local anim = buildAnimDriver(humanoid)
	local currentHumanoidState = Enum.HumanoidStateType.None

	-- Humanoid state connection listeners to seamlessly swap track priorities
	humanoid.Running:Connect(function(speed)
		if currentHumanoidState ~= Enum.HumanoidStateType.Freefall and currentHumanoidState ~= Enum.HumanoidStateType.Jumping then
			if speed > 0.5 then anim:play('walk', 0.1) else anim:play('idle', 0.2) end
		end
	end)

	humanoid.Jumping:Connect(function() 
		currentHumanoidState = Enum.HumanoidStateType.Jumping
		anim:play('jump', 0.05) 
	end)

	humanoid.FreeFalling:Connect(function(active)
		if active then
			currentHumanoidState = Enum.HumanoidStateType.Freefall
			task.delay(0.15, function()
				if humanoid and humanoid.Parent and currentHumanoidState == Enum.HumanoidStateType.Freefall then 
					anim:play('fall', 0.2) 
				end
			end)
		end
	end)

	humanoid.StateChanged:Connect(function(_, new)
		currentHumanoidState = new
		if new == Enum.HumanoidStateType.Landed or new == Enum.HumanoidStateType.Running then
			if not humanoid or not humanoid.Parent then return end
			if humanoid.MoveDirection.Magnitude > 0.1 then anim:play('walk', 0.1) else anim:play('idle', 0.2) end
		end
	end)

	anim:play('idle', 0)

	local agentParams = { AgentHeight=5, AgentRadius=2, AgentCanJump=true, AgentCanClimb=false, WaypointSpacing=4 }
	local spawnPos   = hrp.Position
	local lastJumpAt = 0
	local isIdle       = false

	-- Simulates natural head and body turning adjustments during periods of inactivity
	local idleTargetYaw = hrp.CFrame.LookVector
	local idleTurnConn
	local function startIdleTurn(targetDir)
		idleTargetYaw = targetDir
		if idleTurnConn then idleTurnConn:Disconnect() end
		idleTurnConn = RunService.Heartbeat:Connect(function(dt)
			if not hrp or not hrp.Parent or not isIdle then
				if idleTurnConn then idleTurnConn:Disconnect() end return
			end
			local cur   = hrp.CFrame.LookVector
			local flat = Vector3.new(idleTargetYaw.X, 0, idleTargetYaw.Z)
			if flat.Magnitude < 0.01 then return end
			flat = flat.Unit
			local blended = cur:Lerp(flat, math.min(dt * CONFIG.IDLE_TURN_SPEED, 1))
			if blended.Magnitude > 0.001 then
				hrp.CFrame = CFrame.lookAt(hrp.Position, hrp.Position + blended)
			end
		end)
	end

	-- Isolated asynchronous task routine driving the primary AI behavioral loop
	task.spawn(function()
		task.wait(math.random() * 2)

		while npc and npc.Parent and humanoid.Health > 0 do
			while getNPCPaused() do task.wait(0.1) end
			isIdle = false

			-- Attempts to generate valid path computations with a retry buffer to prevent instantly crashing on failure
			local destination, path, success = nil, nil, false
			for _ = 1, CONFIG.PATH_RETRIES do
				destination = randomWanderTarget(hrp.Position)
				destination = Vector3.new(destination.X, getGroundY(destination)+3, destination.Z)
				path = PathfindingService:CreatePath(agentParams)
				local ok = pcall(function() path:ComputeAsync(hrp.Position, destination) end)
				if ok and path.Status == Enum.PathStatus.Success then success=true break end
				task.wait(0.15)
			end
			if not success then task.wait(math.random(1, 2)) continue end

			local waypoints   = curveWaypoints(path:GetWaypoints())
			local pathAborted = false

			-- Waypoint iteration tracking loop handles individual target point translation
			for i, waypoint in ipairs(waypoints) do
				if i == 1 then continue end
				if not npc.Parent or humanoid.Health <= 0 then return end

				if waypoint.Action == Enum.PathWaypointAction.Jump then
					if tick()-lastJumpAt >= CONFIG.JUMP_COOLDOWN then
						humanoid.Jump = true
						lastJumpAt = tick()
					end
				end

				local startTime = tick()
				local reached   = false

				-- Keeps moving the NPC toward the current waypoint vector, adjusting for crowd avoidance forces along the way
				while not reached do
					RunService.Heartbeat:Wait()
					if not npc.Parent or humanoid.Health <= 0 then return end

					local flatHrp = Vector3.new(hrp.Position.X, 0, hrp.Position.Z)
					local flatWp = Vector3.new(waypoint.Position.X, 0, waypoint.Position.Z)

					local moveDir = (waypoint.Position - hrp.Position).Unit
					local separationForce = getCrowdAvoidanceVector(hrp)

					local blendedDirection = (moveDir + separationForce).Unit
					humanoid:Move(blendedDirection)

					if (flatHrp - flatWp).Magnitude <= CONFIG.WAYPOINT_REACHED then
						reached = true
					else
						local scanTarget = (i+1 <= #waypoints) and waypoints[i+1].Position or waypoint.Position
						local obs = checkObstacleAhead(hrp, scanTarget)
						if obs == 'jump' and tick()-lastJumpAt >= CONFIG.JUMP_COOLDOWN then
							humanoid.Jump = true
							lastJumpAt = tick()
						elseif obs == 'skip' then
							pathAborted = true break
						end
						if tick()-startTime > CONFIG.WAYPOINT_TIMEOUT then
							pathAborted = true break
						end
					end
				end
				if pathAborted then break end
			end

			-- Reset velocity and enter idle state sequence after successfully reaching a target destination
			humanoid:Move(Vector3.zero)
			isIdle = true
			local idleTime = CONFIG.IDLE_MIN + math.random()*(CONFIG.IDLE_MAX-CONFIG.IDLE_MIN)
			if math.random() < 0.5 then
				local a = math.random()*math.pi*2
				startIdleTurn(Vector3.new(math.cos(a), 0, math.sin(a)))
				task.wait(idleTime*0.45)
				if not npc.Parent then return end
				a = math.random()*math.pi*2
				startIdleTurn(Vector3.new(math.cos(a), 0, math.sin(a)))
				task.wait(idleTime*0.55)
			else
				task.wait(idleTime)
			end
		end
	end)
end

-- Scan the designated workspace directory to track existing entries and listen for future instances dynamically
local function initAllNPCs()
	if not npcFolder then warn('[NPC AI] NPCFolder not found') return end
	for _, npc in ipairs(npcFolder:GetChildren()) do
		if npc:IsA('Model') then
			task.delay(math.random()*2.0, function() createAgent(npc) end)
		end
	end
	npcFolder.ChildAdded:Connect(function(npc)
		if npc:IsA('Model') then task.delay(math.random()*0.5 + 0.2, function() createAgent(npc) end) end
	end)
end

task.delay(1, initAllNPCs)
print('[NPCAIController] Loaded - Flocking Avoidance & Jittered Paths Active')
