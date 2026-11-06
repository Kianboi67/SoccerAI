-- SSL-inspired car soccer AI brain for YOUR OWN Roblox experience.
-- Save as a ModuleScript named SoccerAI.
--
-- API:
--   local AI = require(path.To.SoccerAI).new({
--       OpponentGoal = Vector3.new(0, 5, -250),
--       OwnGoal = Vector3.new(0, 5, 250),
--   })
--   local controls = AI:Step(carState, ballState, dt)
--
-- carState fields:
--   CFrame (required), Velocity (Vector3), Boost (0..100), Grounded (boolean)
-- ballState fields:
--   Position (Vector3), Velocity (Vector3)
--
-- Returned controls are intentions. Your own vehicle controller must apply them.
-- This is a heuristic starting point, not a trained SSL-level model.

local SoccerAI = {}
SoccerAI.__index = SoccerAI

local function clamp(x, lo, hi)
	return math.max(lo, math.min(hi, x))
end

local function flat(v)
	return Vector3.new(v.X, 0, v.Z)
end

local function unitOr(v, fallback)
	if v.Magnitude > 1e-4 then
		return v.Unit
	end
	return fallback
end

local function predictBall(position, velocity, seconds, gravity, floorY, restitution)
	local p = position
	local v = velocity
	local step = 1 / 30
	local elapsed = 0

	while elapsed < seconds do
		local h = math.min(step, seconds - elapsed)
		v = v + Vector3.new(0, -gravity * h, 0)
		p = p + v * h

		if p.Y < floorY then
			p = Vector3.new(p.X, floorY, p.Z)
			if v.Y < 0 then
				v = Vector3.new(v.X, -v.Y * restitution, v.Z)
			end
		end
		elapsed = elapsed + h
	end

	return p, v
end

function SoccerAI.new(config)
	config = config or {}

	return setmetatable({
		OpponentGoal = config.OpponentGoal or Vector3.new(0, 5, -250),
		OwnGoal = config.OwnGoal or Vector3.new(0, 5, 250),
		Gravity = config.Gravity or workspace.Gravity,
		BallFloorY = config.BallFloorY or 2,
		BounceRestitution = config.BounceRestitution or 0.62,
		MaxSpeed = config.MaxSpeed or 115,
		BoostReserve = config.BoostReserve or 18,
		AerialHeight = config.AerialHeight or 13,
		ThinkAhead = config.ThinkAhead or 0.65,
		Mode = "Position",
	}, SoccerAI)
end

function SoccerAI:Step(car, ball, dt)
	assert(car and car.CFrame, "carState.CFrame is required")
	assert(ball and ball.Position and ball.Velocity, "ballState Position and Velocity are required")

	dt = clamp(dt or 1/60, 1/240, 1/10)

	local carCF = car.CFrame
	local carPos = carCF.Position
	local carVel = car.Velocity or Vector3.zero
	local boost = car.Boost or 0
	local grounded = car.Grounded ~= false

	local predicted, predictedVelocity = predictBall(
		ball.Position,
		ball.Velocity,
		self.ThinkAhead,
		self.Gravity,
		self.BallFloorY,
		self.BounceRestitution
	)

	local ownGoal = self.OwnGoal
	local enemyGoal = self.OpponentGoal
	local ballToOwn = flat(ball.Position - ownGoal)
	local danger = ballToOwn.Magnitude < 95
		and flat(ball.Velocity):Dot(unitOr(ballToOwn, Vector3.zAxis)) < 12

	-- Choose an approach point behind the ball, on the line to the target goal.
	local attackDir = unitOr(flat(enemyGoal - predicted), Vector3.new(0, 0, -1))
	local defendDir = unitOr(flat(ownGoal - predicted), Vector3.new(0, 0, 1))

	local target
	if danger then
		self.Mode = "Defend"
		target = predicted + defendDir * 13
	elseif predicted.Y > self.AerialHeight then
		self.Mode = "Aerial"
		target = predicted - attackDir * 5
	else
		self.Mode = "Attack"
		target = predicted - attackDir * 11
	end

	-- Aim toward the target point in the car's local coordinate frame.
	local toTarget = flat(target - carPos)
	local distance = toTarget.Magnitude
	local desiredDir = unitOr(toTarget, flat(carCF.LookVector))
	local localDir = carCF:VectorToObjectSpace(desiredDir)
	local steer = clamp(localDir.X * 2.4, -1, 1)

	local forward = flat(carCF.LookVector)
	forward = unitOr(forward, Vector3.new(0, 0, -1))
	local alignment = clamp(forward:Dot(desiredDir), -1, 1)
	local speed = flat(carVel).Magnitude

	-- Slow down for tight approaches and when badly aligned.
	local desiredSpeed = self.MaxSpeed
	if distance < 24 then
		desiredSpeed = 42 + distance * 1.5
	end
	if alignment < 0.25 then
		desiredSpeed = math.min(desiredSpeed, 38)
	end

	local throttle = clamp((desiredSpeed - speed) / 35, -1, 1)
	if distance < 5 and alignment > 0.8 then
		throttle = 0.35
	end

	local jump = false
	local pitch = 0
	local yaw = steer
	local roll = 0
	local handbrake = math.abs(steer) > 0.72 and speed > 35

	if self.Mode == "Aerial" then
		local heightError = predicted.Y - carPos.Y
		jump = grounded and heightError > 7 and distance < 75
		pitch = clamp(heightError / 22, -1, 1)
		yaw = steer
		roll = clamp(-localDir.X * 0.7, -1, 1)
		throttle = 1
	end

	-- Boost only when it creates useful speed or helps reach a high ball.
	local needsSpeed = speed < desiredSpeed - 18 and alignment > 0.55
	local boostForAerial = self.Mode == "Aerial" and distance < 65
	local useBoost = boost > self.BoostReserve
		and (needsSpeed or boostForAerial)
		and alignment > 0.25

	-- If facing almost backward, prioritize turning rather than wasting boost.
	if alignment < -0.15 then
		throttle = -0.35
		useBoost = false
	end

	return {
		Mode = self.Mode,
		Target = target,
		PredictedBall = predicted,
		Throttle = throttle,
		Steer = steer,
		Boost = useBoost,
		Jump = jump,
		Handbrake = handbrake,
		Pitch = pitch,
		Yaw = yaw,
		Roll = roll,
	}
end

return SoccerAI
