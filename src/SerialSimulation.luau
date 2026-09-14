--[[
	- Author: Mawin_CK
	- Date: 2026
]]

--!native
--!optimize 2

local RunService = game:GetService("RunService")

local TypeDef = require(script.Parent:WaitForChild("TypeDefinitions"))
local FastCastEnums = require(script.Parent:WaitForChild("FastCastEnums"))
local Config = require(script.Parent:WaitForChild("Config"))

local DebugLogging = Config.DebugLogging
local EnumCastTypes = FastCastEnums.CastType

local DEFAULT_MAX_DISTANCE = 1000
local FC_VIS_OBJ_NAME = "FastCastVisualizationObjects"

---------------------------------------------------------------------
-- Types
---------------------------------------------------------------------

type BlockcastVariant = {
	CastType: number,
	Size: Vector3,
}

type SpherecastVariant = {
	CastType: number,
	Radius: number,
}

type CastVariants =
	BlockcastVariant
	| SpherecastVariant

type RayVisualizerVariant = {
	castLength: number,
}

type BlockVisualizerVariant = {
	size: Vector3,
}

type SphereVisualizerVariant = {
	radius: number,
}

type CastVisualizerVariants =
	RayVisualizerVariant
	| BlockVisualizerVariant
	| SphereVisualizerVariant

type QueuedEventData = {
	eventType: string,
	args: { any },
}

type QueuedVisualizeCastData = {
	castStartCFrame: CFrame,
	sub: boolean,
}

type QueuedVisualizeHitData = {
	atCF: CFrame,
	wasPierce: boolean,
	sub: boolean,
}

type SegmentData = {
	lastPoint: Vector3,
	currentPoint: Vector3,

	lastTime: number,
	currentTime: number,

	velocity: Vector3,
	displacement: Vector3,
}

---------------------------------------------------------------------
-- SoA State
---------------------------------------------------------------------

local casts_TotalRunTime = {} :: { [number]: number }
local casts_DistanceCovered = {} :: { [number]: number }

local casts_HighFidelitySegmentSize = {} :: { [number]: number }
local casts_HighFidelityBehavior = {} :: { [number]: number }

local casts_IsActivelySimulatingPierce = {} :: { [number]: boolean }
local casts_IsActivelyResimulating = {} :: { [number]: boolean }
local casts_CancelHighResCast = {} :: { [number]: boolean }

local casts_Trajectory = {} :: { [number]: TypeDef.CastTrajectory }
local casts_FastCastEventsConfig = {} :: { [number]: TypeDef.FastCastEventsConfig }

local casts_VisualizeCasts = {} :: { [number]: boolean }
local casts_VisualizeCastSettings = {} :: {
	[number]: TypeDef.VisualizeCastSettings
}

local casts_RayInfo = {} :: { [number]: TypeDef.CastRayInfo }
local casts_UserData = {} :: { [number]: any }

local casts_CFrame = {} :: { [number]: CFrame }

local casts_CastType = {} :: { [number]: number }
local casts_CastVariant = {} :: { [number]: CastVariants }

local casts_MaxDistance = {} :: { [number]: number }
local casts_ActiveMotor6Ds = {} :: { [number]: Motor6D }

local casts_RayDisplacement = {} :: { [number]: number }

local queuedEvents: {
	[number]: { QueuedEventData },
} = {}

local queuedVisualizes: {
	[number]: {
		QueuedVisualizeCastData | QueuedVisualizeHitData
	},
} = {}

---------------------------------------------------------------------
-- Cast Handlers
---------------------------------------------------------------------

local castHandlers = {

	[EnumCastTypes.Raycast] = function(
		worldRoot: WorldRoot,
		origin: Vector3,
		direction: Vector3,
		params: RaycastParams
	)
		return worldRoot:Raycast(
			origin,
			direction,
			params
		)
	end,

	[EnumCastTypes.Blockcast] = function(
		worldRoot: WorldRoot,
		origin: Vector3,
		direction: Vector3,
		params: RaycastParams,
		variant: BlockcastVariant
	)
		return worldRoot:Blockcast(
			CFrame.new(origin),
			variant.Size,
			direction,
			params
		)
	end,

	[EnumCastTypes.Spherecast] = function(
		worldRoot: WorldRoot,
		origin: Vector3,
		direction: Vector3,
		params: RaycastParams,
		variant: SpherecastVariant
	)
		return worldRoot:Spherecast(
			origin,
			variant.Radius,
			direction,
			params
		)
	end,
}

---------------------------------------------------------------------
-- Math
---------------------------------------------------------------------

