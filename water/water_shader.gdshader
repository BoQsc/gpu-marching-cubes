shader_type spatial;
render_mode blend_mix, depth_draw_always, cull_back, diffuse_lambert, specular_schlick_ggx;

uniform vec4 water_color : source_color = vec4(0.0, 0.33, 0.82, 0.3);
uniform float metallic : hint_range(0, 1) = 0.5;
uniform float roughness : hint_range(0, 1) = 0.1;

void fragment() {
	ALBEDO = water_color.rgb;
	METALLIC = metallic;
	ROUGHNESS = roughness;
	ALPHA = water_color.a;
}