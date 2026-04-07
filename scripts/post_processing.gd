extends CanvasLayer

# ==========================================
# Post-Processing: Microscope Optical Effects
# Vignette, chromatic aberration, sensor noise, subtle barrel distortion.
# Renders on top of everything via CanvasLayer at layer 100.
#
# NOTE: Uses GL Compatibility-safe approach.
# We sample the screen via a SubViewport or SCREEN_TEXTURE (available
# in GL Compatibility as a built-in).
# ==========================================

const PP_SHADER = """
shader_type canvas_item;

// We can read the backbuffer in GL Compatibility via the built-in
// texture() with SCREEN_UV. In Godot 4.x GL Compatibility,
// SCREEN_TEXTURE is exposed as a built-in sampler.
uniform sampler2D screen_texture : hint_screen_texture, filter_linear;

uniform float vignette_intensity = 0.5;
uniform float vignette_softness = 0.42;
uniform float aberration_strength = 1.2;
uniform float noise_intensity = 0.025;
uniform float barrel_distortion = 0.02;

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453);
}

vec2 barrel(vec2 uv, float k) {
	vec2 center = uv - 0.5;
	float r2 = dot(center, center);
	return uv + center * r2 * k;
}

void fragment() {
	vec2 uv = SCREEN_UV;
	vec2 center_offset = uv - 0.5;
	float dist = length(center_offset);
	
	// === BARREL DISTORTION (subtle lens curvature) ===
	vec2 distorted_uv = barrel(uv, barrel_distortion);

	// === CHROMATIC ABERRATION ===
	// Offset RGB channels radially — stronger at edges
	float aberration = dist * dist * aberration_strength * 0.004;
	float r = texture(screen_texture, barrel(uv + center_offset * aberration, barrel_distortion)).r;
	float g = texture(screen_texture, distorted_uv).g;
	float b = texture(screen_texture, barrel(uv - center_offset * aberration, barrel_distortion)).b;
	vec3 color = vec3(r, g, b);

	// === VIGNETTE (circular darkening at edges) ===
	// Simulates the view through a microscope eyepiece
	float vignette = 1.0 - smoothstep(vignette_softness, vignette_softness + 0.3, dist) * vignette_intensity;
	color *= vignette;

	// === SENSOR / FILM NOISE ===
	// Animated grain — desync per-channel for analog sensor feel
	float n1 = hash(uv * 1000.0 + vec2(TIME * 1.3, 0.0));
	float n2 = hash(uv * 1000.0 + vec2(0.0, TIME * 1.7));
	float grain = mix(n1, n2, 0.5) - 0.5; // Center around zero
	color += grain * noise_intensity;

	// === SUBTLE BLUE TINT at extreme edges (lens coating artifact) ===
	float lens_coating = smoothstep(0.5, 0.75, dist) * 0.03;
	color.b += lens_coating;

	COLOR = vec4(max(color, vec3(0.0)), 1.0);
}
""";

var _color_rect: ColorRect
var _material: ShaderMaterial

func _ready() -> void:
	layer = 100
	follow_viewport_enabled = false

	_color_rect = ColorRect.new()
	_color_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	_color_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var shader = Shader.new()
	shader.code = PP_SHADER
	_material = ShaderMaterial.new()
	_material.shader = shader
	_color_rect.material = _material

	add_child(_color_rect)
