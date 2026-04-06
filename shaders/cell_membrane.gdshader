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
		
		// The geometry is scaled to 1.5, so dist=1.0 is the true membrane edge
		float body_mask = smoothstep(1.02, 0.98, dist);
		float halo = smoothstep(1.5, 1.0, dist) * (1.0 - body_mask);
		float rim = smoothstep(0.5, 1.0, dist) * body_mask;
		
		float grain = random(local_pos * 0.8 + vec2(time * 5.0));
		
		// Base coloring
		vec3 cell_color = COLOR.rgb - grain * 0.12;
		
		// Additive glow effects
		vec3 glow_contribution = active_color.rgb * luminescence;
		vec3 final_color = mix(cell_color, glow_contribution, rim * 0.4);
		final_color += glow_contribution * halo * 0.8;
		
		// Alpha blending: body uses color alpha, halo fades out
		float alpha_body = COLOR.a * body_mask * mix(0.4, 1.0, smoothstep(0.0, 0.9, dist));
		float alpha_halo = halo * luminescence * 0.5;
		
		COLOR = vec4(final_color, clamp(alpha_body + alpha_halo, 0.0, 1.0));
	} else {
		COLOR = COLOR;
	}
}
