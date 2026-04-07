extends RigidBody2D

# ==========================================
# Organic Debris: Living Particles & Bubbles
# Shader-driven animation, Brownian drift, collision squish, bubble pop
# ==========================================

@export_group("Core")
@export var radius: float = 20.0
@export var is_bubble: bool = false
@export var fluid_linear_damping: float = 8.0
@export var fluid_angular_damping: float = 10.0

@export_group("Appearance")
@export var color_organic: Color = Color(0.75, 0.55, 0.18, 0.85)
@export var color_bubble_rim: Color = Color(0.7, 0.85, 1.0, 0.35)
@export var pulse_speed: float = 1.5
@export var pulse_amount: float = 0.06

@export_group("Dynamics")
@export var brownian_force: float = 8.0
@export var squish_recovery_speed: float = 5.0
@export var bubble_pop_threshold: float = 300.0

@export_group("Depth & Lifecycle")
## Focal-plane offset: 0 = in-focus, ±1.0 = fully defocused.
@export var z_depth: float = 0.0
## Total lifetime in seconds before dissolution (0 = immortal)
@export var decomposition_lifetime: float = 0.0

# Internal state
var _noise: FastNoiseLite
var _squish_intensity: float = 0.0
var _squish_dir: Vector2 = Vector2.RIGHT
var _is_popping: bool = false
var _pop_progress: float = 0.0
var _time: float = 0.0
var _decomp_elapsed: float = 0.0
var _original_radius: float = 0.0
var _last_rebuild_radius: float = 0.0  # Track when to re-bake geometry

# Pre-baked geometry
var _body_points: PackedVector2Array
var _body_uvs: PackedVector2Array
var _body_colors: PackedColorArray
var _body_indices: PackedInt32Array
var _rim_points: PackedVector2Array

const SEGMENTS: int = 24

# ==========================================
# GLSL Shader — Organic grain / Bubble refraction
# Pulse + wobble driven by TIME (zero CPU draw cost)
# ==========================================
const DEBRIS_SHADER = """
shader_type canvas_item;

uniform int mode = 0;
uniform float pulse_speed_u = 1.5;
uniform float pulse_amount_u = 0.06;
uniform float squish_intensity = 0.0;
uniform vec2 squish_dir = vec2(1.0, 0.0);
uniform float seed_offset = 0.0;

varying vec2 local_pos;

void vertex() {
	local_pos = VERTEX;

	// Pulse (breathing)
	float pulse = sin(TIME * pulse_speed_u + seed_offset * 6.283) * pulse_amount_u;
	VERTEX *= 1.0 + pulse;

	// Wobble
	float angle = atan(VERTEX.y, VERTEX.x);
	float wf = mode == 1 ? 5.0 : 3.0;
	float ws = mode == 1 ? 3.0 : 2.0;
	float wobble = sin(TIME * ws + angle * wf + seed_offset * 10.0) * 0.02;
	VERTEX *= 1.0 + wobble;

	// Squish deformation along collision axis
	if (squish_intensity > 0.001) {
		vec2 norm_v = normalize(VERTEX + vec2(0.0001));
		float along = dot(norm_v, squish_dir);
		float stretch = along * squish_intensity * 0.3;
		float compress = (1.0 - abs(along)) * squish_intensity * 0.15;
		VERTEX *= 1.0 + stretch - compress;
	}
}

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453);
}

void fragment() {
	if (UV.x > 50.0) {
		vec2 cuv = UV - vec2(100.0, 100.0);
		float dist = length(cuv);

		if (mode == 0) {
			// === ORGANIC MODE ===
			float depth_alpha = mix(0.9, 0.45, smoothstep(0.0, 0.85, dist));

			float g1 = hash(local_pos * 1.5 + vec2(TIME * 1.2, seed_offset));
			float g2 = hash(local_pos * 0.5 - vec2(TIME * 0.6, -seed_offset));
			float grain = mix(g1, g2, 0.4);

			// Slow decomposition color shift
			float shift = sin(TIME * 0.25 + seed_offset * 3.0) * 0.04;

			vec3 color = COLOR.rgb;
			color.r += shift;
			color.g -= shift * 0.5;
			color -= grain * 0.18;

			// Rim darkening
			float rim = smoothstep(0.6, 1.0, dist) * 0.25;
			color -= rim;

			// Internal spots
			float spot = hash(floor(local_pos * 0.12) + vec2(seed_offset));
			if (spot > 0.82 && dist < 0.7) {
				color += 0.07;
			}

			COLOR = vec4(max(color, vec3(0.0)), COLOR.a * depth_alpha);
		} else {
			// === BUBBLE MODE ===
			float rim = smoothstep(0.2, 0.92, dist);
			float inner_clear = (1.0 - smoothstep(0.0, 0.4, dist)) * 0.06;

			// Specular highlights
			vec2 hl1 = vec2(0.28, -0.35);
			float spec1 = 1.0 - smoothstep(0.0, 0.2, length(cuv - hl1));
			vec2 hl2 = vec2(-0.15, 0.25);
			float spec2 = (1.0 - smoothstep(0.0, 0.1, length(cuv - hl2))) * 0.35;

			// Rainbow iridescence on rim
			float angle = atan(cuv.y, cuv.x);
			float hue = fract((angle / 6.283) + TIME * 0.06 + seed_offset);
			vec3 iri = vec3(
				sin(hue * 6.283) * 0.5 + 0.5,
				sin(hue * 6.283 + 2.094) * 0.5 + 0.5,
				sin(hue * 6.283 + 4.189) * 0.5 + 0.5
			);

			// Film thickness interference
			float film = sin(dist * 14.0 + TIME * 0.2) * 0.025 * rim;

			vec3 color = COLOR.rgb;
			color += iri * rim * 0.15;
			color += (spec1 + spec2) * vec3(1.0);
			color += film;

			float alpha = rim * 0.3 + inner_clear + (spec1 + spec2) * 0.55;
			alpha *= COLOR.a;

			COLOR = vec4(min(color, vec3(1.0)), clamp(alpha, 0.0, 0.8));
		}
	} else {
		COLOR = COLOR;
	}
}
"""

