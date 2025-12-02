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
    // --- Coastal Archipelago / Detailed Terrain ---
    
    // 1. Continent Shape (The "Mask")
    // Low frequency to define Land vs Water
    // Values < 0 will be water, > 0 land.
    float continent = noise(p * 0.0015);
    
    // 2. "Small Mountainous" Detail
    // Higher frequency, using abs() to create sharp ridges (Ridged Noise)
    // This gives the "unique small terrain" look.
    float ridge = 1.0 - abs(noise(p * 0.01)); // 0..1 range roughly (inverted ridges)
    ridge = ridge * ridge; // Sharpen the ridges
    
    // 3. General Rolling variation
    float rolling = noise(p * 0.005);
    
    // Combine:
    // If continent is low, we want to be underwater.
    // If continent is high, we add the ridges.
    
    float height = 0.0;
    
    // Base landmass height (approx 15m max)
    height += continent * 20.0; 
    
    // Add ridges only where it's likely land (or close to it) to create interesting rocky islands
    height += ridge * 10.0;
    
    // Add rolling hills for variety
    height += rolling * 5.0;
    
    // Explicit "Beach Floor" drop
    // If the combined height is low, we push it down faster to create a shelf for the water
    // This creates the "Place for water/ocean"
    // We assume water level is roughly at local height 0 relative to this function
    // So we push anything below 2.0 down.
    /*
    if (height < 2.0) {
        height -= 5.0; // Drop off to sea floor
    }
    */
    // Smoother version of the shelf drop:
    float shelf = smoothstep(5.0, 0.0, height); 
    height -= shelf * 8.0; // Drop 8m when approaching water level
    
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
