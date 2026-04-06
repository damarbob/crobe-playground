shader_type canvas_item;

uniform float luminescence = 0.0;
uniform vec4 active_color : source_color;
uniform float time = 0.0;

varying vec2 local_pos;

void vertex() {
	local_pos = VERTEX;
}

float random(vec2 uv) {
	return fract(sin(dot(uv, vec2(12.9898, 78.233))) * 43758.5453123);
}

void fragment() {
	if (UV.x > 50.0) {
		vec2 centered_uv = UV - vec2(100.0, 100.0);
		float dist = length(centered_uv);
		
		float depth_alpha = mix(0.4, 1.0, smoothstep(0.0, 0.8, dist));
		float rim_glow = smoothstep(0.5, 0.95, dist);
		
		float grain = random(local_pos * 0.8 + vec2(time * 5.0));
		
		vec3 final_color = COLOR.rgb;
		final_color -= grain * 0.12; 
		final_color += active_color.rgb * rim_glow * luminescence * COLOR.a * 4.0;
		float final_alpha = COLOR.a * depth_alpha;
		
		COLOR = vec4(final_color, clamp(final_alpha, 0.0, 1.0));
	} else {
		COLOR = COLOR;
	}
}
