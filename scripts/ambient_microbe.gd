extends Node2D

# ==========================================
# Ambient Microbe: Passive Background Life
# Zero physics, pure visual — 4 organism types with
# biologically-inspired movement patterns and procedural drawing.
# ==========================================

enum MicrobeType { BACTERIA, FLAGELLATE, CILIATE, DIATOM }

@export var type: MicrobeType = MicrobeType.BACTERIA
@export var microbe_size: float = 4.0
@export var base_color: Color = Color(0.5, 0.6, 0.4, 0.5)

# ---- Internal state ----
var _velocity: Vector2 = Vector2.ZERO
var _target_velocity: Vector2 = Vector2.ZERO  # Steering target for gradual turns
var _tumble_timer: float = 0.0
var _time: float = 0.0
var _phase: float = 0.0       # Animation phase offset
var _drift_seed: float = 0.0  # Per-instance noise offset
var _noise: FastNoiseLite

# Flagellate-specific
var _flagellum_wave_offset: float = 0.0

# Ciliate-specific
var _reversal_timer: float = 0.0
var _cilia_phase: float = 0.0

# Diatom-specific
var _diatom_angle: float = 0.0  # Fixed orientation
var _diatom_sides: int = 4      # Rectangle or triangle

# Track for wrapping / culling
var _spawn_origin: Vector2
var _wander_radius: float = 600.0

func _ready() -> void:
	_time = randf() * 100.0  # Desync animations
	_phase = randf() * TAU
	_drift_seed = randf() * 1000.0

	_noise = FastNoiseLite.new()
	_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	_noise.seed = randi()
	_noise.frequency = 0.1

	_spawn_origin = global_position

	match type:
		MicrobeType.BACTERIA:
			_tumble_timer = randf_range(0.3, 1.5)
			_velocity = Vector2.from_angle(randf() * TAU) * randf_range(25.0, 70.0)
			_target_velocity = _velocity
		MicrobeType.FLAGELLATE:
			_velocity = Vector2.from_angle(randf() * TAU) * randf_range(40.0, 90.0)
		MicrobeType.CILIATE:
			_velocity = Vector2.from_angle(randf() * TAU) * randf_range(50.0, 100.0)
			_target_velocity = _velocity
			_reversal_timer = randf_range(2.0, 5.0)
		MicrobeType.DIATOM:
			_diatom_angle = randf() * TAU
			_diatom_sides = [3, 4, 6][randi() % 3]

func _process(delta: float) -> void:
	_time += delta

	# Sample global fluid current
	var current = Vector2.ZERO
	var fluid_field = get_node_or_null("/root/FluidField")
	if fluid_field:
		current = fluid_field.get_flow_at(global_position)

	match type:
		MicrobeType.BACTERIA:
			_process_bacteria(delta, current)
		MicrobeType.FLAGELLATE:
			_process_flagellate(delta, current)
		MicrobeType.CILIATE:
			_process_ciliate(delta, current)
		MicrobeType.DIATOM:
			_process_diatom(delta, current)

	# Soft boundary — drift back toward spawn origin if too far
	var drift_from_home = global_position - _spawn_origin
	if drift_from_home.length() > _wander_radius:
		var pull = -drift_from_home.normalized() * 15.0
		_velocity += pull * delta

	global_position += (_velocity + current) * delta
	# Bodies are drawn with forward along -Y; velocity.angle() measures from +X.
	# Offset by PI/2 so the -Y axis (drawn forward) aligns with movement direction.
	if _velocity.length() > 1.0:
		rotation = _velocity.angle() + PI * 0.5

	queue_redraw()

# ==========================================
# Movement Behaviors
# ==========================================

func _process_bacteria(delta: float, _current: Vector2) -> void:
	## Run-and-tumble chemotaxis: straight runs with gradual tumble transitions
	_tumble_timer -= delta
	if _tumble_timer <= 0.0:
		# Pick new target direction (tumble event), but transition smoothly
		_target_velocity = Vector2.from_angle(randf() * TAU) * randf_range(25.0, 70.0)
		_tumble_timer = randf_range(0.3, 1.5)

	# Gradual angular steering toward target direction
	var steer_rate = 5.0  # Angular catch-up speed (rad/s equivalent in lerp)
	var current_angle = _velocity.angle()
	var target_angle = _target_velocity.angle()
	var new_angle = lerp_angle(current_angle, target_angle, delta * steer_rate)
	var new_speed = lerpf(_velocity.length(), _target_velocity.length(), delta * steer_rate)
	_velocity = Vector2.from_angle(new_angle) * new_speed

