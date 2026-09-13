shader_type spatial;
// Roaring waterfall sheet — downward-scrolling layered noise, soft side edges.
// Compatibility/WebGL2-safe: alpha blend, unshaded, no screen reads.
render_mode unshaded, cull_disabled, blend_mix, depth_draw_opaque;
uniform sampler2D noise_tex;
uniform vec4 tint : source_color = vec4(0.8, 0.9, 0.97, 0.85);

void fragment() {
	float n = texture(noise_tex, vec2(UV.x * 1.6, UV.y * 2.6 - TIME * 0.9)).r;
	float n2 = texture(noise_tex, vec2(UV.x * 3.2 + 0.41, UV.y * 4.8 - TIME * 1.7)).r;
	float streak = clamp(n * 0.7 + n2 * 0.55, 0.0, 1.0);
	float edge = smoothstep(0.0, 0.18, UV.x) * smoothstep(1.0, 0.82, UV.x);
	float foam = smoothstep(0.75, 1.0, UV.y) * 0.35;   // extra white toward the plunge
	ALBEDO = mix(tint.rgb, vec3(1.0), foam + streak * 0.25);
	ALPHA = clamp(streak * 0.85 + foam, 0.15, 0.95) * tint.a * edge;
	EMISSION = tint.rgb * 0.12;
}
