shader_type spatial;
// Stylized TOON OCEAN — gl_compatibility / WebGL2-safe (NO SCREEN_TEXTURE refraction, which is broken on web).
// Animated sine waves (vertex), a shore->deep colour gradient + a foam band at the shoreline (both driven by a
// per-vertex DEPTH baked CPU-side into COLOR.r by water.gd from the terrain height), and a fresnel rim so the
// water catches the light at grazing angles even with bloom off. Opaque (cheap, no transparency depth-sort).
render_mode cull_disabled, diffuse_lambert;

uniform vec4 shallow_color : source_color = vec4(0.22, 0.55, 0.58, 1.0);
uniform vec4 deep_color : source_color = vec4(0.03, 0.13, 0.28, 1.0);
uniform vec4 foam_color : source_color = vec4(0.82, 0.92, 0.95, 1.0);
uniform float wave_amp = 0.22;
uniform float wave_freq = 0.35;
uniform float wave_speed = 1.1;
uniform float fresnel_power = 4.0;
uniform float water_roughness = 0.08;

varying float v_depth;

void vertex() {
	v_depth = COLOR.r;                       // 0 = shore, 1 = deep (baked by water.gd from terrain depth)
	float shore = clamp(v_depth, 0.0, 1.0);
	float w = sin(VERTEX.x * wave_freq + TIME * wave_speed)
			+ sin(VERTEX.z * wave_freq * 1.3 + TIME * wave_speed * 0.8);
	VERTEX.y += w * wave_amp * 0.5 * shore;  // calmer near the shore, swells in the deep
}

void fragment() {
	float depth = clamp(v_depth, 0.0, 1.0);
	vec3 col = mix(shallow_color.rgb, deep_color.rgb, depth);
	float foam = smoothstep(0.10, 0.0, depth);            // a foam band where the water meets land
	col = mix(col, foam_color.rgb, foam * 0.7);
	float fres = pow(1.0 - clamp(dot(normalize(NORMAL), normalize(VIEW)), 0.0, 1.0), fresnel_power);
	ALBEDO = col;
	ROUGHNESS = water_roughness;
	METALLIC = 0.0;
	SPECULAR = 0.5;
	EMISSION = foam_color.rgb * fres * 0.15;               // fresnel rim glow (reads with Environment glow off)
}