func _process_flagellate(delta: float, _current: Vector2) -> void:
	## Sinusoidal path with gradual turning — whip-like tail propulsion
	## All oscillation parameters scale inversely with size: larger = smoother.
	var size_factor = clampf(4.0 / maxf(microbe_size, 1.0), 0.15, 1.5)

	_flagellum_wave_offset += delta * (40.0 * size_factor)

	# Gradual direction wander — turn rate scales down with size
	var turn = _noise.get_noise_2d(_time * 20.0 + _drift_seed, 0.0) * 2.5 * size_factor
	_velocity = _velocity.rotated(turn * delta)

	# Speed oscillation (thrust pulses from flagellum)
	var thrust = 60.0 + sin(_time * 4.0 * size_factor + _phase) * 20.0
	_velocity = _velocity.normalized() * thrust

	# Lateral wobble perpendicular to travel direction — amplitude scales down with size
	var perp = _velocity.normalized().rotated(PI * 0.5)
	global_position += perp * sin(_flagellum_wave_offset) * (1.5 * size_factor)

func _process_ciliate(delta: float, _current: Vector2) -> void:
	## Smooth glide with gradual reversal — cilia beat pattern
	_cilia_phase += delta * 12.0
	_reversal_timer -= delta

	if _reversal_timer <= 0.0:
		# Set reversal target — actual velocity will steer toward it gradually
		_target_velocity = -_velocity.rotated(randf_range(-0.8, 0.8))
		_reversal_timer = randf_range(2.0, 6.0)

	# Gradual angular steering toward target + noise-based micro-wander
	var steer_rate = 2.5
	var current_angle = _velocity.angle()
	var target_angle = _target_velocity.angle()
	var steered_angle = lerp_angle(current_angle, target_angle, delta * steer_rate)

	# Layer noise-based wandering on top of the base steering
	var wander = _noise.get_noise_2d(_time * 10.0 + _drift_seed, 500.0) * 0.6
	steered_angle += wander * delta

	# Maintain oscillating speed
	var target_speed = 65.0 + sin(_time * 0.5 + _phase) * 15.0
	_velocity = Vector2.from_angle(steered_angle) * target_speed

	# Keep target velocity magnitude in sync for consistent future reversals
	_target_velocity = _target_velocity.normalized() * target_speed

func _process_diatom(delta: float, _current: Vector2) -> void:
	## Pure passive drift — no self-propulsion. Slow tumble rotation.
	_velocity *= pow(0.3, delta)  # Framerate-independent exponential decay
	_diatom_angle += delta * 0.15  # Very slow spin

# ==========================================
# Procedural Drawing
# ==========================================

func _draw() -> void:
	match type:
		MicrobeType.BACTERIA:
			_draw_bacteria()
		MicrobeType.FLAGELLATE:
			_draw_flagellate()
		MicrobeType.CILIATE:
			_draw_ciliate()
		MicrobeType.DIATOM:
			_draw_diatom()

func _draw_bacteria() -> void:
	## Rod or coccus shape with subtle internal grain
	var is_rod = microbe_size > 3.5
	if is_rod:
		# Rod-shaped (bacillus): elongated capsule
		var hw = microbe_size * 0.4  # Half-width
		var hl = microbe_size        # Half-length
		var pts = PackedVector2Array()
		var segments = 8
		# Top cap
		for i in range(segments + 1):
			var a = PI + (float(i) / segments) * PI
			pts.append(Vector2(cos(a) * hw, sin(a) * hw - hl + hw))
		# Bottom cap
		for i in range(segments + 1):
			var a = (float(i) / segments) * PI
			pts.append(Vector2(cos(a) * hw, sin(a) * hw + hl - hw))

		draw_colored_polygon(pts, base_color)
		# Division line (binary fission hint)
		var div_alpha = sin(_time * 0.3 + _phase) * 0.3 + 0.2
		draw_line(Vector2(-hw, 0.0), Vector2(hw, 0.0),
				  Color(base_color.r * 0.6, base_color.g * 0.6, base_color.b * 0.6, div_alpha), 0.5)
	else:
		# Coccus (spherical)
		draw_circle(Vector2.ZERO, microbe_size, base_color)
		# Internal granule
		var granule_pos = Vector2(
			sin(_time * 0.5 + _drift_seed) * microbe_size * 0.2,
			cos(_time * 0.4 + _drift_seed) * microbe_size * 0.2)
		draw_circle(granule_pos, microbe_size * 0.35, Color(base_color.r + 0.1, base_color.g + 0.1, base_color.b, base_color.a * 0.6))