@onready var _material: ShaderMaterial = ShaderMaterial.new()

func _ready() -> void:
	_noise = FastNoiseLite.new()
	_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	_noise.seed = randi()
	_noise.frequency = 0.08
	_time = randf() * 100.0  # Desync animations

	_original_radius = radius
	_last_rebuild_radius = radius

	_configure_physics()
	_setup_shader()
	_build_collision()
	_build_visual_geometry()
	_apply_depth_defocus()

	if is_bubble:
		contact_monitor = true
		max_contacts_reported = 2
		body_entered.connect(_on_body_entered)

func _apply_depth_defocus() -> void:
	## Simulates out-of-focus objects at different Z-depths in the water column.
	## Entities far from the focal plane appear ghostly, smaller, and are layered behind/in-front.
	var defocus = abs(z_depth)
	if defocus < 0.05:
		return  # In focus — no changes

	# Alpha reduction — out-of-focus objects are translucent
	modulate.a *= lerpf(1.0, 0.2, defocus)

	# Scale reduction — depth perspective
	var depth_scale = lerpf(1.0, 0.65, defocus)
	scale *= depth_scale

	# Z-ordering — negative z_depth = behind focal plane, positive = in front
	z_index = int(z_depth * 10)

	# Heavily defocused entities should not participate in physics
	if defocus > 0.6:
		collision_layer = 0
		collision_mask = 0

func _configure_physics() -> void:
	gravity_scale = 0.0
	linear_damp = fluid_linear_damping
	angular_damp = fluid_angular_damping

	var phys_mat = PhysicsMaterial.new()
	if is_bubble:
		phys_mat.bounce = 0.8
		phys_mat.friction = 0.1
		mass = 0.2
	else:
		phys_mat.bounce = 0.2
		phys_mat.friction = 0.8
		mass = 1.5
	physics_material_override = phys_mat

func _setup_shader() -> void:
	var shader = Shader.new()
	shader.code = DEBRIS_SHADER
	_material.shader = shader
	_material.set_shader_parameter("mode", 1 if is_bubble else 0)
	_material.set_shader_parameter("pulse_speed_u", pulse_speed)
	_material.set_shader_parameter("pulse_amount_u", pulse_amount)
	_material.set_shader_parameter("seed_offset", randf())
	self.material = _material

func _build_collision() -> void:
	var collision = CollisionShape2D.new()
	var shape = CircleShape2D.new()
	shape.radius = radius
	collision.shape = shape
	add_child(collision)

func _build_visual_geometry() -> void:
	_body_points = PackedVector2Array()
	_body_uvs = PackedVector2Array()
	_body_colors = PackedColorArray()
	_body_indices = PackedInt32Array()

	var base_color = color_bubble_rim if is_bubble else color_organic

	# Center (triangle fan hub)
	_body_points.append(Vector2.ZERO)
	_body_uvs.append(Vector2(100.0, 100.0))
	_body_colors.append(base_color)

	for i in range(SEGMENTS + 1):
		var angle = (float(i) / SEGMENTS) * TAU
		var dir = Vector2(cos(angle), sin(angle))

		var noise_val = _noise.get_noise_2d(dir.x * 100.0, dir.y * 100.0)
		var edge_var: float
		if is_bubble:
			edge_var = noise_val * 0.03  # Near-perfect circle
		else:
			edge_var = noise_val * 0.18  # Irregular organic shape

		var pt = dir * radius * (1.0 + edge_var)
		_body_points.append(pt)
		_body_uvs.append(dir + Vector2(100.0, 100.0))
		_body_colors.append(base_color)

	for i in range(SEGMENTS):
		_body_indices.append(0)
		_body_indices.append(i + 1)
		_body_indices.append(i + 2)

	_rim_points = _body_points.slice(1)

