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
	// Triplanar setup (using simplified top-down for now)
	uv1_triplanar_pos = VERTEX * 0.2; // Scale UVs
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
	float depth_surface = -VERTEX.z;
	
	float depth_diff = linear_scene_depth - depth_surface;
	
	// Beer's Law (Absorption)
	// Deeper water = darker/more opaque
	float alpha = 1.0 - exp(-depth_diff * beer_factor);
	
	// Foam / Edge Fade
	// If depth_diff is small, we are near shore.
	float foam_mix = clamp((1.0 - (depth_diff / foam_distance)), 0.0, 1.0);
	
	vec2 time = (TIME * wave_direction) * time_scale * vec2(1.0, 1.0);
	vec2 uv = uv1_triplanar_pos.xz; // Top-down
	
	ALBEDO = mix(albedo.rgb, albedo_fresh.rgb, foam_mix);
	ALBEDO = mix(ALBEDO, foam_color.rgb, step(0.0, foam_mix * 2.0 - 1.0) * 0.5); // Simple foam band
	
	METALLIC = metallic;
	ROUGHNESS = roughness;
	SPECULAR = 0.5;
	
	// Refraction (Optional - needs offset)
	ALPHA = clamp(alpha * 1.2, 0.05, 0.9); // Tweaked for visibility and transparency
}
