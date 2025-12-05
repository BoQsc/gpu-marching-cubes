#[compute]
#version 450

layout(local_size_x = 4, local_size_y = 4, local_size_z = 4) in;

// 1. Input: Terrain Density (Read-Only)
layout(set = 0, binding = 0, std430) readonly buffer TerrainDensity {
    float values[];
} terrain_buffer;

// 2. Output: Water Density (Write-Only)
layout(set = 0, binding = 1, std430) restrict buffer WaterDensity {
    float values[];
} water_buffer;

layout(push_constant) uniform PushConstants {
    vec4 chunk_offset;
    float water_level; // Y-coordinate of the water surface
} params;

// Simple linear water density: (WaterLevel - y)
// Positive below water, negative above.
float get_base_water_density(vec3 pos) {
    vec3 world_pos = pos + params.chunk_offset.xyz;
    return params.water_level - world_pos.y;
}

void main() {
    uvec3 id = gl_GlobalInvocationID.xyz;
    
    // 33x33x33 grid
    if (id.x >= 33 || id.y >= 33 || id.z >= 33) {
        return;
    }

    uint index = id.x + (id.y * 33) + (id.z * 33 * 33);
    
    // Calculate base water density
    // "world_pos.y - water_level"
    // Above water (+), Below water (-).
    float base_water = (vec3(id).y + params.chunk_offset.y) - params.water_level;
    
    // We do NOT subtract terrain density anymore.
    // By outputting just the water plane, we let the water mesh intersect
    // the terrain mesh naturally using the Z-buffer.
    // This guarantees a crisp, pixel-perfect intersection line (the shoreline)
    // instead of a blocky, aliased Marching Cubes intersection.
    
    water_buffer.values[index] = base_water;
}
