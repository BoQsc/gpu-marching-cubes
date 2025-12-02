shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_burley, specular_schlick_ggx;

uniform sampler2D texture_grass : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D texture_rock : source_color, filter_linear_mipmap, repeat_enable;

uniform float uv_scale = 0.5;
uniform float slope_threshold : hint_range(0.0, 1.0) = 0.5;
uniform float slope_blend : hint_range(0.0, 1.0) = 0.1;

varying vec3 uv1_triplanar_pos;
varying vec3 uv1_power_normal;

void vertex() {
	// Triplanar mapping requires world position and world normal
	// But in Godot spatial shaders, VERTEX is local. 
	// We can use model matrix to get world pos if needed, or just use local if chunks are static.
	// However, since chunks are separate meshes, we want world-space texture alignment so they match at borders.
	
	vec3 world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	uv1_triplanar_pos = world_pos * uv_scale;
	
	// World normal for triplanar weights
	// MODEL_NORMAL_MATRIX transforms normal to world space
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
	
	// Calculate slope. 
	// NORMAL is in View Space in fragment shader by default in Godot 4.
	// We need it in World Space to compare with Up vector.
	// Actually, we can use the varying normal passed or transform back.
	// But wait, in Godot 4 spatial shader:
	// "NORMAL" is in View Space.
	// We want the steepness relative to the world Up (0,1,0).
	// The View Matrix transforms World to View. Inverse View transforms View to World.
	
	vec3 world_normal = (INV_VIEW_MATRIX * vec4(NORMAL, 0.0)).xyz;
	float slope = abs(dot(world_normal, vec3(0.0, 1.0, 0.0))); // 1.0 = Flat, 0.0 = Vertical wall
	
	// Smoothstep for nicer blending
	// slope_threshold defines where the rock starts.
	// e.g. 0.7: anything flatter than 0.7 dot is grass.
	// We want Walls (low dot) to be Rock.
	
	// If slope (dot) < threshold, it's rock.
	float mix_factor = smoothstep(slope_threshold - slope_blend, slope_threshold + slope_blend, slope);
	
	ALBEDO = mix(rock_col.rgb, grass_col.rgb, mix_factor);
	
	// Simple roughness/metallic
	ROUGHNESS = mix(0.6, 0.8, mix_factor); // Rock is smoother? or rougher? Adjust as needed.
	SPECULAR = 0.5;
}
