--[[
    Locomotion
    Version: 0.2.0

    General-purpose movement service. Extends Service.

    Commands:
        :walkTo(position)          Pathfind and walk
        :runTo(position)           Pathfind and run
        :chase(targetInstance)     Pursuit with repath
        :fleeFrom(threatInstance)  Escape pathfinding
        :moveInDirection(dir)      Direct, no pathfinding
        :stop()                    Halt
        :jump()                    Manual jump
        :setSpeedMultiplier(m)     Temp speed scale

    Queries:
        :distanceTo(position)
        :isMoving()

    Events:
        onWalking onRunning onStopping onStopped
        onAccelerating(from,to) onDecelerating(from,to)
        onJumping onLanded
        onPathComputed(path) onPathBlocked() onPathCompleted()
        onWaypointReached(index, waypoint) onStuck()
        onTargetChanged(target)
]]

local RunService         = game:GetService("RunService")
local PathfindingService = game:GetService("PathfindingService")

local Service    = require(script.Parent.Parent.Service)

local Locomotion = setmetatable({}, { __index = Service })
Locomotion.__index = Locomotion

local MODE_STOP = "stop"
local MODE_WALK = "walk"
local MODE_RUN  = "run"

function Locomotion.new(cfg)
	cfg = cfg or {}

	local self = Service.new("Locomotion", {
		version  = "0.2.0",
		requires = cfg.requires or {},
	})
	setmetatable(self, Locomotion)

	self.character = cfg.character or error("Locomotion.character required")
	self.humanoid  = self.character:FindFirstChildOfClass("Humanoid")
		or error("Locomotion.character has no Humanoid")
	self.root      = self.character.PrimaryPart or self.humanoid.RootPart
		or error("Locomotion.character has no root")

	self.mode              = cfg.mode or "ground"
	self.walkSpeed         = cfg.walkSpeed or 16
	self.runSpeed          = cfg.runSpeed or 24
	self.jumpPower         = cfg.jumpPower or 50
	self.canJump           = cfg.canJump ~= false
	self.canFloat          = cfg.canFloat or false
	self.baseHipHeight     = cfg.hipHeight or 2
	self.acceleration      = cfg.acceleration or 30
	self.deceleration      = cfg.deceleration or 40
	self.repathInterval    = cfg.repathInterval or 0.5
	self.waypointThreshold = cfg.waypointThreshold or 4
	self.stuckThreshold    = cfg.stuckThreshold or 1.5
	self.stuckSampleDist   = cfg.stuckSampleDist or 0.5
	self.agentRadius       = cfg.agentRadius or 2
	self.agentHeight       = cfg.agentHeight or 5
	self.agentCanJump      = cfg.agentCanJump ~= false
	self.agentCanClimb     = cfg.agentCanClimb or false
	self.debug             = cfg.debug or false

	self.onWalking         = cfg.onWalking
	self.onRunning         = cfg.onRunning
	self.onStopping        = cfg.onStopping
	self.onStopped         = cfg.onStopped
	self.onAccelerating    = cfg.onAccelerating
	self.onDecelerating    = cfg.onDecelerating
	self.onJumping         = cfg.onJumping
	self.onLanded          = cfg.onLanded
	self.onPathComputed    = cfg.onPathComputed
	self.onPathBlocked     = cfg.onPathBlocked
	self.onPathCompleted   = cfg.onPathCompleted
	self.onWaypointReached = cfg.onWaypointReached
	self.onStuck           = cfg.onStuck
	self.onTargetChanged   = cfg.onTargetChanged

	self._command          = MODE_STOP
	self._movementMode     = MODE_STOP
	self._currentSpeed     = 0
	self._speedMultiplier  = 1.0
	self._target           = nil
	self._targetInstance   = nil
	self._commandKind      = nil
	self._direction        = Vector3.zero
	self._path             = nil
	self._waypoints        = nil
	self._waypointIndex    = 0
	self._lastRepath       = 0
	self._lastPos          = self.root.Position
	self._stuckTimer       = 0
	self._wasGrounded      = true
	self._conn             = nil
	self._running          = false
	self._debugTracks      = {}

	self.humanoid.WalkSpeed    = self.walkSpeed
	self.humanoid.JumpPower    = self.jumpPower
	self.humanoid.UseJumpPower = true

	if self.mode == "flying" then
		self.humanoid.PlatformStand = true
		self.humanoid.HipHeight     = self.baseHipHeight
	end

	return self
