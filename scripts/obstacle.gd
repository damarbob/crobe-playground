extends StaticBody2D

# ==========================================
# Obstacle: Dead Cell Wall / Mineral Structure
# Multi-layer procedural rendering with GLSL shader
# ==========================================

@export_group("Geometry")
@export var base_size: float = 100.0
@export var sides: int = 6

@export_group("Appearance")
@export var color_primary: Color = Color(0.08, 0.18, 0.12, 0.85)
@export var color_secondary: Color = Color(0.15, 0.25, 0.1, 0.4)
@export var membrane_thickness: float = 2.0
@export var grain_intensity: float = 0.15
@export var internal_vein_count: int = 3

@export_group("Fluid Sway")
@export var sway_amplitude: float = 3.0
@export var sway_speed: float = 0.3

@export_group("Biofilm")
@export var biofilm_dot_count: int = 12
@export var biofilm_color: Color = Color(0.3, 0.45, 0.2, 0.35)

# Pre-baked geometry (drawn once, shader animates)
var _body_points: PackedVector2Array
var _body_uvs: PackedVector2Array
var _body_colors: PackedColorArray
var _body_indices: PackedInt32Array
var _rim_points: PackedVector2Array
var _inner_rim_points: PackedVector2Array
var _shadow_points: PackedVector2Array
var _vein_paths: Array[PackedVector2Array] = []
var _noise: FastNoiseLite
var _biofilm_dots: Array[Dictionary] = []  # [{"pos": Vector2, "radius": float, "phase": float}]

# ==========================================
# GLSL Shader — Depth, Grain, Rim, Pigmentation
# Uses built-in TIME for zero GDScript per-frame cost
# ==========================================
const OBSTACLE_SHADER = """
shader_type canvas_item;

uniform float grain_intensity = 0.15;
uniform float sway_amplitude = 3.0;
uniform float sway_speed = 0.3;
uniform float seed_offset = 0.0;

varying vec2 local_pos;

void vertex() {
	local_pos = VERTEX;
	float phase = seed_offset * 6.283;
	float sx = sin(TIME * sway_speed + VERTEX.y * 0.008 + phase) * sway_amplitude;
	float sy = cos(TIME * sway_speed * 0.8 + VERTEX.x * 0.006 + phase) * sway_amplitude * 0.5;
	VERTEX.x += sx;
	VERTEX.y += sy;
}

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453);
}

void fragment() {
	if (UV.x > 50.0) {
		vec2 centered_uv = UV - vec2(100.0, 100.0);
		float dist = length(centered_uv);

		// Depth gradient — brighter edges for volume illusion
		float depth = smoothstep(0.0, 1.0, dist);

		// Dual-frequency grain texture
		float g1 = hash(local_pos * 0.4 + vec2(TIME * 0.15));
		float g2 = hash(local_pos * 0.12 - vec2(TIME * 0.08));
		float grain = mix(g1, g2, 0.5);

		// Rim darkening — dense cell wall at edges
		float rim_dark = smoothstep(0.55, 1.0, dist) * 0.35;

		// Patchy pigmentation
		float patch = hash(floor(local_pos * 0.02) + vec2(seed_offset));

		vec3 color = COLOR.rgb;
		color *= mix(0.55, 1.0, depth * 0.4 + 0.6);
		color -= grain * grain_intensity;
		color -= rim_dark;
		color += (patch - 0.5) * 0.07;

		// Subtle inner glow near center
		float inner = (1.0 - smoothstep(0.0, 0.4, dist)) * 0.08;
		color += inner;

		float alpha = COLOR.a * mix(0.65, 1.0, depth);
		COLOR = vec4(max(color, vec3(0.0)), clamp(alpha, 0.0, 1.0));
	} else {
		COLOR = COLOR;
	}
}
"""

@onready var _material: ShaderMaterial = ShaderMaterial.new()

func _ready() -> void:
	_noise = FastNoiseLite.new()
	_noise.noise_type = FastNoiseLite.TYPE_CELLULAR
	_noise.seed = randi()
	_noise.frequency = 0.015

	# Shader setup — parameters set once, never updated
	var shader = Shader.new()
	shader.code = OBSTACLE_SHADER
	_material.shader = shader
	_material.set_shader_parameter("grain_intensity", grain_intensity)
	_material.set_shader_parameter("sway_amplitude", sway_amplitude)
	_material.set_shader_parameter("sway_speed", sway_speed)
	_material.set_shader_parameter("seed_offset", randf())
	self.material = _material

	_build_collision()
	_build_visual_geometry()
	_generate_veins()
	_generate_biofilm()

func _build_collision() -> void:
	var points = PackedVector2Array()
	var segments = sides * 4
	for i in range(segments):
		var angle = (float(i) / segments) * TAU
		var dir = Vector2(cos(angle), sin(angle))
		var n_val = _noise.get_noise_2d(dir.x * 200.0, dir.y * 200.0)
		var variance = 1.0 + n_val * 0.35
		points.append(dir * base_size * variance)

	var collision = CollisionPolygon2D.new()
	collision.polygon = points
	add_child(collision)

