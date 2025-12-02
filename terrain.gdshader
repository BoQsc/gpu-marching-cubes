shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_burley, specular_schlick_ggx;

uniform sampler2D texture_grass : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D texture_rock : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D texture_sand : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D texture_snow : source_color, filter_linear_mipmap, repeat_enable;

uniform float uv_scale = 1.0;
uniform float slope_threshold : hint_range(0.0, 1.0) = 0.7;
uniform float slope_blend : hint_range(0.0, 1.0) = 0.1;

uniform float sand_height = 2.0;
uniform float sand_blend = 1.0;
uniform float snow_height = 12.0;
uniform float snow_blend = 4.0;

varying vec3 uv1_triplanar_pos;
varying vec3 uv1_power_normal;
varying vec3 uv1_world_pos;

void vertex() {
	vec3 world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	uv1_triplanar_pos = world_pos * uv_scale;
	uv1_world_pos = world_pos;
	
	uv1_power_normal = pow(abs(mat3(MODEL_MATRIX) * NORMAL), vec3(4.0));
	uv1_power_normal /= dot(uv1_power_normal, vec3(1.0));
}

vec4 triplanar_texture(sampler2D p_sampler, vec3 p_weights, vec3 p_triplanar_pos) {
	vec4 samp = vec4(0.0);
	samp += texture(p_sampler, p_triplanar_pos.xy) * p_weights.z;
	samp += texture(p_sampler, p_triplanar_pos.xz) * p_weights.y;
	samp += texture(p_sampler, p_triplanar_pos.zy) * p_weights.x;
	return samp;
}

void fragment() {
	vec4 grass_col = triplanar_texture(texture_grass, uv1_power_normal, uv1_triplanar_pos);
	vec4 rock_col = triplanar_texture(texture_rock, uv1_power_normal, uv1_triplanar_pos);
	vec4 sand_col = triplanar_texture(texture_sand, uv1_power_normal, uv1_triplanar_pos);
	vec4 snow_col = triplanar_texture(texture_snow, uv1_power_normal, uv1_triplanar_pos);
	
	vec3 world_normal = (INV_VIEW_MATRIX * vec4(NORMAL, 0.0)).xyz;
	float slope = abs(dot(world_normal, vec3(0.0, 1.0, 0.0))); // 1.0 = Flat, 0.0 = Vertical wall
	
	// 1. Rock vs Grass (Slope based)
	float slope_mix = smoothstep(slope_threshold - slope_blend, slope_threshold + slope_blend, slope);
	vec3 base_albedo = mix(rock_col.rgb, grass_col.rgb, slope_mix);
	float roughness = mix(0.8, 0.6, slope_mix); // Rock rougher(0.8) than grass(0.6)? Or reversed.
	
	// 2. Sand (Height based, bottom)
	// Appears below sand_height.
	float sand_mix = 1.0 - smoothstep(sand_height - sand_blend, sand_height + sand_blend, uv1_world_pos.y);
	// Sand overrides everything at bottom
	base_albedo = mix(base_albedo, sand_col.rgb, sand_mix);
	roughness = mix(roughness, 0.9, sand_mix); // Sand is rough
	
	// 3. Snow (Height based, top)
	// Appears above snow_height.
	// Only settles on flat surfaces (slope_mix is high for flat)
	float snow_height_mix = smoothstep(snow_height - snow_blend, snow_height + snow_blend, uv1_world_pos.y);
	float snow_final_mix = snow_height_mix * slope_mix; // Only on flat parts
	
	base_albedo = mix(base_albedo, snow_col.rgb, snow_final_mix);
	roughness = mix(roughness, 0.3, snow_final_mix); // Snow is smoother/shinier
	
	ALBEDO = base_albedo;
	ROUGHNESS = roughness;
	SPECULAR = 0.5;
}