local function GetPositionAtTime(
	t: number,
	origin: Vector3,
	initialVelocity: Vector3,
	acceleration: Vector3
): Vector3

	return origin
		+ initialVelocity * t
		+ acceleration * (t * t * 0.5)
end

local function GetVelocityAtTime(
	t: number,
	initialVelocity: Vector3,
	acceleration: Vector3
): Vector3

	return initialVelocity + acceleration * t
end

---------------------------------------------------------------------
-- Debug Visualization
---------------------------------------------------------------------

local function DebrisAdd(
	object: Instance,
	lifetime: number
)
	if lifetime <= 0 then
		object:Destroy()
		return
	end

	task.delay(lifetime, function()
		if object.Parent then
			object:Destroy()
		end
	end)
end

local function GetVisualizationContainer(): Instance

	local container = workspace.Terrain:FindFirstChild(
		FC_VIS_OBJ_NAME
	)

	if container then
		return container
	end

	container = Instance.new("Folder")
	container.Name = FC_VIS_OBJ_NAME
	container.Archivable = false
	container.Parent = workspace.Terrain

	return container
end

local function VisualizeRaySegment(
	startCFrame: CFrame,
	settings: TypeDef.VisualizeCastSettings,
	variant: RayVisualizerVariant
)

	local adornment = Instance.new("ConeHandleAdornment")

	adornment.Adornee = workspace.Terrain
	adornment.CFrame = startCFrame
	adornment.Height = variant.castLength

	adornment.Color3 = settings.Debug_SegmentColor
	adornment.Radius = settings.Debug_SegmentSize
	adornment.Transparency = settings.Debug_SegmentTransparency

	adornment.Parent = GetVisualizationContainer()

	DebrisAdd(
		adornment,
		settings.Debug_RayLifetime
	)

	return adornment
end

local function VisualizeBlockSegment(
	startCFrame: CFrame,
	settings: TypeDef.VisualizeCastSettings,
	variant: BlockVisualizerVariant
)

	local adornment = Instance.new("BoxHandleAdornment")

	adornment.Adornee = workspace.Terrain
	adornment.CFrame = startCFrame
	adornment.Size = variant.size

	adornment.Color3 = settings.Debug_SegmentColor
	adornment.Transparency = settings.Debug_SegmentTransparency

	adornment.Parent = GetVisualizationContainer()

	DebrisAdd(
		adornment,
		settings.Debug_RayLifetime
	)

	return adornment
end

local function VisualizeSphereSegment(
	startCFrame: CFrame,
	settings: TypeDef.VisualizeCastSettings,
	variant: SphereVisualizerVariant
)

	local adornment = Instance.new("SphereHandleAdornment")

	adornment.Adornee = workspace.Terrain
	adornment.CFrame = startCFrame
	adornment.Radius = variant.radius

	adornment.Color3 = settings.Debug_SegmentColor
	adornment.Transparency = settings.Debug_SegmentTransparency

	adornment.Parent = GetVisualizationContainer()

	DebrisAdd(
		adornment,
		settings.Debug_RayLifetime
	)

	return adornment
end

local function VisualizeHit(
	atCFrame: CFrame,
	wasPierce: boolean,
	settings: TypeDef.VisualizeCastSettings
)

	local adornment = Instance.new("SphereHandleAdornment")

	adornment.Adornee = workspace.Terrain
	adornment.CFrame = atCFrame

	if wasPierce then
		adornment.Radius = settings.Debug_RayPierceSize
		adornment.Transparency = settings.Debug_RayPierceTransparency
		adornment.Color3 = settings.Debug_RayPierceColor
	else
		adornment.Radius = settings.Debug_HitSize
		adornment.Transparency = settings.Debug_HitTransparency
		adornment.Color3 = settings.Debug_HitColor
	end

	adornment.Parent = GetVisualizationContainer()

	DebrisAdd(
		adornment,
		settings.Debug_HitLifetime
	)

	return adornment
end

local Visualizers = {
	[EnumCastTypes.Raycast] = VisualizeRaySegment,
	[EnumCastTypes.Blockcast] = VisualizeBlockSegment,
	[EnumCastTypes.Spherecast] = VisualizeSphereSegment,
}

---------------------------------------------------------------------
-- SerialSimulation
---------------------------------------------------------------------

local SerialSimulation = {}
SerialSimulation.__index = SerialSimulation
SerialSimulation.__type = "SerialSimulation"

---------------------------------------------------------------------
-- Queue Helpers
---------------------------------------------------------------------