end

function Locomotion:start()
	if self._running then return end
	self._running = true
	self._conn = RunService.Heartbeat:Connect(function(dt)
		self:_update(dt)
	end)
end

function Locomotion:stop()
	self._running = false
	if self._conn then self._conn:Disconnect(); self._conn = nil end
	if self.humanoid then self.humanoid:Move(Vector3.zero, false) end
end

function Locomotion:destroy()
	self:stop()
	for _, t in ipairs(self._debugTracks) do
		if t.part and t.part.Parent then t.part:Destroy() end
	end
	self._debugTracks = {}
end

function Locomotion:walkTo(position)
	self._commandKind = "walk"
	self:_setDestination(position)
end

function Locomotion:runTo(position)
	self._commandKind = "run"
	self:_setDestination(position)
end

function Locomotion:chase(targetInstance)
	self._commandKind    = "chase"
	self._targetInstance = targetInstance
	if self.onTargetChanged then self.onTargetChanged(targetInstance) end
	self._lastRepath = 0
end

function Locomotion:fleeFrom(threatInstance)
	self._commandKind    = "flee"
	self._targetInstance = threatInstance
	if self.onTargetChanged then self.onTargetChanged(threatInstance) end
	self._lastRepath = 0
end

function Locomotion:moveInDirection(direction)
	self._commandKind = "direction"
	self._direction   = direction
	self:_setMovementMode(MODE_WALK)
end

function Locomotion:stop()
	self._commandKind    = "stop"
	self._target         = nil
	self._targetInstance = nil
	self._path           = nil
	self._direction      = Vector3.zero
	self:_setMovementMode(MODE_STOP)
	if self.humanoid then self.humanoid:Move(Vector3.zero, false) end
end

function Locomotion:jump()
	if not self.canJump then return end
	if self.mode == "flying" then return end
	if not self:_isGrounded() then return end
	self.humanoid.Jump = true
	if self.onJumping then self.onJumping() end
end

function Locomotion:setSpeedMultiplier(m)
	self._speedMultiplier = m
end

function Locomotion:distanceTo(position)
	local r = self.root.Position
	return (Vector3.new(position.X, r.Y, position.Z) - r).Magnitude
end

function Locomotion:isMoving()
	return self._currentSpeed > 0.1
end

function Locomotion:_setDestination(position)
	if self._target and (self._target - position).Magnitude < 0.5 then return end
	self._target      = position
	self._path        = nil
	self._waypoints   = nil
	self._lastRepath  = 0
	if self.onTargetChanged then self.onTargetChanged(position) end
end

function Locomotion:_setMovementMode(mode)
	if self._movementMode == mode then return end
	local prev         = self._movementMode
	self._movementMode = mode

	if mode == MODE_STOP then
		if self.onStopping then self.onStopping() end
	elseif mode == MODE_WALK then
		if prev == MODE_STOP and self.onWalking then self.onWalking() end
	elseif mode == MODE_RUN then
		if self.onRunning then self.onRunning() end
	end
end

function Locomotion:_update(dt)
	if self._commandKind == "walk" or self._commandKind == "run" then
		self:_followPath(dt)
	elseif self._commandKind == "chase" then
		self:_updateChase(dt)
	elseif self._commandKind == "flee" then
		self:_updateFlee(dt)
	elseif self._commandKind == "direction" then
		self:_applyMove(self._direction)
	elseif self._commandKind == "stop" then
		self:_setMovementMode(MODE_STOP)
		if self.humanoid then self.humanoid:Move(Vector3.zero, false) end
	end

	self:_updateSpeed(dt)
	self:_checkStuck(dt)
	self:_updateGrounded()
	if self.mode == "flying" then self:_updateFloating() end
	if self.debug then self:_updateDebug() end
end

function Locomotion:_computePath(from, to)
	local path = PathfindingService:CreatePath({
		AgentRadius   = self.agentRadius,
		AgentHeight   = self.agentHeight,
		AgentCanJump  = self.agentCanJump,
		AgentCanClimb = self.agentCanClimb,
	})
	local ok = pcall(function() path:ComputeAsync(from, to) end)
	if not ok or path.Status ~= Enum.PathStatus.Success then
		if self.onPathBlocked then self.onPathBlocked() end
		return nil
	end
	if self.onPathComputed then self.onPathComputed(path) end
	path.Blocked:Connect(function()
		if self.onPathBlocked then self.onPathBlocked() end
		self._path = nil
	end)
	return path