func _draw_flagellate() -> void:
	## Teardrop body + trailing flagellum (whip-like sine wave)
	## Body is oriented with wide head at -Y (forward) and narrow tail at +Y.
	var body_pts = PackedVector2Array()
	var segments = 16
	for i in range(segments + 1):
		var t = float(i) / segments
		var a = t * TAU
		# Teardrop: wide head at -Y (forward), narrow tail at +Y
		# -sin(a) peaks at a=3PI/2 (-Y) and dips at a=PI/2 (+Y)
		var r = microbe_size * (0.8 - 0.4 * sin(a))
		var pt = Vector2(cos(a) * r * 0.6, sin(a) * r)
		body_pts.append(pt)

	draw_colored_polygon(body_pts, base_color)

	# Nucleus dot (toward the head / front)
	draw_circle(Vector2(0.0, -microbe_size * 0.35), microbe_size * 0.2,
				Color(base_color.r + 0.15, base_color.g + 0.15, base_color.b + 0.1, base_color.a * 0.8))

	# Flagellum — sine wave trailing from the tail center
	# The tail's narrowest point (a=PI/2) is at y = 0.4 * microbe_size
	var tail_y = microbe_size * 0.4
	var flag_pts = PackedVector2Array()
	var flag_length = microbe_size * 3.0
	var flag_segments = 12
	var size_factor = clampf(4.0 / maxf(microbe_size, 1.0), 0.15, 1.5)
	for i in range(flag_segments + 1):
		var ft = float(i) / flag_segments
		var y = tail_y + ft * flag_length
		# Increased amplitude from 0.3 to 0.7 for bigger whipping effect
		var x = sin(ft * 6.0 + _flagellum_wave_offset) * microbe_size * 0.7 * ft * size_factor
		flag_pts.append(Vector2(x, y))

	if flag_pts.size() >= 2:
		var flag_color = base_color
		flag_color.a *= 0.6
		draw_polyline(flag_pts, flag_color, 0.8, true)

func _draw_ciliate() -> void:
	## Oval body with animated cilia dots around perimeter
	var body_pts = PackedVector2Array()
	var segments = 20
	var cilia_positions: Array[Vector2] = []
	for i in range(segments + 1):
		var a = (float(i) / segments) * TAU
		var rx = microbe_size * 0.65
		var ry = microbe_size * 1.2
		var pt = Vector2(cos(a) * rx, sin(a) * ry)
		body_pts.append(pt)
		# Store cilia attachment points
		if i < segments and i % 2 == 0:
			cilia_positions.append(pt)

	draw_colored_polygon(body_pts, base_color)

	# Oral groove (mouth)
	var groove_color = base_color.darkened(0.3)
	groove_color.a = 0.5
	draw_arc(Vector2(microbe_size * 0.15, -microbe_size * 0.3), microbe_size * 0.3,
			 -PI * 0.3, PI * 0.5, 6, groove_color, 0.7)

	# Animated cilia — small lines that beat in metachronal wave
	for ci in range(cilia_positions.size()):
		var cp = cilia_positions[ci]
		var outward = cp.normalized()
		# Metachronal wave: phase offset per cilium
		var beat_phase = _cilia_phase + float(ci) * 0.5
		var beat_angle = sin(beat_phase) * 0.6
		var tip_dir = outward.rotated(beat_angle)
		var tip = cp + tip_dir * microbe_size * 0.35
		var cilia_color = base_color
		cilia_color.a *= 0.5
		draw_line(cp, tip, cilia_color, 0.6)

	# Macronucleus (kidney-bean shaped — approximate with two overlapping circles)
	var nuc_color = Color(base_color.r + 0.1, base_color.g + 0.1, base_color.b + 0.15, 0.4)
	draw_circle(Vector2(0.0, -microbe_size * 0.1), microbe_size * 0.3, nuc_color)
	draw_circle(Vector2(0.0, microbe_size * 0.15), microbe_size * 0.25, nuc_color)

func _draw_diatom() -> void:
	## Geometric glass-like shell — frustule
	var pts = PackedVector2Array()
	var inner_pts = PackedVector2Array()
	for i in range(_diatom_sides):
		var a = _diatom_angle + (float(i) / _diatom_sides) * TAU
		var pt = Vector2(cos(a), sin(a)) * microbe_size
		pts.append(pt)
		inner_pts.append(pt * 0.7)

	# Outer silica shell — glass-like translucent
	var shell_color = Color(0.5, 0.65, 0.7, 0.25)
	draw_colored_polygon(pts, shell_color)

	# Inner chamber
	var inner_color = Color(0.3, 0.5, 0.3, 0.15)
	draw_colored_polygon(inner_pts, inner_color)

	# Structural lines (raphe / striae)
	var line_color = Color(0.6, 0.7, 0.75, 0.3)
	for i in range(_diatom_sides):
		draw_line(pts[i], inner_pts[i], line_color, 0.5)

	# Central node
	draw_circle(Vector2.ZERO, microbe_size * 0.15,
				Color(0.4, 0.55, 0.35, 0.35))