func _build_visual_geometry() -> void:
	_body_points = PackedVector2Array()
	_body_uvs = PackedVector2Array()
	_body_colors = PackedColorArray()
	_body_indices = PackedInt32Array()

	var segments = sides * 4

	# Center point (triangle fan hub)
	_body_points.append(Vector2.ZERO)
	_body_uvs.append(Vector2(100.0, 100.0))
	_body_colors.append(color_primary)

	for i in range(segments + 1):
		var angle = (float(i) / segments) * TAU
		var dir = Vector2(cos(angle), sin(angle))

		var n1 = _noise.get_noise_2d(dir.x * 200.0, dir.y * 200.0)
		var n2 = _noise.get_noise_2d(dir.x * 500.0 + 1000.0, dir.y * 500.0)
		var variance = 1.0 + n1 * 0.35 + n2 * 0.1

		var pt = dir * base_size * variance
		_body_points.append(pt)
		_body_uvs.append(dir + Vector2(100.0, 100.0))
		_body_colors.append(color_primary)

	for i in range(segments):
		_body_indices.append(0)
		_body_indices.append(i + 1)
		_body_indices.append(i + 2)

	_rim_points = _body_points.slice(1)

	_inner_rim_points = PackedVector2Array()
	for p in _rim_points:
		_inner_rim_points.append(p * 0.96)

	_shadow_points = PackedVector2Array()
	for p in _rim_points:
		_shadow_points.append(p * 1.12)

func _generate_veins() -> void:
	_vein_paths.clear()
	for v in range(internal_vein_count):
		var path = PackedVector2Array()
		var start_angle = randf() * TAU
		var start_dist = randf_range(0.05, 0.3) * base_size
		var current = Vector2(cos(start_angle), sin(start_angle)) * start_dist
		path.append(current)

		var walk_dir = Vector2(cos(start_angle + randf_range(-0.5, 0.5)),
							   sin(start_angle + randf_range(-0.5, 0.5)))
		var steps = randi_range(3, 6)
		for s in range(steps):
			walk_dir = walk_dir.rotated(randf_range(-0.4, 0.4))
			current += walk_dir * base_size * randf_range(0.12, 0.25)
			if current.length() > base_size * 0.85:
				current = current.normalized() * base_size * 0.85
			path.append(current)

		_vein_paths.append(path)

func _generate_biofilm() -> void:
	## Procedurally place bacterial colony dots along the inner surface of the obstacle.
	## Dots cluster near the rim (70-95% of radius) to simulate surface-attached biofilm.
	_biofilm_dots.clear()
	for i in range(biofilm_dot_count):
		var angle = randf() * TAU
		var dist_ratio = randf_range(0.7, 0.95)
		var dir = Vector2(cos(angle), sin(angle))

		# Match the obstacle's deformed shape
		var n_val = _noise.get_noise_2d(dir.x * 200.0, dir.y * 200.0)
		var variance = 1.0 + n_val * 0.35
		var surface_r = base_size * variance

		_biofilm_dots.append({
			"pos": dir * surface_r * dist_ratio,
			"radius": randf_range(1.5, 4.0),
			"phase": randf() * TAU
		})

# ==========================================
# Multi-Layer Draw — called once, shader animates via TIME
# ==========================================
func _draw() -> void:
	# Layer 0: Ambient shadow halo
	draw_colored_polygon(_shadow_points, Color(0.0, 0.0, 0.0, 0.1))

	# Layer 1: Main body (shader applies depth/grain/pigmentation)
	RenderingServer.canvas_item_add_triangle_array(
		get_canvas_item(), _body_indices, _body_points, _body_colors, _body_uvs
	)

	# Layer 2: Structural veins
	for vein in _vein_paths:
		if vein.size() >= 2:
			draw_polyline(vein, color_secondary, 1.5, true)

	# Layer 3: Outer rim highlight
	var rim_color = color_primary.lightened(0.25)
	rim_color.a = 0.6
	draw_polyline(_rim_points, rim_color, membrane_thickness, true)

	# Layer 4: Inner dark membrane line
	var dark_color = color_primary.darkened(0.3)
	dark_color.a = 0.3
	draw_polyline(_inner_rim_points, dark_color, 1.0, true)

	# Layer 5: Biofilm colony dots (static — _draw() fires once, shader animates the sway)
	for dot in _biofilm_dots:
		# Phase-based size variation gives spatial diversity without per-frame updates
		var r = dot["radius"] * (0.8 + sin(dot["phase"]) * 0.3)
		draw_circle(dot["pos"], r, biofilm_color)
		# Darker core
		draw_circle(dot["pos"], r * 0.4, Color(biofilm_color.r - 0.1, biofilm_color.g - 0.05, biofilm_color.b, biofilm_color.a * 0.6))