end

function Locomotion:_followPath(dt)
	local now = os.clock()
	if not self._path or (now - self._lastRepath) >= self.repathInterval then
		if not self._target then return end
		self._path = self:_computePath(self.root.Position, self._target)
		self._lastRepath = now
		if not self._path then return end
		self._waypoints     = self._path:GetWaypoints()
		self._waypointIndex = 2
		self:_setMovementMode(self._commandKind == "run" and MODE_RUN or MODE_WALK)
	end

	if not self._waypoints or self._waypointIndex > #self._waypoints then
		if self.onPathCompleted then self.onPathCompleted() end
		self:stop()
		return
	end

	local wp = self._waypoints[self._waypointIndex]

	if wp.Action == Enum.PathWaypointAction.Jump and self.canJump then
		self:jump()
	end

	local pos     = self.root.Position
	local targetY = pos.Y
	local wpPos   = Vector3.new(wp.Position.X, targetY, wp.Position.Z)
	local d       = (wpPos - pos).Magnitude

	if d < self.waypointThreshold then
		self._waypointIndex = self._waypointIndex + 1
		if self.onWaypointReached then self.onWaypointReached(self._waypointIndex - 1, wp) end
	else
		self:_applyMove((wpPos - pos).Unit)
	end
end

function Locomotion:_updateChase(dt)
	if not self._targetInstance or not self._targetInstance.Parent then
		self:stop()
		return
	end
	local now = os.clock()
	if (now - self._lastRepath) >= self.repathInterval then
		self._lastRepath = now
		local tpos = self._targetInstance:GetPivot().Position
		local dist = self:distanceTo(tpos)
		if dist < 6 then
			self:_applyMove((Vector3.new(tpos.X, self.root.Position.Y, tpos.Z) - self.root.Position).Unit)
			self:_setMovementMode(MODE_RUN)
			self._path = nil
		else
			self._target = tpos
			self._path   = self:_computePath(self.root.Position, tpos)
			if self._path then
				self._waypoints     = self._path:GetWaypoints()
				self._waypointIndex = 2
			end
			self:_setMovementMode(MODE_RUN)
		end
	end
	if self._path and self._waypoints then
		self:_followPath(dt)
	end
end

function Locomotion:_updateFlee(dt)
	if not self._targetInstance or not self._targetInstance.Parent then
		self:stop()
		return
	end
	local now = os.clock()
	if (now - self._lastRepath) >= self.repathInterval or not self._path then
		self._lastRepath = now
		local threatPos = self._targetInstance:GetPivot().Position
		local myPos     = self.root.Position
		local awayDir   = Vector3.new(myPos.X - threatPos.X, 0, myPos.Z - threatPos.Z)

		if awayDir.Magnitude < 0.01 then
			awayDir = Vector3.new(math.random() - 0.5, 0, math.random() - 0.5)
		end
		awayDir = awayDir.Unit

		local bestDir, bestClear = awayDir, -1
		for i = -2, 2 do
			local angle = i * math.rad(30)
			local rot   = CFrame.Angles(0, angle, 0)
			local cand  = (rot * awayDir).Unit
			local params = RaycastParams.new()
			params.FilterDescendantsInstances = { self.character }
			params.FilterType = Enum.RaycastFilterType.Exclude
			local hit = workspace:Raycast(myPos + Vector3.new(0, 2, 0), cand * 15, params)
			local clear = hit and (hit.Position - myPos).Magnitude or 15
			if clear > bestClear then bestDir, bestClear = cand, clear end
		end

		local destination = myPos + bestDir * math.min(30, bestClear)
		self._path = self:_computePath(myPos, destination)
		if self._path then
			self._waypoints     = self._path:GetWaypoints()
			self._waypointIndex = 2
		end
		self:_setMovementMode(MODE_RUN)
	end
	if self._path and self._waypoints then
		self:_followPath(dt)
	end
end

function Locomotion:_applyMove(direction)
	direction = Vector3.new(direction.X, 0, direction.Z)
	if direction.Magnitude < 0.01 then
		if self.humanoid then self.humanoid:Move(Vector3.zero, false) end
		return
	end
	direction = direction.Unit
	if self.mode == "ground" and self.humanoid then
		self.humanoid:Move(direction, false)
	elseif self.mode == "flying" then
		local vel = direction * self._currentSpeed
		local part = self.root
		if part:FindFirstChildOfClass("LinearVelocity") then
			part:FindFirstChildOfClass("LinearVelocity").VectorVelocity = vel
		else
			part.AssemblyLinearVelocity = Vector3.new(vel.X, 0, vel.Z)
		end
	end