function SerialSimulation:QueueEvent(
	castID: number,
	eventType: string,
	...: any
)

	if not queuedEvents[castID] then
		queuedEvents[castID] = {}
	end

	table.insert(
		queuedEvents[castID],
		{
			eventType = eventType,
			args = { ... },
		}
	)
end

function SerialSimulation:QueueVisualize(
	castID: number,
	data: QueuedVisualizeCastData | QueuedVisualizeHitData
)

	if not casts_VisualizeCasts[castID] then
		return
	end

	if not queuedVisualizes[castID] then
		queuedVisualizes[castID] = {}
	end

	table.insert(
		queuedVisualizes[castID],
		data
	)
end

---------------------------------------------------------------------
-- Event Helpers
---------------------------------------------------------------------

function SerialSimulation:QueueLengthChanged(
	id: number,
	segment: SegmentData,
	distance: number
)

	local rayDirection

	if segment.displacement.Magnitude > 0 then
		rayDirection = segment.displacement.Unit
	else
		rayDirection = Vector3.zero
	end

	local cosmeticBullet =
		casts_RayInfo[id].CosmeticBulletObject

	self:QueueEvent(
		id,
		"LengthChanged",
		segment.lastPoint,
		rayDirection,
		distance,
		segment.velocity,
		cosmeticBullet
	)
end

function SerialSimulation:QueueHit(
	id: number,
	result: RaycastResult,
	velocity: Vector3,
	sub: boolean
)

	self:QueueEvent(
		id,
		"Hit",
		result,
		velocity,
		casts_RayInfo[id].CosmeticBulletObject
	)

	self:QueueVisualize(
		id,
		{
			atCF = CFrame.new(result.Position),
			wasPierce = false,
			sub = sub,
		}
	)
end

function SerialSimulation:QueuePierce(
	id: number,
	result: RaycastResult,
	velocity: Vector3,
	sub: boolean
)

	self:QueueEvent(
		id,
		"Pierced",
		result,
		velocity,
		casts_RayInfo[id].CosmeticBulletObject
	)

	self:QueueVisualize(
		id,
		{
			atCF = CFrame.new(result.Position),
			wasPierce = true,
			sub = sub,
		}
	)
end

function SerialSimulation:QueueTermination(id: number)
	self:QueueEvent(
		id,
		"CastTerminating"
	)
end

---------------------------------------------------------------------
-- Event Dispatch
---------------------------------------------------------------------

function SerialSimulation:FireQueuedVisualizes(
	unFiredVisualizes
)

	local sortedIDs = {}

	for id in unFiredVisualizes do
		table.insert(
			sortedIDs,
			id
		)
	end

	table.sort(sortedIDs)

	for _, castID in sortedIDs do

		local list =
			unFiredVisualizes[castID]

		if not list then
			continue
		end

		for _, data in list do

			if data.atCF then

				if DebugLogging.Hit
					and not data.wasPierce
					and not data.sub
				then
					print(
						"Hit was successful. Terminating."
					)
				end

				if DebugLogging.Pierced
					and data.wasPierce
					and not data.sub
				then
					print(
						"Piercing function returned TRUE."
					)
				end

				VisualizeHit(
					data.atCF,
					data.wasPierce,
					casts_VisualizeCastSettings[castID]
				)

				continue
			end

			if DebugLogging.Segment
				and data.sub
			then
				print(
					"Subcast visualization"
				)
			end

			local castType = casts_CastType[castID]

			local visualizer = Visualizers[castType]

			if not visualizer then
				continue
			end

			local variant: CastVisualizerVariants

			if castType
				== EnumCastTypes.Raycast
			then

				variant = {
					castLength =
						casts_RayDisplacement[castID]
						or 1,
				}

			elseif castType
				== EnumCastTypes.Blockcast
			then

				variant = {
					size =
						(casts_CastVariant[castID]
							:: BlockcastVariant).Size,
				}

			else

				variant = {
					radius =
						(casts_CastVariant[castID]
							:: SpherecastVariant).Radius,
				}
			end

			visualizer(
				data.castStartCFrame,
				casts_VisualizeCastSettings[castID],
				variant
			)
		end
	end
end

