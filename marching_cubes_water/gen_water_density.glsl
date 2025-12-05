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
    float water_dens = get_base_water_density(vec3(id));
    
    // Read existing terrain density
    float terrain_dens = terrain_buffer.values[index];
    
    // Boolean Subtraction: Water MINUS Terrain
    // To carve terrain out of water, we use: min(water, -terrain)
    // Wait, marching cubes usually assumes surface at 0. 
    // Solid is positive? Or negative?
    // In gen_density.glsl: return world_pos.y - terrain_height;
    // If y > height (air), value > 0. If y < height (ground), value < 0.
    // So NEGATIVE is SOLID (inside ground), POSITIVE is AIR.
    
    // Let's check standard:
    // Usually, inside=negative, outside=positive.
    // terrain_dens < 0 means "inside rock".
    
    // Water logic:
    // We want "inside water" to be negative.
    // world_pos.y < water_level  =>  water_level - world_pos.y > 0. 
    // This would make UNDERWATER positive (Air-like).
    // That's backwards if we want standard SDF convention (dist to surface).
    // But let's look at 'marching_cubes.glsl'. It likely looks for 0 crossing.
    // The sign determines inside/outside.
    
    // Let's Stick to the convention of 'gen_density.glsl':
    // "world_pos.y - terrain_height"
    // Above ground (+), Below ground (-).
    
    // So for water:
    // "world_pos.y - water_level"
    // Above water (+), Below water (-).
    
    float base_water = (vec3(id).y + params.chunk_offset.y) - params.water_level;
    
    // Now, we want water ONLY where there is NO terrain.
    // Terrain exists where terrain_dens < 0.
    // Water exists where base_water < 0.
    
    // We want the final density to be "inside water" (negative) ONLY if:
    // 1. We are below water level (base_water < 0)
    // 2. We are NOT inside terrain (terrain_dens > 0)
    
    // Boolean Intersection: max(A, B)
    // Intersection of "Below Water" and "Above Terrain"
    // final = max(base_water, -terrain_dens? No, terrain_dens is already 'dist to ground')
    // If terrain_dens is negative (underground), we want to treat it as "Solid/Occupied".
    // We want water to be 'air' (positive) inside the rock.
    
    // Fix Z-Fighting & Gaps: Add a positive bias to terrain_dens.
    // This pushes the "Solid Ground" definition slightly inwards,
    // effectively extending the "Air" (Water) space into the terrain.
    float terrain_dens_biased = terrain_dens + 0.5;

    // Smooth Intersection: smax(A, B)
    // We blend the Water Plane (base_water) with the Terrain Hole (-terrain_dens_biased).
    // k = 3.0 provides a very smooth, wide fillet at the intersection.
    float final_density = smax(base_water, -terrain_dens_biased, 3.0);
    
    water_buffer.values[index] = final_density;
}
