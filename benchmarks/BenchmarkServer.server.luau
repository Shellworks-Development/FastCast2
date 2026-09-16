--[[
	FastCast2 Server Benchmark
	Author: Mawin CK
	Date: 2026

	Interactive server benchmark.
	Type single letters in chat to control the benchmark.

	Commands:
		p  - Start benchmark
		l  - +500 projectiles
		k  - -500 projectiles
		u  - Toggle Instanced / Instanceless
		j  - Toggle BulkMoveTo / Motor6D
		y  - Toggle ObjectCache
		v  - Toggle Cast Visualization
		x  - Cycle HighFidelityBehavior
		>  - Increase HighFidelitySegmentSize
		<  - Decrease HighFidelitySegmentSize
		]  - Increase workers
		[  - Decrease workers
		i  - Show benchmark information
		h  - Show help
]]

--// Services

local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Players = game:GetService("Players")

--// Configuration

local Config = {
	NumWorkers = 4,

	Instanced = false,
	MovementMode = "BulkMoveTo",
	ObjectCacheEnabled = false,
	ProjectileAmount = 500,
	VisualizeCasts = false,

	Velocity = 6,

	BenchmarkDuration = 6,

	VMName = "CastVMs",
	VMContainerName = "CastVMContainer",
	VMTemplateName = "CastVM",

	ProjectileStep = 500,

	WorkerStep = 1,
	MinWorkers = 2,

	SegmentSizeStep = 0.05,
	MinSegmentSize = 0.05,
}

--// Constants
local NUM_WORKERS_CHANGE_COOLDOWN = 4.5
local BENCHMARK_COOLDOWN = 2.5

--// Modules

local FastCastModule = ReplicatedStorage:WaitForChild("FastCast2")

local FastCast = require(FastCastModule)
local FastCastEnums = require(
	FastCastModule:WaitForChild("FastCastEnums")
)

--// Projectile Objects

local ProjectileContainer = Instance.new("Folder")
ProjectileContainer.Name = "FastCast2PJ_Parallel"
ProjectileContainer.Parent = workspace

local ProjectileTemplate = Instance.new("Part")
ProjectileTemplate.Name = "Projectile"
ProjectileTemplate.Size = Vector3.one
ProjectileTemplate.Position = Vector3.one

ProjectileTemplate.Anchored = true
ProjectileTemplate.CanCollide = false
ProjectileTemplate.CanQuery = false
ProjectileTemplate.CanTouch = false
ProjectileTemplate.Massless = true

ProjectileTemplate.Parent = ReplicatedStorage

--// Raycast Parameters

local CastParams = RaycastParams.new()
CastParams.FilterType = Enum.RaycastFilterType.Exclude
CastParams.IgnoreWater = true

--// Cast Behavior

local CastBehavior = FastCast.newBehavior()

CastBehavior.MaxDistance = 1e9
CastBehavior.RaycastParams = CastParams

CastBehavior.HighFidelityBehavior =
	FastCastEnums.HighFidelityBehavior.Default

CastBehavior.HighFidelitySegmentSize = 1
CastBehavior.Acceleration = Vector3.zero

CastBehavior.AutoIgnoreContainer = true

CastBehavior.CosmeticBulletContainer = ProjectileContainer
CastBehavior.CosmeticBulletTemplate =
	Config.Instanced and ProjectileTemplate or nil

CastBehavior.VisualizeCasts = Config.VisualizeCasts

--// State

local Caster
local ActiveCasts = {}

local IsBenchmarking = false
local IsReconfiguring = false

--// FPS Tracking

local FPS = {
	Current = 0,
	Average = 0,
	Minimum = math.huge,
	Maximum = 0,

	Accumulator = 0,
	FrameCount = 0,
}

local function resetFPS()
	FPS.Current = 0
	FPS.Average = 0
	FPS.Minimum = math.huge
	FPS.Maximum = 0

	FPS.Accumulator = 0
	FPS.FrameCount = 0
