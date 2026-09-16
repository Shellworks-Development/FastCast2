--[[
	FastCast2 Client Benchmark
	Author: Mawin CK
	Date: 2026

	Controls:
		P       Benchmark
		L       +500 projectiles
		K       -500 projectiles
		U       Toggle Instanced / Instanceless
		J       Toggle BulkMoveTo / Motor6D
		Y       Toggle ObjectCache
		V       Toggle Cast Visualization
		X       Cycle HighFidelityBehavior
		>       Increase HighFidelitySegmentSize
		<       Decrease HighFidelitySegmentSize
		B       Toggle Serial / Parallel
		[       Decrease workers
		]       Increase workers
		I       Show benchmark information
		H       Show controls
]]

--// Services

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ReplicatedFirst = game:GetService("ReplicatedFirst")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")

--// Configuration

local Config = {
	Parallel = true,
	NumWorkers = 4,

	ProjectileAmount = 500,
	Velocity = 6,

	Instanced = true,
	ObjectCacheEnabled = false,
	VisualizeCasts = false,

	BenchmarkDuration = 6,

	MovementMode = "BulkMoveTo",

	VMName = "CastVMs",
	VMContainerName = "CastVMContainer",
	VMTemplateName = "CastVM",

	FPSUpdateRate = 0.5,

	HighFidelitySegmentSizeStep = 0.05,
	MinHighFidelitySegmentSize = 0.05,

	MinWorkers = 2,
	ProjectileStep = 500,
}

--// Constants
local NUM_WORKERS_CHANGE_COOLDOWN = 4.5
local MODE_CHANGE_COOLDOWN = 2.5
local BENCHMARK_COOLDOWN = 2.5

--// Modules

local FastCastModule = ReplicatedStorage:WaitForChild("FastCast2")

local FastCast = require(FastCastModule)
local FastCastEnums = require(FastCastModule:WaitForChild("FastCastEnums"))

--// Objects

local ProjectileContainer = Instance.new("Folder")
ProjectileContainer.Name = "FastCast2PJ"
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
CastBehavior.HighFidelityBehavior =
	FastCastEnums.HighFidelityBehavior.Default

CastBehavior.HighFidelitySegmentSize = 1
CastBehavior.Acceleration = Vector3.zero

CastBehavior.AutoIgnoreContainer = true

CastBehavior.CosmeticBulletContainer = ProjectileContainer
CastBehavior.CosmeticBulletTemplate = ProjectileTemplate

CastBehavior.VisualizeCasts = Config.VisualizeCasts
CastBehavior.RaycastParams = CastParams

--// State

local Caster
local ActiveCasts = {}

local IsBenchmarking = false
local IsReconfiguring = false

--// FPS Statistics

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

	if FPS.FrameCount >= 1 then
		-- Update the rolling average periodically rather than
		-- calculating it every frame.
		FPS.Average = FPS.Accumulator / FPS.FrameCount
	end
end

RunService.Heartbeat:Connect(function(dt)
	updateFPS(dt)
end)

--// Utility

local function getMode()
	return Config.Parallel and "PARALLEL" or "SERIAL"
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

local function printSeparator(title)
	print(("=== %s ==="):format(title))
end

--// Caster

