shader_type spatial;
render_mode blend_mix, cull_back, diffuse_lambert, specular_schlick_ggx;
uniform sampler2D DEPTH_TEXTURE : hint_depth_texture, filter_linear_mipmap;

uniform vec4 water_color : source_color = vec4(0.0, 0.329, 0.816, 0.588);
uniform float metallic : hint_range(0, 1) = 0.5;
uniform float roughness : hint_range(0, 1) = 0.1;

// Wave properties
uniform float time_scale = 1.0;
uniform float wave_strength = 0.2;
uniform float wave_speed = 1.0;
uniform float wave_frequency = 5.0;

// Depth-based transparency/color
uniform float depth_fade_near = 0.0;
uniform float depth_fade_far = 10.0;
uniform vec4 deep_water_color : source_color = vec4(0.0, 0.2, 0.6, 1.0); // Deeper blue/opaque

varying vec3 world_pos;

void vertex() {
	// Calculate world position FIRST, based on the flat plane
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	
	// Use World Position for wave calculation so waves are world-locked
	// (They won't move if the water mesh moves to follow the player)
	float wave1 = sin((world_pos.x + TIME * time_scale * wave_speed) * wave_frequency) * wave_strength;
	float wave2 = cos((world_pos.z + TIME * time_scale * wave_speed * 0.7) * wave_frequency * 1.2) * wave_strength * 0.7;
	
	VERTEX.y += wave1 + wave2;
	
	// Update world_pos.y to reflect the new height for accurate depth calculation in fragment
	// Actually, for depth calculation we want the SURFACE world pos.
	world_pos.y += wave1 + wave2;
}

void fragment() {
	// Base color and material properties
	ALBEDO = water_color.rgb;
	METALLIC = metallic;
	ROUGHNESS = roughness;
	ALPHA = water_color.a;

	// Depth calculation and fading
	// Get linear depth from scene
	float screen_depth = texture(DEPTH_TEXTURE, SCREEN_UV).r;
	
	// Reconstruct world position from depth buffer
	vec3 ndc = vec3(SCREEN_UV * 2.0 - 1.0, screen_depth);
	vec4 view = INV_PROJECTION_MATRIX * vec4(ndc, 1.0);
	view.xyz /= view.w;
	vec4 world_pos_below_water = INV_VIEW_MATRIX * view;
	
	// Calculate vertical depth of water column
	// world_pos.y is the water surface height (from vertex displacement)
	// world_pos_below_water.y is the terrain/object height
	float water_depth = world_pos.y - world_pos_below_water.y;
	
	// Clamp water_depth to avoid negative values (when looking at sky/objects above water)
	// Note: For sky, screen_depth is usually 1.0 (far plane), resulting in very large negative world Y or similar.
	// We should handle the sky case or just clamp.
	if (screen_depth >= 0.99999) {
		water_depth = 0.0; // Treat sky as surface or deep? Usually deep, but for transparency mixing...
		// If we look at the sky through water, we want it to be tinted.
		// The logic below handles large positive depth. 
		// Sky reconstructs to far away. 
	}
	
	water_depth = max(0.0, water_depth);

	float depth_lerp = smoothstep(depth_fade_near, depth_fade_far, water_depth);
	ALBEDO = mix(ALBEDO, deep_water_color.rgb, depth_lerp);
	ALPHA = mix(ALPHA, deep_water_color.a, depth_lerp);
}