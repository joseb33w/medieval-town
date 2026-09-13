shader_type spatial;
// Boiling molten lava — TIME-scrolled noise over dark crust, with pulsing bright "bubble" cells that
// swell and pop so the surface reads as actively BOILING. Compatibility/WebGL2-safe: opaque, no screen reads.
uniform sampler2D noise_tex;

void fragment() {
	vec2 uv = UV * 2.0 + vec2(TIME * 0.03, TIME * 0.018);
	float n = texture(noise_tex, uv).r;
	float n2 = texture(noise_tex, uv * 2.3 + vec2(0.37, -TIME * 0.05)).r;
	// BOIL: sharp noise cells that pulse in and out of brightness -> bubbling molten pockets
	float b = texture(noise_tex, UV * 3.6 + vec2(-TIME * 0.05, TIME * 0.07)).r;
	float boil = pow(b, 3.0) * (0.55 + 0.45 * sin(TIME * 2.3 + b * 22.0));
	boil = max(boil, 0.0);
	float heat = smoothstep(0.28, 0.72, n * 0.65 + n2 * 0.45);
	vec3 crust = vec3(0.11, 0.03, 0.02);
	vec3 hot = mix(vec3(0.92, 0.24, 0.02), vec3(1.0, 0.92, 0.42), smoothstep(0.45, 0.9, n2));
	vec3 col = mix(crust, hot, heat);
	col += vec3(1.0, 0.72, 0.22) * boil;        // bright boiling bubbles
	ALBEDO = col * 0.4;
	EMISSION = col * (heat * 2.2 + boil * 3.2);  // glows, brightest at the boiling pockets
	ROUGHNESS = 0.85;
}