# ==========================================
# Per-frame: Brownian drift + squish decay
# No queue_redraw — shader handles animation via TIME
# ==========================================
func _physics_process(delta: float) -> void:
	_time += delta

	if _is_popping:
		_pop_progress += delta * 4.0
		if _pop_progress >= 1.0:
			queue_free()
			return
		queue_redraw()
		return

	# Brownian micro-currents (local random jitter)
	var nx = _noise.get_noise_2d(_time * 40.0, 0.0)
	var ny = _noise.get_noise_2d(0.0, _time * 40.0 + 500.0)
	apply_central_force(Vector2(nx, ny) * brownian_force)

	# Global fluid current — coherent bulk flow shared with all entities
	var fluid_field = get_node_or_null("/root/FluidField")
	if fluid_field:
		var current = fluid_field.get_flow_at(global_position)
		apply_central_force(current * mass)

	# Decomposition — gradual shrink over lifetime
	if decomposition_lifetime > 0.0 and not is_bubble:
		_decomp_elapsed += delta
		var life_ratio = _decomp_elapsed / decomposition_lifetime
		if life_ratio >= 1.0:
			_dissolve()
			return
		# Shrink radius over time (accelerates near end)
		var shrink_curve = 1.0 - pow(life_ratio, 2.0)
		radius = _original_radius * shrink_curve
		# Fade alpha in the last 20% of life
		if life_ratio > 0.8:
			modulate.a = lerpf(modulate.a, 0.0, delta * 2.0)
		# Re-bake visual geometry when radius has changed substantially
		if abs(radius - _last_rebuild_radius) > _original_radius * 0.15:
			_last_rebuild_radius = radius
			_build_visual_geometry()
			queue_redraw()

	# Velocity-based squish
	var speed = linear_velocity.length()
	if speed > 10.0:
		_squish_dir = linear_velocity.normalized()
		_squish_intensity = clampf(speed / 200.0, 0.0, 0.35)
	else:
		_squish_intensity = lerpf(_squish_intensity, 0.0, delta * squish_recovery_speed)

	# Update squish uniforms only when active
	if _squish_intensity > 0.001:
		_material.set_shader_parameter("squish_intensity", _squish_intensity)
		_material.set_shader_parameter("squish_dir", _squish_dir)
	elif _squish_intensity != 0.0:
		_squish_intensity = 0.0
		_material.set_shader_parameter("squish_intensity", 0.0)

func _on_body_entered(_body: Node) -> void:
	if not is_bubble or _is_popping:
		return
	if linear_velocity.length() > bubble_pop_threshold:
		_trigger_pop()

func _dissolve() -> void:
	## End of decomposition lifecycle — remove this debris from the world.
	freeze = true
	queue_free()

func _trigger_pop() -> void:
	_is_popping = true
	_pop_progress = 0.0
	freeze = true

# ==========================================
# Draw — called once at init, then only during pop
# ==========================================
func _draw() -> void:
	if _is_popping:
		_draw_pop_effect()
		return

	var base_color = color_bubble_rim if is_bubble else color_organic

	# Shadow (organic only)
	if not is_bubble:
		var shadow_pts = PackedVector2Array()
		for p in _rim_points:
			shadow_pts.append(p * 1.15)
		draw_colored_polygon(shadow_pts, Color(0.0, 0.0, 0.0, 0.08))

	# Main body with shader
	RenderingServer.canvas_item_add_triangle_array(
		get_canvas_item(), _body_indices, _body_points, _body_colors, _body_uvs
	)

	# Rim line
	var rim_color: Color
	if is_bubble:
		rim_color = color_bubble_rim.lightened(0.3)
		rim_color.a = 0.45
		draw_polyline(_rim_points, rim_color, 1.2, true)
	else:
		rim_color = color_organic.darkened(0.2)
		rim_color.a = 0.5
		draw_polyline(_rim_points, rim_color, 1.5, true)

func _draw_pop_effect() -> void:
	var pop_scale = 1.0 + _pop_progress * 0.6
	var pop_alpha = (1.0 - _pop_progress) * color_bubble_rim.a

	# Fragmenting ring pieces
	var num_frags = 6
	for f in range(num_frags):
		var frag_angle = (float(f) / num_frags) * TAU + _pop_progress * 1.5
		var frag_center = Vector2(cos(frag_angle), sin(frag_angle)) * radius * _pop_progress * 1.2

		var frag_pts = PackedVector2Array()
		var arc_span = TAU / num_frags * 0.6
		for i in range(5):
			var a = frag_angle - arc_span * 0.5 + (float(i) / 4.0) * arc_span
			frag_pts.append(frag_center + Vector2(cos(a), sin(a)) * radius * pop_scale * 0.25)

		if frag_pts.size() >= 3:
			var c = color_bubble_rim
			c.a = pop_alpha * (1.0 - float(f) / num_frags * 0.3)
			draw_colored_polygon(frag_pts, c)

	# Central fade ring
	var ring_pts = PackedVector2Array()
	var ring_r = radius * pop_scale * 0.5
	for i in range(13):
		var a = (float(i) / 12.0) * TAU
		ring_pts.append(Vector2(cos(a), sin(a)) * ring_r)
	var rc = Color(1.0, 1.0, 1.0, pop_alpha * 0.3)
	draw_polyline(ring_pts, rc, 1.0, true)
