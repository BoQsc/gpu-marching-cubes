shader_type spatial;

uniform vec3 albedo : source_color = vec3(0.0, 0.3, 0.5);
uniform float metallic : hint_range(0.0, 1.0) = 0.0;
uniform float roughness : hint_range(0.0, 1.0) = 0.02;
uniform vec3 wave_direction = vec3(2.0, 0.0, 1.0);
uniform float wave_speed = 1.0;
uniform float noise_scale = 10.0;
uniform float height_scale = 0.15;

// Simple time-based noise for waves
float wave(vec2 position, float time) {
	vec2 p = position / noise_scale;
	float d = dot(p, normalize(wave_direction.xz));
	return sin(d * 10.0 + time * wave_speed);
}

void vertex() {
	float time = TIME * wave_speed;
	// Displace vertices slightly
	float h = wave(VERTEX.xz, time);
	VERTEX.y += h * height_scale;
}

void fragment() {
	ALBEDO = albedo;
	METALLIC = metallic;
	ROUGHNESS = roughness;
	ALPHA = 0.8; // Transparent water
	
	// Normals for visual waves
	vec2 p = (min(VERTEX.x, VERTEX.z) * vec2(1.0)) / noise_scale;
	float t = TIME * wave_speed;
	
	// Simple normal map approximation
	vec3 normal = normalize(vec3(
		wave(p + vec2(0.1, 0.0), t) - wave(p - vec2(0.1, 0.0), t),
		2.0, // Up vector strength
		wave(p + vec2(0.0, 0.1), t) - wave(p - vec2(0.0, 0.1), t)
	));
	
	NORMAL = normal;
}