function SerialSimulation:FireQueuedEvents(
	unFiredEvents
)

	local sortedIDs = {}

	for id in unFiredEvents do
		table.insert(
			sortedIDs,
			id
		)
	end

	table.sort(sortedIDs)

	for _, castID in sortedIDs do

		local events =
			unFiredEvents[castID]

		if not events then
			continue
		end

		for _, event in events do

			local cast =
				self.ActivesRef[castID]

			if not cast then
				continue
			end

			local config = casts_FastCastEventsConfig[castID]

			local eventType = event.eventType

			if eventType == "LengthChanged" then

				if config
					and config.UseLengthChanged
					and self.Events.LengthChanged
				then

					self.Events.LengthChanged(
						cast,
						table.unpack(event.args)
					)
				end

			elseif eventType == "Hit" then

				if config
					and config.UseHit
					and self.Events.Hit
				then

					self.Events.Hit(
						cast,
						table.unpack(event.args)
					)
				end

			elseif eventType == "Pierced" then

				if config
					and config.UsePierced
					and self.Events.Pierced
				then

					self.Events.Pierced(
						cast,
						table.unpack(event.args)
					)
				end

			elseif eventType == "CastTerminating" then

				self.BaseCastRef:_TerminateCast(
					castID,
					self.Events.CastTerminating
				)

				self:Unregister(
					castID
				)
			end
		end
	end
end

---------------------------------------------------------------------
-- Registration
---------------------------------------------------------------------

function SerialSimulation:Register(
	cast: any
)

	local id = cast.ID

	casts_TotalRunTime[id] = cast.StateInfo.TotalRuntime or 0

	casts_DistanceCovered[id] = 0

	casts_HighFidelitySegmentSize[id] =
		cast.StateInfo.HighFidelitySegmentSize
		or 0.1

	casts_HighFidelityBehavior[id] =
		cast.StateInfo.HighFidelityBehavior
		or 0

	casts_IsActivelySimulatingPierce[id] = false
	casts_IsActivelyResimulating[id] = false
	casts_CancelHighResCast[id] = false

	casts_Trajectory[id] = cast.StateInfo.Trajectory

	casts_FastCastEventsConfig[id] = cast.StateInfo.FastCastEventsConfig

	casts_VisualizeCasts[id] = cast.StateInfo.VisualizeCasts

	casts_VisualizeCastSettings[id] = cast.StateInfo.VisualizeCastSettings

	casts_RayInfo[id] = cast.RayInfo

	casts_UserData[id] = cast.UserData

	casts_CastType[id] = cast.CastVariant.CastType

	casts_CastVariant[id] = cast.CastVariant

	casts_MaxDistance[id] =
		cast.RayInfo.MaxDistance
		or DEFAULT_MAX_DISTANCE

	table.insert(
		self.casts_ID,
		id
	)

	self.casts_ID_Index[id] = #self.casts_ID

	local trajectory = casts_Trajectory[id]

	local position =
		GetPositionAtTime(
			casts_TotalRunTime[id],
			trajectory.Origin,
			trajectory.InitialVelocity,
			trajectory.Acceleration
		)

	casts_CFrame[id] = CFrame.new(position)

	cast.CFrame = casts_CFrame[id]

	queuedEvents[id] = {}
end

---------------------------------------------------------------------
-- Unregister
---------------------------------------------------------------------

