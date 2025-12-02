#[compute]
#version 450

// 33x33x33 grid points to cover a 32x32x32 voxel chunk + 1 neighbor edge
layout(local_size_x = 4, local_size_y = 4, local_size_z = 4) in;

// Output: Density values
layout(set = 0, binding = 0, std430) restrict buffer DensityBuffer {
    float values[];
} density_buffer;

layout(push_constant) uniform PushConstants {
    vec4 chunk_offset; // .xyz is position
    float noise_freq;
    float terrain_height;
} params;

// Include noise functions (or duplicate them if include fails/is annoying to manage)
// We'll duplicate for simplicity to ensure self-containment in this step, 
// but ideally we'd use the include. The user has 'marching_cubes_lookup_table.glsl' 
// but the noise functions were inline. I'll inline them here.

// --- Noise Functions ---

vec2 hash(vec2 p) {
    p = vec2(dot(p, vec2(127.1, 311.7)), dot(p, vec2(269.5, 183.3)));
    return -1.0 + 2.0 * fract(sin(p) * 43758.5453123);
}

float noise(vec2 p) {
    const float K1 = 0.366025404; // (sqrt(3)-1)/2;
    const float K2 = 0.211324865; // (3-sqrt(3))/6;

    vec2 i = floor(p + (p.x + p.y) * K1);
    vec2 a = p - i + (i.x + i.y) * K2;
    float m = step(a.y, a.x); 
    vec2 o = vec2(m, 1.0 - m);
    vec2 b = a - o + K2;
    vec2 c = a - 1.0 + 2.0 * K2;

    vec3 h = max(0.5 - vec3(dot(a, a), dot(b, b), dot(c, c)), 0.0);
    vec3 n = h * h * h * h * vec3(dot(a, hash(i + 0.0)), dot(b, hash(i + o)), dot(c, hash(i + 1.0)));

    return dot(n, vec3(70.0));
}

float fbm(vec2 p, int octaves) {
    float f = 0.0;
    float w = 0.5;
    for (int i = 0; i < octaves; i++) {
        f += w * noise(p);
        p *= 2.0;
        w *= 0.5;
    }
    return f;
}

// --- Biome Specific Height Functions ---

float get_desert_height(vec2 p) {
    // Dune shape: Sharp ridges using sin/cos and absolute values
    float dune = abs(sin(p.x * 0.05) + sin(p.y * 0.05 + p.x * 0.02));
    dune += abs(sin(p.x * 0.1 + 1.0) + sin(p.y * 0.1 + 2.0)) * 0.5;
    return dune * 5.0; // Reduced to 5m dunes for flatter feel
}

float get_grass_height(vec2 p) {
    // Rolling hills: Low frequency, simple noise
    // Map noise to [0,1] and reduce amplitude for more baseline flat terrain
    float primary_hills = ((noise(p * 0.004) + 1.0) * 0.5) * 10.0; // Max height 10m
    float secondary_detail = ((noise(p * 0.015) + 1.0) * 0.5) * 2.0;  // Max height 2m
    return primary_hills + secondary_detail;
}

float get_wasteland_height(vec2 p) {
    // Jagged mountains: High frequency FBM, high amplitude
    float mountain = fbm(p * 0.02, 4);
    // Make it spikier
    mountain = mountain * mountain * sign(mountain); 
    return mountain * 60.0;
}