end

local function updateFPS(dt)
	if dt <= 0 then
		return
	end

	local current = 1 / dt

	FPS.Current = current
	FPS.Minimum = math.min(FPS.Minimum, current)
	FPS.Maximum = math.max(FPS.Maximum, current)

	FPS.Accumulator += current
	FPS.FrameCount += 1

	-- Keep a continuously updated average.
	FPS.Average = FPS.Accumulator / FPS.FrameCount
end

RunService.Heartbeat:Connect(function(dt)
	updateFPS(dt)
end)

--// Utility

local function getHighFidelityName()
	local behavior = CastBehavior.HighFidelityBehavior

	if behavior == FastCastEnums.HighFidelityBehavior.Default then
		return "Default"
	elseif behavior == FastCastEnums.HighFidelityBehavior.Automatic then
		return "Automatic"
	else
		return "Always"
	end
end

local function getObjectCacheState()
	if not Caster then
		return false
	end

	if Caster.ObjectCacheEnabled then
		return true
	end

	if Caster.BaseCast and Caster.BaseCast.ObjectCacheInstance then
		return true
	end

	return false
end

local function getModeName()
	return Config.Instanced and "Instanced" or "Instanceless"
end

local function printSection(title)
	print(("=== %s ==="):format(title))
end

--// Cast Tracking

