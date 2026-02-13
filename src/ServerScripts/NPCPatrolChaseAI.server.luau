--[[
	NPCPatrolChaseAI.server.luau

	Place this Script inside an R15 NPC model that has:
	  - A HumanoidRootPart
	  - A Humanoid
	  - A Head (used for line-of-sight raycasting)

	The NPC will:
	  1. Randomly patrol the map using PathfindingService (avoids walls/objects).
	  2. Continuously scan for nearby players.
	  3. Chase any player it can see within range.
	  4. Return to patrolling when the player breaks line of sight or escapes.

	Movement is driven by RunService.Heartbeat for smooth, frame-level updates.
	The NPC advances to the next waypoint by proximity (no stopping between
	waypoints) and skips waypoints it has already passed.
--]]

local PathfindingService = game:GetService("PathfindingService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

--------------------------
-- CONFIGURATION
--------------------------
local CONFIG = {
	-- Patrol
	PatrolRadius       = 60,    -- how far from spawn it picks random patrol points
	PatrolWalkSpeed    = 10,    -- walk speed while patrolling
	PatrolPauseMIN     = 1,     -- min seconds to pause at each patrol waypoint
	PatrolPauseMAX     = 3,     -- max seconds to pause at each patrol waypoint

	-- Detection
	SightRange         = 50,    -- max distance the NPC can see a player
	SightAngle         = 120,   -- field-of-view cone in degrees (total, centered on look direction)
	DetectionInterval  = 0.25,  -- how often (seconds) the NPC checks for players

	-- Chase
	ChaseRunSpeed      = 20,    -- run speed while chasing
	ChaseRePathDelay   = 0.3,   -- how often to recalculate path while chasing
	LoseTargetTime     = 3,     -- seconds of no line-of-sight before giving up chase

	-- Smooth movement
	WaypointReachDist  = 4,     -- how close (studs) to a waypoint before advancing to next
	SpeedLerpRate      = 4,     -- how fast WalkSpeed transitions (higher = snappier)
	StuckTimeout       = 3,     -- seconds without progress before picking a new path

	-- Pathfinding agent parameters (R15 rig dimensions)
	AgentRadius        = 2,
	AgentHeight        = 5,
	AgentCanJump       = true,
}

--------------------------
-- REFERENCES
--------------------------
local npc = script.Parent
local humanoid: Humanoid = npc:WaitForChild("Humanoid")
local rootPart: BasePart = npc:WaitForChild("HumanoidRootPart")
local head: BasePart = npc:WaitForChild("Head")

local spawnPosition = rootPart.Position

local raycastParams = RaycastParams.new()
raycastParams.FilterType = Enum.RaycastFilterType.Exclude
raycastParams.FilterDescendantsInstances = {npc}

--------------------------
-- STATE
--------------------------
local currentState: string = "Patrol"  -- "Patrol" | "Chase"
local currentTarget: Player? = nil
local lastSeenTime: number = 0

local targetSpeed: number = CONFIG.PatrolWalkSpeed
local alive: boolean = true

--------------------------
-- HELPERS
--------------------------

local function createPath(): Path
	return PathfindingService:CreatePath({
		AgentRadius = CONFIG.AgentRadius,
		AgentHeight = CONFIG.AgentHeight,
		AgentCanJump = CONFIG.AgentCanJump,
	})
end

--- Pick a random walkable point near the spawn position.
local function getRandomPatrolPoint(): Vector3
	local angle = math.random() * math.pi * 2
	local dist = math.random() * CONFIG.PatrolRadius
	return spawnPosition + Vector3.new(
		math.cos(angle) * dist,
		0,
		math.sin(angle) * dist
	)
end

--- Check whether the NPC has a clear line of sight to a position.
local function hasLineOfSight(targetPosition: Vector3): boolean
	local origin = head.Position
	local direction = targetPosition - origin
	local result = workspace:Raycast(origin, direction, raycastParams)

	if result then
		local distToTarget = direction.Magnitude
		local distToHit = (result.Position - origin).Magnitude
		return distToHit >= distToTarget - 1
	end

	return true
end

--- Check if a target position is within the NPC's field-of-view cone.
local function isInFieldOfView(targetPosition: Vector3): boolean
	local toTarget = (targetPosition - head.Position).Unit
	local lookDir = head.CFrame.LookVector
	local dotProduct = lookDir:Dot(toTarget)
	local halfAngleRad = math.rad(CONFIG.SightAngle / 2)
	return dotProduct >= math.cos(halfAngleRad)
end

--- Find the closest visible player within detection range.
local function findVisibleTarget(): Player?
	local closestPlayer: Player? = nil
	local closestDist = CONFIG.SightRange + 1

	for _, player in Players:GetPlayers() do
		local character = player.Character
		if not character then continue end

		local targetRoot = character:FindFirstChild("HumanoidRootPart")
		local targetHumanoid = character:FindFirstChild("Humanoid") :: Humanoid?
		if not targetRoot or not targetHumanoid then continue end
		if targetHumanoid.Health <= 0 then continue end

		local dist = (targetRoot.Position - rootPart.Position).Magnitude
		if dist > CONFIG.SightRange then continue end
		if not isInFieldOfView(targetRoot.Position) then continue end
		if not hasLineOfSight(targetRoot.Position) then continue end

		if dist < closestDist then
			closestDist = dist
			closestPlayer = player
		end
	end

	return closestPlayer
end

--- Horizontal distance only (ignores Y), used for waypoint reach checks
--- so slopes/stairs don't cause the NPC to overshoot waypoints.
local function horizontalDist(a: Vector3, b: Vector3): number
	local dx = a.X - b.X
	local dz = a.Z - b.Z
	return math.sqrt(dx * dx + dz * dz)
end

--- Find the furthest waypoint the NPC can skip ahead to.
--- This prevents the NPC from backtracking to waypoints it already passed.
local function getNextWaypointIndex(waypoints: {PathWaypoint}, currentIndex: number): number
	local best = currentIndex
	for i = currentIndex, math.min(currentIndex + 3, #waypoints) do
		local dist = horizontalDist(rootPart.Position, waypoints[i].Position)
		if dist < CONFIG.WaypointReachDist then
			best = math.min(i + 1, #waypoints)
		end
	end
	return best
end

--- Smoothly follow a set of waypoints using MoveTo, advancing by proximity
--- instead of waiting for MoveToFinished. Returns true if we reached the end.
local function followPathSmooth(waypoints: {PathWaypoint}, checkInterrupt: () -> boolean): boolean
	if #waypoints < 2 then return true end

	local waypointIndex = 2
	local lastPosition = rootPart.Position
	local lastProgressTime = tick()

	while waypointIndex <= #waypoints do
		if checkInterrupt() then return false end
		if not alive then return false end

		-- Skip ahead past any waypoints we've already reached
		waypointIndex = getNextWaypointIndex(waypoints, waypointIndex)
		if waypointIndex > #waypoints then break end

		local waypoint = waypoints[waypointIndex]

		-- Handle jump waypoints
		if waypoint.Action == Enum.PathWaypointAction.Jump then
			humanoid.Jump = true
		end

		-- Issue MoveTo — Humanoid will walk toward this point
		humanoid:MoveTo(waypoint.Position)

		-- Check if we've reached this waypoint
		local dist = horizontalDist(rootPart.Position, waypoint.Position)
		if dist < CONFIG.WaypointReachDist then
			waypointIndex += 1
			lastProgressTime = tick()
		end

		-- Stuck detection: if we haven't made meaningful progress, bail out
		local moved = (rootPart.Position - lastPosition).Magnitude
		if moved > 0.5 then
			lastPosition = rootPart.Position
			lastProgressTime = tick()
		elseif tick() - lastProgressTime > CONFIG.StuckTimeout then
			return false
		end

		-- Yield one frame — keeps movement smooth at Heartbeat rate
		RunService.Heartbeat:Wait()
	end

	return true
end

--- Smoothly lerp WalkSpeed toward the target each frame.
local function setTargetSpeed(speed: number)
	targetSpeed = speed
end

--------------------------
-- SMOOTH SPEED LERP (runs every frame)
--------------------------

RunService.Heartbeat:Connect(function(dt)
	if not alive then return end
	local diff = targetSpeed - humanoid.WalkSpeed
	if math.abs(diff) < 0.1 then
		humanoid.WalkSpeed = targetSpeed
	else
		humanoid.WalkSpeed += diff * math.min(CONFIG.SpeedLerpRate * dt, 1)
	end
end)

--------------------------
-- PATROL BEHAVIOR
--------------------------

local function patrol()
	currentState = "Patrol"
	setTargetSpeed(CONFIG.PatrolWalkSpeed)

	while currentState == "Patrol" do
		local destination = getRandomPatrolPoint()
		local path = createPath()

		local success = pcall(function()
			path:ComputeAsync(rootPart.Position, destination)
		end)

		if success and path.Status == Enum.PathStatus.Success then
			local waypoints = path:GetWaypoints()
			local completed = followPathSmooth(waypoints, function()
				return currentState ~= "Patrol"
			end)

			if completed and currentState == "Patrol" then
				-- Pause briefly at the destination
				local pauseTime = CONFIG.PatrolPauseMIN
					+ math.random() * (CONFIG.PatrolPauseMAX - CONFIG.PatrolPauseMIN)

				-- Interruptible wait (don't block the whole pause duration)
				local waited = 0
				while waited < pauseTime and currentState == "Patrol" do
					local dt = RunService.Heartbeat:Wait()
					waited += dt
				end
			end
		else
			task.wait(0.5)
		end
	end
end

--------------------------
-- CHASE BEHAVIOR
--------------------------

local function chase(target: Player)
	currentState = "Chase"
	currentTarget = target
	setTargetSpeed(CONFIG.ChaseRunSpeed)
	lastSeenTime = tick()

	local lastRepath = 0

	while currentState == "Chase" do
		local character = target.Character
		if not character then break end

		local targetRoot = character:FindFirstChild("HumanoidRootPart")
		local targetHumanoid = character:FindFirstChild("Humanoid") :: Humanoid?
		if not targetRoot or not targetHumanoid or targetHumanoid.Health <= 0 then
			break
		end

		-- Check line of sight
		if hasLineOfSight(targetRoot.Position) then
			lastSeenTime = tick()
		elseif tick() - lastSeenTime >= CONFIG.LoseTargetTime then
			break
		end

		-- Compute a fresh path periodically
		if tick() - lastRepath >= CONFIG.ChaseRePathDelay then
			lastRepath = tick()

			local path = createPath()
			local success = pcall(function()
				path:ComputeAsync(rootPart.Position, targetRoot.Position)
			end)

			if success and path.Status == Enum.PathStatus.Success then
				local waypoints = path:GetWaypoints()

				-- Follow a few waypoints smoothly, then re-path
				-- (limits how long we commit to a stale path)
				local maxWaypoints = math.min(#waypoints, 6)
				local trimmed = {}
				for i = 1, maxWaypoints do
					trimmed[i] = waypoints[i]
				end

				followPathSmooth(trimmed, function()
					-- Interrupt if state changed OR it's time to re-path
					if currentState ~= "Chase" then return true end
					if tick() - lastRepath >= CONFIG.ChaseRePathDelay then return true end
					return false
				end)
			else
				-- Path failed — move directly toward player
				humanoid:MoveTo(targetRoot.Position)
				RunService.Heartbeat:Wait()
			end
		else
			-- Between re-paths, keep walking toward the player directly
			-- for a single frame so movement never stalls
			humanoid:MoveTo(targetRoot.Position)
			RunService.Heartbeat:Wait()
		end
	end

	-- Chase ended — smoothly transition back to patrol
	currentTarget = nil
	patrol()
end

--------------------------
-- DETECTION LOOP
--------------------------

task.spawn(function()
	while alive do
		task.wait(CONFIG.DetectionInterval)

		if humanoid.Health <= 0 then break end

		if currentState == "Patrol" then
			local target = findVisibleTarget()
			if target then
				currentState = "Chase"
				task.defer(chase, target)
			end
		elseif currentState == "Chase" and currentTarget then
			local newTarget = findVisibleTarget()
			if newTarget and newTarget ~= currentTarget then
				local currentChar = currentTarget.Character
				local newChar = newTarget.Character
				if currentChar and newChar then
					local currentRoot = currentChar:FindFirstChild("HumanoidRootPart")
					local newRoot = newChar:FindFirstChild("HumanoidRootPart")
					if currentRoot and newRoot then
						local currentDist = (currentRoot.Position - rootPart.Position).Magnitude
						local newDist = (newRoot.Position - rootPart.Position).Magnitude
						if newDist < currentDist then
							currentTarget = newTarget
						end
					end
				end
			end
		end
	end
end)

--------------------------
-- ENTRY POINT
--------------------------

npc.AncestryChanged:Connect(function()
	if not npc:IsDescendantOf(workspace) then
		currentState = "None"
		alive = false
	end
end)

humanoid.Died:Connect(function()
	currentState = "None"
	alive = false
end)

patrol()