function SerialSimulation:Unregister(
	castID: number
)

	casts_TotalRunTime[castID] = nil
	casts_DistanceCovered[castID] = nil

	casts_HighFidelitySegmentSize[castID] = nil
	casts_HighFidelityBehavior[castID] = nil

	casts_IsActivelySimulatingPierce[castID] = nil
	casts_IsActivelyResimulating[castID] = nil
	casts_CancelHighResCast[castID] = nil

	casts_Trajectory[castID] = nil
	casts_FastCastEventsConfig[castID] = nil

	casts_VisualizeCasts[castID] = nil
	casts_VisualizeCastSettings[castID] = nil

	casts_RayInfo[castID] = nil
	casts_UserData[castID] = nil

	casts_CFrame[castID] = nil
	casts_CastType[castID] = nil
	casts_CastVariant[castID] = nil

	casts_MaxDistance[castID] = nil
	casts_RayDisplacement[castID] = nil

	if casts_ActiveMotor6Ds[castID] then

		if self.BaseCastRef
			and self.BaseCastRef._ReturnMotor6D
		then

			self.BaseCastRef:_ReturnMotor6D(
				casts_ActiveMotor6Ds[castID]
			)
		end

		casts_ActiveMotor6Ds[castID] = nil
	end

	local index =
		self.casts_ID_Index[castID]

	if index then

		local lastID =
			self.casts_ID[#self.casts_ID]

		self.casts_ID[index] =
			lastID

		self.casts_ID_Index[lastID] =
			index

		self.casts_ID[#self.casts_ID] = nil
		self.casts_ID_Index[castID] = nil
	end

	queuedEvents[castID] = nil
	queuedVisualizes[castID] = nil
end

---------------------------------------------------------------------
-- Movement
---------------------------------------------------------------------

function SerialSimulation:BulkMoveTo()

	if self.CurrentMovementMode
		~= "BulkMoveTo"
		or not self.MovementEnabled
	then
		return
	end

	local parts =
		table.create(#self.casts_ID)

	local cframes =
		table.create(#self.casts_ID)

	for _, id in self.casts_ID do

		local cosmetic =
			casts_RayInfo[id]
			and casts_RayInfo[id].CosmeticBulletObject

		if cosmetic
			and cosmetic.Parent
		then

			table.insert(
				parts,
				cosmetic
			)

			table.insert(
				cframes,
				casts_CFrame[id]
			)
		end
	end

	if #parts > 0 then

		workspace:BulkMoveTo(
			parts,
			cframes,
			Enum.BulkMoveMode.FireCFrameChanged
		)
	end
end

function SerialSimulation:UpdateMotor6Ds()

	if self.CurrentMovementMode
		~= "Motor6D"
		or not self.MovementEnabled
	then
		return
	end

	for id, motor6d in casts_ActiveMotor6Ds do

		if motor6d
			and motor6d.Parent
		then

			motor6d.Transform =
				casts_CFrame[id]
		end
	end
end

---------------------------------------------------------------------
-- Movement Mode
---------------------------------------------------------------------

function SerialSimulation:SetMovementModeEnabled(
	enabled: boolean,
	mode: "BulkMoveTo" | "Motor6D"
)

	self.CurrentMovementMode =
		mode

	self.MovementEnabled =
		enabled
end

---------------------------------------------------------------------
-- Update
---------------------------------------------------------------------

function SerialSimulation:UpdateCasts(
	delta: number
)

	for _, id in self.casts_ID do

		local cast =
			self.ActivesRef[id]

		if cast
			and cast._Destroying
		then
			continue
		end

		if casts_HighFidelitySegmentSize[id] <= 0 then
			casts_HighFidelitySegmentSize[id] = 0.1
		end

		self:SimulateCast(
			id,
			delta,
			self.Events.CanPierce
		)
	end

	-------------------------------------------------------------
	-- Write state back
	-------------------------------------------------------------

	for _, id in self.casts_ID do

		local cast =
			self.ActivesRef[id]

		if cast then

			cast.StateInfo.TotalRuntime =
				casts_TotalRunTime[id]

			cast.StateInfo.DistanceCovered =
				casts_DistanceCovered[id]

			cast.CFrame =
				casts_CFrame[id]
		end
	end

	-------------------------------------------------------------
	-- Movement
	-------------------------------------------------------------

	self:UpdateMotor6Ds()
	self:BulkMoveTo()

	-------------------------------------------------------------
	-- Swap queues
	-------------------------------------------------------------

	local events =
		queuedEvents

	queuedEvents = {}

	local visualizes =
		queuedVisualizes

	queuedVisualizes = {}

	-------------------------------------------------------------
	-- Dispatch
	-------------------------------------------------------------

	self:FireQueuedVisualizes(
		visualizes
	)

	self:FireQueuedEvents(
		events
	)
end

---------------------------------------------------------------------
-- Construction
---------------------------------------------------------------------

function SerialSimulation.new()

	local self =
		setmetatable(
			{},
			SerialSimulation
		)

	self.Connection = nil

	self.CurrentMovementMode = "BulkMoveTo"

	self.MovementEnabled = true

	self.Events = {}

	self.BaseCastRef = nil
	self.ActivesRef = nil

	self.casts_ID = {}
	self.casts_ID_Index = {}

	return self
end

function SerialSimulation:Init(
	baseCastRef: any,
	events: TypeDef.FastCastEvents
)

	self.BaseCastRef = baseCastRef

	self.ActivesRef = baseCastRef.Actives

	self.Events = events
end

---------------------------------------------------------------------
-- RunService
---------------------------------------------------------------------

function SerialSimulation:Start()

	if self.Connection then
		warn(
			"[FastCast2] SerialSimulation already started."
		)

		return
	end

	if RunService:IsClient() then

		self.Connection =
			RunService.PreSimulation:Connect(
				function(delta)
					self:UpdateCasts(delta)
				end
			)

	else

		self.Connection =
			RunService.Heartbeat:Connect(
				function(delta)
					self:UpdateCasts(delta)
				end
			)
	end
end

function SerialSimulation:Stop()

	if self.Connection then

		self.Connection:Disconnect()
		self.Connection = nil
	end
end

---------------------------------------------------------------------
-- Events
---------------------------------------------------------------------

function SerialSimulation:_UpdateEvents(
	eventName: string,
	newEventfn: (...any) -> ()
)

	self.Events[eventName] =
		newEventfn
end

return SerialSimulation
