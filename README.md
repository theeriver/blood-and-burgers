# Blood and Burgers — NPC Patrol & Chase AI

## Setup in Roblox Studio

### 1. Place the script on your NPC

1. Open your game in Roblox Studio.
2. Select your **R15 NPC model** in the Explorer (it must have a `Humanoid`, `HumanoidRootPart`, and `Head`).
3. Insert a new **Script** (ServerScript) as a child of the NPC model.
4. Copy the contents of `src/ServerScripts/NPCPatrolChaseAI.server.luau` into that script.
5. Hit **Play** — the NPC will start patrolling immediately.

### 2. How it works

| State   | Behavior |
|---------|----------|
| **Patrol** | NPC picks random points within a configurable radius of its spawn location and walks to them using `PathfindingService`, avoiding walls and obstacles. It pauses briefly at each point before moving on. |
| **Chase**  | When a player enters the NPC's line-of-sight cone and is within range, the NPC switches to a sprint and pathfinds toward the player. It re-paths frequently to keep up with player movement. |
| **Return to Patrol** | If the player breaks line of sight for a configurable duration (default 3 seconds), the NPC gives up the chase and resumes patrolling. |

### 3. Configuration

All tunable values are in the `CONFIG` table at the top of the script:

| Setting | Default | Description |
|---------|---------|-------------|
| `PatrolRadius` | 60 | How far from spawn patrol points are chosen |
| `PatrolWalkSpeed` | 10 | Humanoid walk speed while patrolling |
| `PatrolPauseMIN` / `MAX` | 1 / 3 | Random pause range (seconds) at each patrol point |
| `SightRange` | 50 | Max detection distance (studs) |
| `SightAngle` | 120 | Field-of-view cone (degrees) |
| `DetectionInterval` | 0.25 | How often the NPC scans for players (seconds) |
| `ChaseRunSpeed` | 20 | Humanoid walk speed while chasing |
| `ChaseRePathDelay` | 0.3 | How often the path is recomputed during chase |
| `LoseTargetTime` | 3 | Seconds without line-of-sight before giving up |
| `AgentRadius` / `AgentHeight` | 2 / 5 | Pathfinding agent dimensions for obstacle avoidance |

### 4. Requirements

- The NPC must be an **R15** rig with standard parts (`HumanoidRootPart`, `Humanoid`, `Head`).
- The map should have collidable geometry so `PathfindingService` can generate valid navmeshes.
- The script runs on the **server** — no client-side setup needed.
