shader_type spatial;

uniform sampler2D texture_grass : source_color, filter_linear_mipmap;
uniform sampler2D texture_rock : source_color, filter_linear_mipmap;
uniform sampler2D texture_sand : source_color, filter_linear_mipmap;
uniform sampler2D texture_snow : source_color, filter_linear_mipmap;

uniform float uv_scale = 0.5;
uniform float biome_scale = 0.002; // Smaller = larger biomes
uniform float global_snow_amount : hint_range(0.0, 1.0) = 0.0;

varying vec3 world_pos;
varying vec3 world_normal;

// Simple 2D hash/noise for biomes
vec2 hash(vec2 p) {
	p = vec2(dot(p, vec2(127.1, 311.7)), dot(p, vec2(269.5, 183.3)));
	return -1.0 + 2.0 * fract(sin(p) * 43758.5453123);
}

float noise(vec2 p) {
	const float K1 = 0.366025404; // (sqrt(3)-1)/2;
	const float K2 = 0.211324865; // (3-sqrt(3))/6;

	vec2 i = floor(p + (p.x + p.y) * K1);
	vec2 a = p - i + (i.x + i.y) * K2;
	float m = step(a.y, a.x); 
	vec2 o = vec2(m, 1.0 - m);
	vec2 b = a - o + K2;
	vec2 c = a - 1.0 + 2.0 * K2;

	vec3 h = max(0.5 - vec3(dot(a, a), dot(b, b), dot(c, c)), 0.0);
	vec3 n = h * h * h * h * vec3(dot(a, hash(i + 0.0)), dot(b, hash(i + o)), dot(c, hash(i + 1.0)));

	return dot(n, vec3(70.0));
}

// Fractal Brownian Motion for more natural biome shapes
float fbm(vec2 p, int octaves) {
	float f = 0.0;
	float w = 0.5;
	for (int i = 0; i < octaves; i++) {
		f += w * noise(p);
		p *= 2.0;
		w *= 0.5;
	}
	return f;
}

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	world_normal = (MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz;
}

vec4 triplanar_texture(sampler2D p_sampler, vec3 p_weights, vec3 p_triplanar_pos) {
	vec4 samp = vec4(0.0);
	samp += texture(p_sampler, p_triplanar_pos.xy) * p_weights.z;
	samp += texture(p_sampler, p_triplanar_pos.xz) * p_weights.y;
	samp += texture(p_sampler, p_triplanar_pos.zy * vec2(-1.0, 1.0)) * p_weights.x;
	return samp;
}

void fragment() {
	vec3 normal = normalize(world_normal);
	vec3 weights = abs(normal);
	weights = max(weights - 0.2, 0.0);
	weights /= dot(weights, vec3(1.0));
	
	vec3 uv_pos = world_pos * uv_scale;
	
	// Sample all textures
	vec3 col_grass = triplanar_texture(texture_grass, weights, uv_pos).rgb;
	vec3 col_rock = triplanar_texture(texture_rock, weights, uv_pos).rgb;
	vec3 col_sand = triplanar_texture(texture_sand, weights, uv_pos).rgb;
	vec3 col_snow = triplanar_texture(texture_snow, weights, uv_pos).rgb;
	
	// --- Testing Biome Logic ---
	// Coastal Archipelago Texturing
	
	// The heightmap pushes "ocean" areas down. The "shelf" drop happens as height approaches 0.
	// So the beach line should be just above that drop.
	float beach_level = 2.0; 
	float beach_transition = 2.0; // range of blend
	
	// 0.0 = Full Sand, 1.0 = Full Grass
	float grass_mix = smoothstep(beach_level, beach_level + beach_transition, world_pos.y);
	
	vec3 biome_color = mix(col_sand, col_grass, grass_mix);

	// --- Slope Logic (Steep cliffs are rock) ---
	// This applies on top of the biome base
	float slope = normal.y;
	float cliff_mix = 1.0 - smoothstep(0.5, 0.7, slope);
	biome_color = mix(biome_color, col_rock, cliff_mix);
	
	// --- Dynamic Weather Snow ---
	// Applies everywhere based on global_snow_amount
	// Snow sticks to flat surfaces more (slope > 0.5)
	float weather_snow = global_snow_amount * smoothstep(0.3, 0.6, slope);
	// Also adds some noise to the snow edge
	weather_snow *= smoothstep(0.0, 1.0, noise(world_pos.xz * 0.5) + 0.5); 
	
	ALBEDO = mix(biome_color, col_snow, clamp(weather_snow, 0.0, 1.0));
}