end

function Locomotion:_updateSpeed(dt)
	local targetSpeed
	if self._movementMode == MODE_STOP then
		targetSpeed = 0
	elseif self._movementMode == MODE_WALK then
		targetSpeed = self.walkSpeed * self._speedMultiplier
	else
		targetSpeed = self.runSpeed * self._speedMultiplier
	end

	local prev = self._currentSpeed

	if self._currentSpeed < targetSpeed then
		self._currentSpeed = math.min(targetSpeed, self._currentSpeed + self.acceleration * dt)
		if self.onAccelerating then self.onAccelerating(prev, self._currentSpeed) end
	elseif self._currentSpeed > targetSpeed then
		self._currentSpeed = math.max(targetSpeed, self._currentSpeed - self.deceleration * dt)
		if self.onDecelerating then self.onDecelerating(prev, self._currentSpeed) end
	end

	if self._currentSpeed < 0.1 and self._movementMode == MODE_STOP and prev >= 0.1 then
		if self.onStopped then self.onStopped() end
	end

	if self.mode == "ground" and self.humanoid then
		self.humanoid.WalkSpeed = self._currentSpeed
	end
end

function Locomotion:_checkStuck(dt)
	if self._movementMode == MODE_STOP then
		self._stuckTimer = 0
		self._lastPos    = self.root.Position
		return
	end
	local moved = (self.root.Position - self._lastPos).Magnitude
	if moved < self.stuckSampleDist then
		self._stuckTimer = self._stuckTimer + dt
	else
		self._stuckTimer = 0
		self._lastPos    = self.root.Position
	end
	if self._stuckTimer >= self.stuckThreshold then
		self._stuckTimer = 0
		if self.onStuck then self.onStuck() end
		if self.canJump and self:_isGrounded() then self:jump() end
		self._path = nil
	end
end

function Locomotion:_isGrounded()
	if not self.humanoid then return false end
	return self.humanoid.FloorMaterial ~= Enum.Material.Air
end

function Locomotion:_updateGrounded()
	local g = self:_isGrounded()
	if not self._wasGrounded and g then
		if self.onLanded then self.onLanded() end
	end
	self._wasGrounded = g
end

function Locomotion:_updateFloating()
	if not self.canFloat or not self.humanoid then return end
	self.humanoid.HipHeight = self.baseHipHeight
end

function Locomotion:_updateDebug()
	local now = os.clock()
	for i = #self._debugTracks, 1, -1 do
		local t = self._debugTracks[i]
		if now >= t.expires then
			if t.part and t.part.Parent then t.part:Destroy() end
			table.remove(self._debugTracks, i)
		end
	end

	local function line(a, b, color, thick)
		local dir = b - a
		if dir.Magnitude < 0.1 then return end
		local p = Instance.new("Part")
		p.Anchored     = true
		p.CanCollide   = false
		p.CanQuery     = false
		p.CanTouch     = false
		p.Material     = Enum.Material.Neon
		p.Color        = color
		p.Transparency = 0.4
		p.Size         = Vector3.new(thick, thick, dir.Magnitude)
		p.CFrame       = CFrame.lookAt((a + b) / 2, b)
		p.Parent       = workspace
		table.insert(self._debugTracks, { part = p, expires = now + 0.1 })
	end

	if self._waypoints and self._waypoints[self._waypointIndex] then
		local wp = self._waypoints[self._waypointIndex]
		line(self.root.Position, wp.Position, Color3.fromRGB(0, 180, 255), 0.1)
	end
	if self._target then
		local p = Instance.new("Part")
		p.Anchored     = true
		p.CanCollide   = false
		p.CanQuery     = false
		p.Material     = Enum.Material.Neon
		p.Color        = self._commandKind == "flee"
			and Color3.fromRGB(255, 60, 60)
			or  Color3.fromRGB(60, 255, 120)
		p.Shape  = Enum.PartType.Ball
		p.Size   = Vector3.new(1, 1, 1)
		p.CFrame = CFrame.new(self._target)
		p.Parent = workspace
		table.insert(self._debugTracks, { part = p, expires = now + 0.1 })
	end
end

local function create(cfg)
	return Locomotion.new(cfg)
end

return create