local function onCastFire(cast)
	ActiveCasts[#ActiveCasts + 1] = cast
end

local function createCaster()
	local newCaster

	if Config.Parallel then
		newCaster = FastCast.newParallel()

		newCaster:Init(
			Config.NumWorkers,
			ReplicatedFirst,
			Config.VMName,
			ReplicatedFirst,
			Config.VMContainerName,
			Config.VMTemplateName,
			Config.MovementMode
		)
	else
		newCaster = FastCast.new()

		newCaster:Init(Config.MovementMode)
	end

	newCaster.CastFire = onCastFire

	return newCaster
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

local function destroyCaster()
	if Caster then
		Caster:Destroy()
		Caster = nil
	end

	table.clear(ActiveCasts)
end

local function rebuildCaster()
	destroyCaster()

	Caster = createCaster()
	applyObjectCache()
end

-- Create initial caster.
Caster = createCaster()
applyObjectCache()

--// Benchmark Information

local function printBenchmarkInfo()
	printSeparator(("%s MODE BENCHMARK"):format(getMode()))

	print(("Projectiles: %d"):format(Config.ProjectileAmount))
	print(("Velocity: %.2f"):format(Config.Velocity))

	print(
		"ObjectCache: %s",
		getObjectCacheState() and "Enabled" or "Disabled"
	)

	print(
		"Instanced: %s",
		Config.Instanced and "Enabled" or "Disabled"
	)

	print(
		"VisualizeCasts: %s",
		CastBehavior.VisualizeCasts and "Enabled" or "Disabled"
	)

	print(("HighFidelityBehavior: %s"):format(getHighFidelityName()))

	print(
		("HighFidelitySegmentSize: %.2f"):format(
			CastBehavior.HighFidelitySegmentSize
		)
	)

	print(("MovementMode: %s"):format(Config.MovementMode))

	print(("Mode: %s"):format(getMode()))

	if Config.Parallel then
		print(("numWorkers: %d"):format(Config.NumWorkers))
	end
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

local function fireProjectile()
	Caster:RaycastFire(
		Vector3.new(
			math.random(-100, 100),
			math.random(0, 100),
			math.random(-100, 100)
		),

		Vector3.new(
			math.random() * 2 - 1,
			math.random() * 2 - 1,
			math.random() * 2 - 1
		),

		Config.Velocity,
		CastBehavior
	)
end

local function fireProjectiles()
	for _ = 1, Config.ProjectileAmount do
		task.spawn(fireProjectile)
	end
end

--// Cleanup

local function cleanupCasts()
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

--// Benchmark

local function benchmark()
	if IsBenchmarking or IsReconfiguring then
		return
	end

	IsBenchmarking = true

	resetFPS()

	printBenchmarkInfo()
	print(("Firing %d projectiles..."):format(Config.ProjectileAmount))

	fireProjectiles()

	-- Allow the casts to begin processing.
	task.wait()

	printSeparator("CREATION COMPLETE")
	printFPS()

	task.wait(Config.BenchmarkDuration)

	printSeparator("SIMULATION COMPLETE")
	printFPS()

	printSeparator("CLEANUP")

	cleanupCasts()

	-- Give FastCast/object cache time to settle.
	task.wait(BENCHMARK_COOLDOWN)

	printSeparator("DONE")
	printFPS()

	IsBenchmarking = false
end

--// Configuration Changes

local function toggleInstancing()
	Config.Instanced = not Config.Instanced

	CastBehavior.CosmeticBulletTemplate =
		Config.Instanced and ProjectileTemplate or nil

	print(
		("CosmeticBulletTemplate: %s"):format(
			Config.Instanced and "Enabled" or "Disabled"
		)
	)
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

	print(("MovementMode: %s"):format(Config.MovementMode))
end

local function toggleObjectCache()
	Config.ObjectCacheEnabled = not Config.ObjectCacheEnabled

	applyObjectCache()

	print(
		("ObjectCache: %s"):format(
			Config.ObjectCacheEnabled and "Enabled" or "Disabled"
		)
	)
end

local function toggleVisualization()
	CastBehavior.VisualizeCasts =
		not CastBehavior.VisualizeCasts

	print(
		("VisualizeCasts: %s"):format(
			CastBehavior.VisualizeCasts and "Enabled" or "Disabled"
		)
	)
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

	print(
		("HighFidelityBehavior: %s"):format(
			getHighFidelityName()
		)
	)
end

local function changeSegmentSize(amount)
	CastBehavior.HighFidelitySegmentSize = math.max(
		Config.MinHighFidelitySegmentSize,
		CastBehavior.HighFidelitySegmentSize + amount
	)

	print(
		("HighFidelitySegmentSize: %.2f"):format(
			CastBehavior.HighFidelitySegmentSize
		)
	)
end

local function changeProjectileAmount(amount)
	Config.ProjectileAmount = math.max(
		0,
		Config.ProjectileAmount + amount
	)

	print(
		("ProjectileAmount: %d"):format(
			Config.ProjectileAmount
		)
	)
end

--// Mode Switching

local function switchMode()
	if IsBenchmarking or IsReconfiguring then
		return
	end

	IsReconfiguring = true

	Config.Parallel = not Config.Parallel

	rebuildCaster()

	print(("Switched to %s."):format(getMode()))

	task.wait(MODE_CHANGE_COOLDOWN)

	IsReconfiguring = false

	print("Done!")
end

local function changeWorkerCount(amount)
	if IsBenchmarking or IsReconfiguring then
		return
	end

	if not Config.Parallel then
		print("Worker count only applies to Parallel mode.")
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

	print(("numWorkers: %d"):format(Config.NumWorkers))

	task.wait(NUM_WORKERS_CHANGE_COOLDOWN)

	IsReconfiguring = false
end

--// Controls

local function showControls()
	printSeparator("FastCast2 Client Benchmark Keys")

	print("P  - Benchmark")
	print("L  - Increase projectile amount by 500")
	print("K  - Decrease projectile amount by 500")
	print("U  - Toggle Instanced / Instanceless")
	print("J  - Toggle BulkMoveTo / Motor6D")
	print("Y  - Toggle ObjectCache")
	print("V  - Toggle VisualizeCasts")
	print("X  - Cycle HighFidelityBehavior")
	print(">  - Increase HighFidelitySegmentSize")
	print("<  - Decrease HighFidelitySegmentSize")
	print("B  - Toggle Serial / Parallel")
	print("[  - Decrease numWorkers")
	print("]  - Increase numWorkers")
	print("I  - Show benchmark info")
	print("H  - Show controls")
end

--// Keybind Table

local Keybinds = {
	[Enum.KeyCode.P] = benchmark,

	[Enum.KeyCode.L] = function()
		if not IsBenchmarking then
			changeProjectileAmount(Config.ProjectileStep)
		end
	end,

	[Enum.KeyCode.K] = function()
		if not IsBenchmarking then
			changeProjectileAmount(-Config.ProjectileStep)
		end
	end,

	[Enum.KeyCode.U] = function()
		if not IsBenchmarking then
			toggleInstancing()
		end
	end,

	[Enum.KeyCode.J] = function()
		if not IsBenchmarking and not IsReconfiguring then
			toggleMovementMode()
		end
	end,

	[Enum.KeyCode.Y] = function()
		if not IsBenchmarking and not IsReconfiguring then
			toggleObjectCache()
		end
	end,

	[Enum.KeyCode.V] = function()
		if not IsBenchmarking then
			toggleVisualization()
		end
	end,

	[Enum.KeyCode.X] = function()
		if not IsBenchmarking then
			cycleHighFidelity()
		end
	end,

	[Enum.KeyCode.B] = switchMode,

	[Enum.KeyCode.LeftBracket] = function()
		changeWorkerCount(-1)
	end,

	[Enum.KeyCode.RightBracket] = function()
		changeWorkerCount(1)
	end,

	[Enum.KeyCode.Period] = function()
		if not IsBenchmarking then
			changeSegmentSize(
				Config.HighFidelitySegmentSizeStep
			)
		end
	end,

	[Enum.KeyCode.Comma] = function()
		if not IsBenchmarking then
			changeSegmentSize(
				-Config.HighFidelitySegmentSizeStep
			)
		end
	end,

	[Enum.KeyCode.H] = showControls,

	[Enum.KeyCode.I] = function()
		if not IsBenchmarking then
			printBenchmarkInfo()
		end
	end,
}

--// Input

UserInputService.InputBegan:Connect(function(input, gameProcessed)
	if gameProcessed then
		return
	end

	local callback = Keybinds[input.KeyCode]

	if callback then
		callback()
	end
end)

--// Startup

showControls()
printBenchmarkInfo()
