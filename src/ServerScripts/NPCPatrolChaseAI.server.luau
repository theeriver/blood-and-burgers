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
--]]

local PathfindingService = game:GetService("PathfindingService")
local Players = game:GetService("Players")

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

-- Parts belonging to the NPC (excluded from raycasts)
local npcDescendants = npc:GetDescendants()
local raycastParams = RaycastParams.new()
raycastParams.FilterType = Enum.RaycastFilterType.Exclude
raycastParams.FilterDescendantsInstances = {npc}

--------------------------
-- STATE
--------------------------
local currentState: string = "Patrol"  -- "Patrol" | "Chase"
local currentTarget: Player? = nil
local lastSeenTime: number = 0
local currentPath: Path? = nil

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
		-- Something is in the way — check distance. If the hit is beyond
		-- the target it means nothing blocked the path.
		local distToTarget = direction.Magnitude
		local distToHit = (result.Position - origin).Magnitude
		return distToHit >= distToTarget - 1
	end

	-- Nothing hit at all — clear line of sight
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

--- Walk along a computed path. Returns true if the NPC reached the end,
--- false if it was interrupted (state changed).
local function followPath(path: Path, checkInterrupt: () -> boolean): boolean
	local waypoints = path:GetWaypoints()

	for i = 2, #waypoints do
		if checkInterrupt() then
			return false
		end

		local waypoint = waypoints[i]

		if waypoint.Action == Enum.PathWaypointAction.Jump then
			humanoid.Jump = true
		end

		humanoid:MoveTo(waypoint.Position)

		-- Wait for the NPC to reach the waypoint or get stuck
		local reached = humanoid.MoveToFinished:Wait()
		if not reached then
			-- Stuck — break out so we can pick a new destination
			return false
		end
	end

	return true
end

--------------------------
-- PATROL BEHAVIOR
--------------------------

local function patrol()
	currentState = "Patrol"
	humanoid.WalkSpeed = CONFIG.PatrolWalkSpeed

	while currentState == "Patrol" do
		local destination = getRandomPatrolPoint()
		local path = createPath()

		local success, err = pcall(function()
			path:ComputeAsync(rootPart.Position, destination)
		end)

		if success and path.Status == Enum.PathStatus.Success then
			local completed = followPath(path, function()
				return currentState ~= "Patrol"
			end)

			if completed and currentState == "Patrol" then
				-- Pause briefly at the destination
				local pauseTime = CONFIG.PatrolPauseMIN
					+ math.random() * (CONFIG.PatrolPauseMAX - CONFIG.PatrolPauseMIN)
				task.wait(pauseTime)
			end
		else
			-- Path failed — try a different point next loop
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
	humanoid.WalkSpeed = CONFIG.ChaseRunSpeed
	lastSeenTime = tick()

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
		else
			-- Lost sight — check if we've exceeded the give-up timer
			if tick() - lastSeenTime >= CONFIG.LoseTargetTime then
				break
			end
		end

		-- Compute path toward player's current position
		local path = createPath()
		local success, err = pcall(function()
			path:ComputeAsync(rootPart.Position, targetRoot.Position)
		end)

		if success and path.Status == Enum.PathStatus.Success then
			local waypoints = path:GetWaypoints()

			for i = 2, math.min(#waypoints, 4) do
				if currentState ~= "Chase" then break end

				local waypoint = waypoints[i]
				if waypoint.Action == Enum.PathWaypointAction.Jump then
					humanoid.Jump = true
				end

				humanoid:MoveTo(waypoint.Position)

				-- Don't wait for the full MoveToFinished — re-path frequently
				local startTime = tick()
				while tick() - startTime < CONFIG.ChaseRePathDelay do
					-- Check if target moved significantly; if so, break early to re-path
					if not target.Character then break end
					local newRoot = target.Character:FindFirstChild("HumanoidRootPart")
					if newRoot then
						local distToWaypoint = (waypoint.Position - rootPart.Position).Magnitude
						if distToWaypoint < 2 then break end
					end
					task.wait(0.05)
				end
			end
		else
			-- Path failed — try moving directly toward last known position
			humanoid:MoveTo(targetRoot.Position)
			task.wait(CONFIG.ChaseRePathDelay)
		end
	end

	-- Chase ended — go back to patrol
	currentTarget = nil
	patrol()
end

--------------------------
-- DETECTION LOOP
--------------------------

task.spawn(function()
	while true do
		task.wait(CONFIG.DetectionInterval)

		if humanoid.Health <= 0 then break end

		if currentState == "Patrol" then
			local target = findVisibleTarget()
			if target then
				-- Interrupt patrol and start chasing
				currentState = "Chase"
				task.defer(chase, target)
			end
		elseif currentState == "Chase" and currentTarget then
			-- While chasing, check if a closer player is now visible
			local newTarget = findVisibleTarget()
			if newTarget and newTarget ~= currentTarget then
				-- Switch targets if the new one is closer
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

-- Clean up if the NPC is destroyed
npc.AncestryChanged:Connect(function()
	if not npc:IsDescendantOf(workspace) then
		currentState = "None"
	end
end)

-- Also stop if the NPC dies
humanoid.Died:Connect(function()
	currentState = "None"
end)

-- Start patrolling
patrol()
