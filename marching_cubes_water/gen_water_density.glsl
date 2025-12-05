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

// Simple linear water density: (y - WaterLevel)
// Negative below water (Solid), Positive above (Air).
// This matches the standard marching cubes convention (Negative = Solid).
float get_base_water_density(vec3 pos) {
    vec3 world_pos = pos + params.chunk_offset.xyz;
    return world_pos.y - params.water_level;
}

// Polynomial Smooth Max (for smooth intersection)
// k = smoothing radius
float smax(float a, float b, float k) {
    float h = clamp(0.5 + 0.5 * (a - b) / k, 0.0, 1.0);
    return mix(b, a, h) + k * h * (1.0 - h);
}

void main() {
    uvec3 id = gl_GlobalInvocationID.xyz;
    
    // 33x33x33 grid
    if (id.x >= 33 || id.y >= 33 || id.z >= 33) {
        return;
    }

    uint index = id.x + (id.y * 33) + (id.z * 33 * 33);
    
    // Calculate base water density
    // d_plane = y - level. (Negative/Solid below level).
    float base_water = get_base_water_density(vec3(id));
    
    // Read existing terrain density
    // terrain_dens = y - height. (Negative/Solid below ground).
    float terrain_dens = terrain_buffer.values[index];
    
    // We want the region that is:
    // 1. BELOW water level (base_water < 0)
    // 2. ABOVE terrain surface (terrain_dens > 0)
    
    // To treat "Above Terrain" as a "Solid" volume for intersection,
    // we invert terrain_dens:
    // air_dens = -terrain_dens. (Negative/Solid above ground).
    
    // Bias: We subtract 1.0 to aggressively push the "Air" solid boundary 
    // into the real ground. This creates a generous overlap, ensuring the 
    // water meshes firmly intersect the terrain without gaps.
    float air_dens_biased = -terrain_dens - 1.0;

    // Intersection: smax(WaterPlane, AirVolume)
    // The region that is BOTH "Below Water" AND "In the Air".
    // k = 4.0 creates a wide meniscus.
    // SUBTRACTING 1.0 (k/4) counteracts the "erosion" caused by smax,
    // ensuring the water level doesn't dip below the intended surface at the edge.
    // This forces the water to "climb" the terrain rather than shying away.
    float final_density = smax(base_water, air_dens_biased, 4.0) - 1.0;
    
    water_buffer.values[index] = final_density;
}