local function onCastFire(cast)
	ActiveCasts[#ActiveCasts + 1] = cast
end

--// Caster Creation

local function createCaster()
	local caster = FastCast.newParallel()

	caster:Init(
		Config.NumWorkers,
		ServerScriptService,
		Config.VMName,
		ServerScriptService,
		Config.VMContainerName,
		Config.VMTemplateName,
		Config.MovementMode
	)

	caster.CastFire = onCastFire

	return caster
end

local function applyObjectCache()
	if not Caster then
		return
	end

	if not Config.ObjectCacheEnabled then
		Caster:SetObjectCacheEnabled(false)
		return
	end

	Caster:SetObjectCacheEnabled(
		true,
		ProjectileTemplate,
		Config.ProjectileAmount,
		ProjectileContainer
	)
end

--// Cast Cleanup

local function terminateActiveCasts()
	for i = #ActiveCasts, 1, -1 do
		task.spawn(function()
			local cast = ActiveCasts[i]

			if cast then
				FastCast:TerminateCast(cast)
			end

			ActiveCasts[i] = nil
		end)
	end
end

local function destroyCaster()
	if not Caster then
		return
	end

	terminateActiveCasts()

	Caster:Destroy()
	Caster = nil

	table.clear(ActiveCasts)
end

local function rebuildCaster()
	destroyCaster()

	Caster = createCaster()
	applyObjectCache()
end

--// Benchmark Information

local function printBenchmarkInfo()
	printSection("PARALLEL MODE BENCHMARK")

	print(("ProjectileAmount: %d"):format(
		Config.ProjectileAmount
		))

	print(("Velocity: %.2f"):format(
		Config.Velocity
		))

	print(("ObjectCache: %s"):format(
		getObjectCacheState() and "Enabled" or "Disabled"
		))

	print(("VisualizeCasts: %s"):format(
		CastBehavior.VisualizeCasts and "Enabled" or "Disabled"
		))

	print(("HighFidelityBehavior: %s"):format(
		getHighFidelityName()
		))

	print(("HighFidelitySegmentSize: %.2f"):format(
		CastBehavior.HighFidelitySegmentSize
		))

	print(("MovementMode: %s"):format(
		Config.MovementMode
		))

	print(("Mode: %s"):format(
		getModeName()
		))

	print(("numWorkers: %d"):format(
		Config.NumWorkers
		))
end

--// FPS Output

local function printFPS()
	local minimum = FPS.Minimum

	if minimum == math.huge then
		minimum = 0
	end

	local delta = FPS.Current > 0
		and (1000 / FPS.Current)
		or 0

	print(("Delta: %.2f ms"):format(delta))
	print(("Average FPS: %.2f"):format(FPS.Average))
	print(("Max FPS: %.2f"):format(FPS.Maximum))
	print(("Min FPS: %.2f"):format(minimum))
end

--// Projectile Generation

local function randomDirection()
	return Vector3.new(
		math.random() * 2 - 1,
		math.random() * 2 - 1,
		math.random() * 2 - 1
	).Unit
end

local function fireProjectile()
	local origin = Vector3.new(
		math.random(-100, 100),
		math.random(0, 100),
		math.random(-100, 100)
	)

	Caster:RaycastFire(
		origin,
		randomDirection(),
		Config.Velocity,
		CastBehavior
	)
end

local function fireProjectiles()
	for _ = 1, Config.ProjectileAmount do
		task.spawn(fireProjectile)
	end
end

--// Benchmark

local function runBenchmark()
	if IsBenchmarking or IsReconfiguring then
		return
	end

	IsBenchmarking = true

	resetFPS()

	printBenchmarkInfo()

	print(("Firing %d projectiles..."):format(
		Config.ProjectileAmount
		))

	fireProjectiles()

	-- Let the first batch begin processing.
	task.wait()

	printSection("CREATION COMPLETE")
	printFPS()

	task.wait(Config.BenchmarkDuration)

	printSection("SIMULATION COMPLETE")
	printFPS()

	printSection("CLEANUP")

	terminateActiveCasts()

	task.wait(BENCHMARK_COOLDOWN)

	printSection("DONE")
	printFPS()

	IsBenchmarking = false
end

--// Configuration

local function setInstanced(enabled)
	Config.Instanced = enabled

	CastBehavior.CosmeticBulletTemplate =
		enabled and ProjectileTemplate or nil
end

local function toggleInstancing()
	setInstanced(not Config.Instanced)

	print(("Instanced: %s"):format(
		Config.Instanced and "Enabled" or "Disabled"
		))
end

local function toggleMovementMode()
	if Config.MovementMode == "BulkMoveTo" then
		Config.MovementMode = "Motor6D"
	else
		Config.MovementMode = "BulkMoveTo"
	end

	if Caster then
		Caster:SetMovementModeEnabled(
			true,
			Config.MovementMode
		)
	end

	print(("MovementMode: %s"):format(
		Config.MovementMode
		))
end

local function toggleObjectCache()
	Config.ObjectCacheEnabled =
		not Config.ObjectCacheEnabled

	applyObjectCache()

	print(("ObjectCache: %s"):format(
		Config.ObjectCacheEnabled
			and "Enabled"
			or "Disabled"
		))
end

local function toggleVisualization()
	Config.VisualizeCasts =
		not Config.VisualizeCasts

	CastBehavior.VisualizeCasts =
		Config.VisualizeCasts

	print(("VisualizeCasts: %s"):format(
		Config.VisualizeCasts
			and "Enabled"
			or "Disabled"
		))
end

local function cycleHighFidelity()
	local current = CastBehavior.HighFidelityBehavior

	if current == FastCastEnums.HighFidelityBehavior.Default then

		CastBehavior.HighFidelityBehavior =
			FastCastEnums.HighFidelityBehavior.Automatic

	elseif current == FastCastEnums.HighFidelityBehavior.Automatic then

		CastBehavior.HighFidelityBehavior =
			FastCastEnums.HighFidelityBehavior.Always

	else

		CastBehavior.HighFidelityBehavior =
			FastCastEnums.HighFidelityBehavior.Default

	end

	print(("HighFidelityBehavior: %s"):format(
		getHighFidelityName()
		))
end

local function changeSegmentSize(amount)
	CastBehavior.HighFidelitySegmentSize = math.max(
		Config.MinSegmentSize,
		CastBehavior.HighFidelitySegmentSize + amount
	)

	print(("HighFidelitySegmentSize: %.2f"):format(
		CastBehavior.HighFidelitySegmentSize
		))
end

local function changeProjectileAmount(amount)
	Config.ProjectileAmount = math.max(
		0,
		Config.ProjectileAmount + amount
	)

	print(("ProjectileAmount: %d"):format(
		Config.ProjectileAmount
		))
end

--// Worker Configuration

local function changeWorkerCount(amount)
	if IsBenchmarking or IsReconfiguring then
		return
	end

	local newCount = math.max(
		Config.MinWorkers,
		Config.NumWorkers + amount
	)

	if newCount == Config.NumWorkers then
		return
	end

	IsReconfiguring = true

	Config.NumWorkers = newCount

	rebuildCaster()

	print(("numWorkers: %d"):format(
		Config.NumWorkers
		))

	task.wait(NUM_WORKERS_CHANGE_COOLDOWN)

	IsReconfiguring = false
end

--// Help

local function showHelp()
	printSection("FastCast2 Server Benchmark Keys")

	print("Type these commands in chat:")

	print("p - Start benchmark")
	print("l - Increase projectile amount by 500")
	print("k - Decrease projectile amount by 500")
	print("u - Toggle Instanced / Instanceless")
	print("j - Toggle BulkMoveTo / Motor6D")
	print("y - Toggle ObjectCache")
	print("v - Toggle VisualizeCasts")
	print("x - Cycle HighFidelityBehavior")
	print("> - Increase HighFidelitySegmentSize")
	print("< - Decrease HighFidelitySegmentSize")
	print("] - Increment numWorkers")
	print("[ - Decrement numWorkers")
	print("i - Show benchmark information")
	print("h - Show this help")
end

--// Command Handlers

local Commands = {
	p = runBenchmark,

	l = function()
		if not IsBenchmarking then
			changeProjectileAmount(Config.ProjectileStep)
		end
	end,

	k = function()
		if not IsBenchmarking then
			changeProjectileAmount(-Config.ProjectileStep)
		end
	end,

	u = function()
		if not IsBenchmarking then
			toggleInstancing()
		end
	end,

	j = function()
		if not IsBenchmarking and not IsReconfiguring then
			toggleMovementMode()
		end
	end,

	y = function()
		if not IsBenchmarking and not IsReconfiguring then
			toggleObjectCache()
		end
	end,

	v = function()
		if not IsBenchmarking then
			toggleVisualization()
		end
	end,

	x = function()
		if not IsBenchmarking then
			cycleHighFidelity()
		end
	end,

	[">"] = function()
		if not IsBenchmarking then
			changeSegmentSize(Config.SegmentSizeStep)
		end
	end,

	["."] = function()
		if not IsBenchmarking then
			changeSegmentSize(Config.SegmentSizeStep)
		end
	end,

	["<"] = function()
		if not IsBenchmarking then
			changeSegmentSize(-Config.SegmentSizeStep)
		end
	end,

	[","] = function()
		if not IsBenchmarking then
			changeSegmentSize(-Config.SegmentSizeStep)
		end
	end,

	["["] = function()
		changeWorkerCount(-Config.WorkerStep)
	end,

	["]"] = function()
		changeWorkerCount(Config.WorkerStep)
	end,

	i = function()
		if not IsBenchmarking then
			printBenchmarkInfo()
		end
	end,

	h = showHelp,
}

--// Chat Handling

local function onChatMessage(player, message)
	local command = message:lower():gsub("^%s*(.-)%s*$", "%1")

	local handler = Commands[command]

	if handler then
		handler()
	end
end

local function connectPlayer(player)
	player.Chatted:Connect(function(message)
		onChatMessage(player, message)
	end)
end

Players.PlayerAdded:Connect(connectPlayer)

for _, player in Players:GetPlayers() do
	connectPlayer(player)
end

--// Initialization

rebuildCaster()

showHelp()
printBenchmarkInfo()
