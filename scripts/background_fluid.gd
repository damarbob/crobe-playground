extends CanvasLayer

# ==========================================
# Background Fluid Medium
# Renders the water/fluid medium via a full-screen GLSL shader.
# Features: density fog currents, caustic light refraction,
# suspended micro-particles, color temperature gradients.
# Tracks camera position so the background scrolls in world-space.
# ==========================================

const BG_SHADER = """
shader_type canvas_item;

uniform vec2 camera_position = vec2(0.0);
uniform float zoom_level = 2.0;
uniform vec2 flow_offset = vec2(0.0);

// Palette — very dark, subtle: darkfield microscopy aesthetic
uniform vec3 deep_color = vec3(0.012, 0.025, 0.04);
uniform vec3 shallow_color = vec3(0.03, 0.055, 0.035);

uniform float caustic_intensity = 0.055;
uniform float particle_density = 600.0;

// ---- Noise primitives ----

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453);
}

float hash2(vec2 p) {
	return fract(sin(dot(p, vec2(45.164, 91.391))) * 28947.1247);
}

float value_noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float a = hash(i);
	float b = hash(i + vec2(1.0, 0.0));
	float c = hash(i + vec2(0.0, 1.0));
	float d = hash(i + vec2(1.0, 1.0));
	return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

float fbm(vec2 p, int octaves) {
	float value = 0.0;
	float amp = 0.5;
	float freq_mul = 1.0;
	for (int i = 0; i < octaves; i++) {
		value += amp * value_noise(p * freq_mul);
		freq_mul *= 2.0;
		amp *= 0.5;
	}
	return value;
}

// ---- Fragment ----

void fragment() {
	// Map screen UV to world-space coordinates
	// CanvasLayer ignores camera, so we reconstruct world position manually
	vec2 viewport_size = 1.0 / SCREEN_PIXEL_SIZE;
	vec2 world_pos = camera_position + (SCREEN_UV - 0.5) * viewport_size / zoom_level;

	// Scale down to noise-friendly range
	vec2 world_uv = world_pos * 0.0008;

	// === DENSITY CURRENTS (large-scale dissolved-matter fog) ===
	// Two fbm layers at different scales, drifting with the fluid current
	float fog1 = fbm(world_uv * 3.0 + flow_offset * 0.5 + TIME * 0.012, 4);
	float fog2 = fbm(world_uv * 1.5 - flow_offset * 0.3 - TIME * 0.007, 3);
	float density = mix(fog1, fog2, 0.45);

	// === CAUSTIC LIGHT REFRACTION ===
	// Overlapping sine waves creating caustic network
	vec2 caustic_uv = world_uv * 10.0 + flow_offset * 0.2;
	float c1 = sin(caustic_uv.x * 3.5 + TIME * 0.22 + density * 2.5);
	float c2 = sin(caustic_uv.y * 2.8 - TIME * 0.18 + density * 1.8);
	float c3 = sin((caustic_uv.x + caustic_uv.y) * 2.2 + TIME * 0.13);
	float caustic = pow(abs(c1 * c2 + c2 * c3) * 0.5, 4.0) * caustic_intensity;

	// === SUSPENDED MICRO-PARTICLES (bacteria-scale) ===
	// Hash-based point field — each cell may or may not contain a particle
	vec2 particle_uv = world_uv * particle_density + flow_offset * 2.0 + TIME * 0.018;
	vec2 cell = floor(particle_uv);
	float particle = 0.0;
	float prob = hash(cell);
	if (prob > 0.990) {
		// Jitter particle position within its cell
		vec2 center = vec2(hash(cell + vec2(1.0, 0.0)), hash(cell + vec2(0.0, 1.0)));
		float d = length(fract(particle_uv) - center);
		// Animate brightness (subtle twinkle)
		float flicker = sin(TIME * hash2(cell) * 2.5 + hash(cell * 7.3) * TAU) * 0.5 + 0.5;
		particle = smoothstep(0.1, 0.0, d) * (0.08 + flicker * 0.12);
	}

	// === FILAMENT STRUCTURES (elongated organic strands) ===
	// Thin directional noise streaks to simulate mucus/filament threads
	vec2 filament_uv = world_uv * 6.0 + flow_offset * 0.8;
	float fil_noise = value_noise(vec2(filament_uv.x * 0.3, filament_uv.y * 4.0) + TIME * 0.01);
	float filament = smoothstep(0.7, 0.75, fil_noise) * 0.04;

	// === COLOR COMPOSITION ===
	vec3 base = mix(deep_color, shallow_color, density);
	base += caustic;
	base += particle;
	base += filament;

	// Color temperature variation — large-scale biome zones
	float temp = fbm(world_uv * 0.4 + TIME * 0.004, 2);
	base.r += temp * 0.01;
	base.b -= temp * 0.006;

	// Ensure no negative values
	COLOR = vec4(max(base, vec3(0.0)), 1.0);
}
""";

var _color_rect: ColorRect
var _material: ShaderMaterial
var _accumulated_flow: Vector2 = Vector2.ZERO

func _ready() -> void:
	layer = -100
	# CanvasLayer should not follow viewport transform — we handle it manually via camera_position
	follow_viewport_enabled = false

	_color_rect = ColorRect.new()
	_color_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	_color_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var shader = Shader.new()
	shader.code = BG_SHADER
	_material = ShaderMaterial.new()
	_material.shader = shader
	_color_rect.material = _material

	add_child(_color_rect)

func _process(delta: float) -> void:
	var cam = get_viewport().get_camera_2d()
	if not cam:
		return

	_material.set_shader_parameter("camera_position", cam.global_position)
	_material.set_shader_parameter("zoom_level", cam.zoom.x)

	# Sync flow direction with global FluidField so fog drifts coherently with particles
	var fluid_field = get_node_or_null("/root/FluidField")
	if fluid_field:
		var flow = fluid_field.get_flow_at(cam.global_position)
		_accumulated_flow += flow * delta * 0.0015
		_material.set_shader_parameter("flow_offset", _accumulated_flow)