float get_testing_biome_height(vec2 p) {
    // --- Consolidated Detailed Terrain ---
    
    // 1. Domain Warping
    vec2 q = p;
    q.x += fbm(p * 0.004, 2) * 20.0;
    q.y += fbm(p * 0.004 + vec2(5.2, 1.3), 2) * 20.0;

    // 2. Masks
    // Mountain Mask: Increased threshold (0.2 -> 0.7) for LESS frequent large mountains
    float mountain_mask = smoothstep(0.2, 0.7, noise(q * 0.003));
    
    // Residential Mask (NEW): Areas designated for flat, walkable ground
    // Freq 0.002
    float residential_mask = smoothstep(0.1, 0.6, noise(p * 0.002 + vec2(90.0, -90.0)));

    // 3. Base Continent (More Water)
    // Subtract 1.5 to lower land, widening ocean basins significantly
    float continent = noise(p * 0.002) * 7.0 - 1.5; 

    // 4. Main Terrain Shapes
    // Smooth Mountains (Warped)
    float ridge_raw = noise(q * 0.015) * 0.5 + 0.5;
    float strata = ridge_raw * 10.0;
    float ridge = mix(ridge_raw, floor(strata) / 10.0, 0.3);
    
    // Rolling Hills
    float rolling = noise(p * 0.008);
    
    // Flatland (for Residential)
    float flatland = noise(p * 0.01) * 0.2; // Very flat

    // 5. Combine Base
    float height = 0.0;
    height += continent;

    // Calculate primary detail (Hills vs Mountains)
    float terrain_detail = mix(rolling * 2.0, ridge * 8.0, mountain_mask);
    
    // Apply Residential Flattening
    // If residential, blend towards 'flatland' and boost height slightly (+2.5) 
    // to ensure these clearings are above water level.
    float final_detail = mix(terrain_detail, flatland + 2.5, residential_mask);

    height += final_detail;

    // 6. Add Detailed Features (Restored & Integrated)
    
    // Boulders (Softened)
    float n_boulder = noise(p * 0.06);
    float boulder_h = smoothstep(0.3, 0.9, n_boulder) * 1.5;
    // Suppress boulders slightly in residential areas for easier building/walking
    height += boulder_h * (1.0 - residential_mask * 0.5);

    // Oases (Hollows)
    float n_oasis = noise(p * 0.04 + vec2(12.5, 4.1)); 
    float oasis_depth = smoothstep(0.2, 0.6, n_oasis) * 6.0;
    height -= oasis_depth * (1.0 - mountain_mask);

    // Pocket Valleys
    float n_valley = noise(p * 0.025 + vec2(50.0, 50.0));
    float valley_depth = smoothstep(0.25, 0.65, n_valley) * 9.0;
    height -= valley_depth;

    // Tiny Islands / Pockets (Mini Islands)
    // These add small peaks. If in water -> Mini Islands. If on land -> Rocky patches.
    float n_pocket_mask = smoothstep(0.6, 0.9, noise(p * 0.015 + vec2(80.0, -20.0)));
    float n_tiny_mtn = noise(p * 0.08) * 3.0;
    height += n_pocket_mask * n_tiny_mtn;

    // Rock Pools (Mid-level)
    // Great for "hanging out" spots
    float mid_level_mask = smoothstep(3.0, 5.0, height) * (1.0 - smoothstep(8.0, 12.0, height));
    float n_pool = noise(p * 0.08 + vec2(33.0, -10.0));
    float pool_depth = smoothstep(0.4, 0.8, n_pool) * 2.5; 
    height -= pool_depth * mid_level_mask;

    // Micro-detail
    height += fbm(p * 0.1, 2) * 0.4;

    // 7. Shoreline
    // Lower start (-1.0) allows low-lying flatlands near water
    float drop_start = -1.0; 
    
    // Sharpness control:
    // Mountains = Sharp Cliffs (0.5)
    // Standard = Beaches (5.0)
    // Residential = Very Gentle Beaches (6.0)
    float sharpness = mix(5.0, 0.5, mountain_mask);
    sharpness = mix(sharpness, 6.0, residential_mask);
    
    float shelf = smoothstep(drop_start, drop_start - sharpness, height);
    height -= shelf * 8.0;

    // Clamps
    height = max(height, -12.0);
    height = min(height, 15.0);

    return height;
}

float get_biome_height(vec3 world_pos) {
    return get_testing_biome_height(world_pos.xz);
}

float get_density(vec3 pos) {
    vec3 world_pos = pos + params.chunk_offset.xyz;
    
    // Base terrain height (flat plane at height 0 + biome modifications)
    float terrain_h = get_biome_height(world_pos);
    
    // We can still add global base height from params if desired, or just use generated
    terrain_h += params.terrain_height;

    // Simple heightmap density: positive below ground, negative above
    return world_pos.y - terrain_h;
}

void main() {
    uvec3 id = gl_GlobalInvocationID.xyz;
    
    // We need 33 points per axis (0..32)
    if (id.x >= 33 || id.y >= 33 || id.z >= 33) {
        return;
    }

    uint index = id.x + (id.y * 33) + (id.z * 33 * 33);
    vec3 pos = vec3(id);
    
    density_buffer.values[index] = get_density(pos);
}
