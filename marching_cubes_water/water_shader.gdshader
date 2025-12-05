shader_type spatial;
render_mode blend_mix, depth_draw_always, cull_back, diffuse_lambert, specular_schlick_ggx;

uniform vec4 albedo : source_color = vec4(0.0, 0.32, 0.43, 1.0);
uniform vec4 albedo_fresh : source_color = vec4(0.0, 0.32, 0.43, 1.0);
uniform float metallic : hint_range(0.0, 1.0) = 0.0;
uniform float roughness : hint_range(0.0, 1.0) = 0.02;
uniform float wave_direction = 1.0;
uniform float wave_speed = 1.0;
uniform float time_scale = 0.025;
uniform float noise_scale = 10.0;
uniform float height_scale = 0.15;

uniform sampler2D wave; // Noise texture for waves
uniform sampler2D texture_normal; // Normal map
uniform sampler2D texture_normal2; // Second normal map

// Depth Fade & Beer's Law
uniform float beer_factor = 0.2;
uniform float foam_distance = 0.01;
uniform float foam_max_distance = 0.4;
uniform float foam_min_distance = 0.04;
uniform vec4 foam_color : source_color = vec4(1.0);
uniform sampler2D DEPTH_TEXTURE : hint_depth_texture, filter_linear_mipmap;
uniform sampler2D SCREEN_TEXTURE : hint_screen_texture, filter_linear_mipmap;

// Triplanar blending for Marching Cubes meshes
varying vec3 uv1_triplanar_pos;

void vertex() {
	// Force flat normals for water to avoid "jelly" artifacts at terrain intersection
	NORMAL = vec3(0.0, 1.0, 0.0);
	
	// Triplanar setup (using simplified top-down for now)
	uv1_triplanar_pos = VERTEX * 0.2; // Scale UVs
}

vec4 triplanar_texture(sampler2D p_sampler, vec3 p_weights, vec3 p_triplanar_pos) {
	vec4 samp = vec4(0.0);
	samp += texture(p_sampler, p_triplanar_pos.xy) * p_weights.z;
	samp += texture(p_sampler, p_triplanar_pos.xz) * p_weights.y;
	samp += texture(p_sampler, p_triplanar_pos.zy * vec2(-1.0, 1.0)) * p_weights.x;
	return samp;
}

void fragment() {
	// Depth Calculation
	float depth_tex = texture(DEPTH_TEXTURE, SCREEN_UV).r;
	vec3 ndc = vec3(SCREEN_UV * 2.0 - 1.0, depth_tex);
	vec4 view = INV_PROJECTION_MATRIX * vec4(ndc, 1.0);
	view.xyz /= view.w;
	float linear_depth = -view.z;
	float linear_scene_depth = linear_depth; // Depth of the object behind water
	
	// Current fragment depth (approximate)
	float fragment_depth = VERTEX.z; // View space Z is negative, usually we want distance
	// Godot 4 View Space: Z is negative forward.
	// We want positive distance.
	float depth_surface = -VERTEX.z;
	
	float depth_diff = linear_scene_depth - depth_surface;
	
	// Beer's Law (Absorption)
	// Deeper water = darker/more opaque
	float alpha = 1.0 - exp(-depth_diff * beer_factor);
	
	// Foam / Edge Fade
	// If depth_diff is small, we are near shore.
	float foam_mix = clamp((1.0 - (depth_diff / foam_distance)), 0.0, 1.0);
	
	// Normal Mapping (Triplanar or scrolling)
	// For simplicity on MC mesh, let's just use world UVs (xz) for top-down water look, 
	// but triplanar is better for steep angles.
	
	vec2 time = (TIME * wave_direction) * time_scale * vec2(1.0, 1.0);
	vec2 uv = uv1_triplanar_pos.xz; // Top-down
	
	// Simple scrolling normals (placeholder noise if no texture)
	// Assuming we might not have specific textures, we'll use simple logic or placeholders.
	// But let's try to read the noise.
	
	ALBEDO = mix(albedo.rgb, albedo_fresh.rgb, foam_mix);
	ALBEDO = mix(ALBEDO, foam_color.rgb, step(0.0, foam_mix * 2.0 - 1.0) * 0.5); // Simple foam band
	
	METALLIC = metallic;
	ROUGHNESS = roughness;
	SPECULAR = 0.5;
	
	// Refraction (Optional - needs offset)
	// ALPHA = clamp(alpha + 0.1, 0.0, 1.0); // Ensure some visibility
	ALPHA = clamp(alpha * 1.2, 0.05, 0.9); // Tweaked for visibility and transparency
}
