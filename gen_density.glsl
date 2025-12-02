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
    return dune * 10.0; // 10m dunes
}

float get_grass_height(vec2 p) {
    // Rolling hills: Low frequency, simple noise
    return noise(p * 0.01) * 20.0 + noise(p * 0.03) * 5.0;
}

float get_wasteland_height(vec2 p) {
    // Jagged mountains: High frequency FBM, high amplitude
    float mountain = fbm(p * 0.02, 4);
    // Make it spikier
    mountain = mountain * mountain * sign(mountain); 
    return mountain * 60.0;
}

float get_biome_height(vec3 world_pos) {
    float biome_scale = 0.002;
    // Calculate biome value (same logic as shader ideally)
    // We use a separate low-freq noise for biome distribution
    float biome_val = fbm(world_pos.xz * biome_scale, 2);
    
    // Biome Thresholds (matching plan):
    // < -0.2 : Desert
    // -0.2 to 0.2 : Transition
    // 0.2 to 0.4 : Grass
    // > 0.6 : Wasteland
    
    float h_desert = get_desert_height(world_pos.xz);
    float h_grass = get_grass_height(world_pos.xz);
    float h_wasteland = get_wasteland_height(world_pos.xz);
    
    float final_height = h_grass; // Default
    
    // Smooth blend between biomes
    // Mix Desert -> Grass
    float desert_mix = smoothstep(-0.4, -0.1, biome_val);
    final_height = mix(h_desert, h_grass, desert_mix);
    
    // Mix Grass -> Wasteland
    float wasteland_mix = smoothstep(0.3, 0.6, biome_val);
    final_height = mix(final_height, h_wasteland, wasteland_mix);
    
    return final_height;
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
