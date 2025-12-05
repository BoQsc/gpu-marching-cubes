#[compute]
#version 450

layout(local_size_x = 4, local_size_y = 4, local_size_z = 4) in;

// Density Buffer: vec2(density, material_id)
layout(set = 0, binding = 0, std430) restrict buffer DensityBuffer {
    vec2 values[];
} density_buffer;

layout(push_constant) uniform PushConstants {
    vec4 chunk_offset;   // .xyz
    vec4 brush_pos;      // .xyz, .w = radius
    float brush_value;   // +1 to dig (make air), -1 to place (make solid)
    float material_id;   // 1.0 = Terrain, 2.0 = Water
} params;

// Standard SDF convention: Negative = Solid, Positive = Air.

void main() {
    uvec3 id = gl_GlobalInvocationID.xyz;
    if (id.x >= 33 || id.y >= 33 || id.z >= 33) return;

    uint index = id.x + (id.y * 33) + (id.z * 33 * 33);
    
    vec3 local_pos = vec3(id);
    vec3 world_pos = local_pos + params.chunk_offset.xyz;
    
    float dist = distance(world_pos, params.brush_pos.xyz);
    float radius = params.brush_pos.w;
    
    if (dist < radius) {
        vec2 current = density_buffer.values[index];
        float density = current.x;
        float mat = current.y;
        
        // Smooth falloff for density modification
        float falloff = 1.0 - (dist / radius);
        falloff = clamp(falloff, 0.0, 1.0);
        float modification = params.brush_value * falloff * 1.0; 
        
        float new_density = density + modification;
        
        // Material Logic:
        // If we are placing material (brush_value < 0):
        // We are making the density MORE NEGATIVE (more solid).
        // If we are pushing it towards solid, we should apply the brush material.
        if (params.brush_value < 0.0) {
             // Only switch material if we are actually adding significant density
             // or if it was previously air (mat == 0).
             mat = params.material_id;
        }
        // If we are digging (brush_value > 0):
        // We are making it MORE POSITIVE (Air).
        // If it becomes air (> 0), material usually becomes 0 (Air), 
        // but we can leave the ID until it's re-filled or handled by mesher.
        // For simplicity, if density > 0, effectively it's air, mesher ignores material.
        
        density_buffer.values[index] = vec2(new_density, mat);
    }
}
