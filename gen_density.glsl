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

// ----------------------------------------------------------------------------
// Noise Functions (Gradient Noise for better quality)
// ----------------------------------------------------------------------------

vec3 hash33(vec3 p3) {
	p3 = fract(p3 * vec3(.1031, .1030, .0973));
    p3 += dot(p3, p3.yxz + 33.33);
    return -1.0 + 2.0 * fract((p3.xxy + p3.yxx) * p3.zyx);
}

// Gradient Noise 3D
float snoise(vec3 p) {
    const float K1 = 0.333333333;
    const float K2 = 0.166666667;

    vec3 i = floor(p + (p.x + p.y + p.z) * K1);
    vec3 d0 = p - (i - (i.x + i.y + i.z) * K2);

    vec3 e = step(vec3(0.0), d0 - d0.yzx);
    vec3 i1 = e * (1.0 - e.zxy);
    vec3 i2 = 1.0 - e.zxy * (1.0 - e);

    vec3 d1 = d0 - i1 + K2;
    vec3 d2 = d0 - i2 + 2.0 * K2;
    vec3 d3 = d0 - 1.0 + 3.0 * K2;

    vec4 h = max(0.6 - vec4(dot(d0, d0), dot(d1, d1), dot(d2, d2), dot(d3, d3)), 0.0);
    vec4 n = h * h * h * h * vec4(dot(d0, hash33(i)), dot(d1, hash33(i + i1)), dot(d2, hash33(i + i2)), dot(d3, hash33(i + 1.0)));

    return dot(n, vec4(52.0));
}

// Fractal Brownian Motion (3D)
float fbm(vec3 p) {
    float f = 0.0;
    float amp = 0.5;
    float freq = 1.0;
    
    for (int i = 0; i < 4; i++) { // 4 octaves
        f += snoise(p * freq) * amp;
        amp *= 0.5;
        freq *= 2.0;
    }
    return f;
}

// ----------------------------------------------------------------------------
// Density Generation Logic
// ----------------------------------------------------------------------------

float get_density(vec3 pos) {
    vec3 world_pos = pos + params.chunk_offset.xyz;
    
    // 1. Base Terrain (Heightmap-ish but 3D influenced)
    // Use low frequency noise for large hills
    float base_noise = snoise(world_pos * params.noise_freq * 0.5);
    float base_height = params.terrain_height + (base_noise * 20.0); // +/- 20 units
    
    // 2. 3D Caves / Overhangs
    // Use higher frequency 3D noise
    // We warp the space a bit for variety
    vec3 cave_pos = world_pos * params.noise_freq * 2.0;
    float cave_noise = fbm(cave_pos);
    
    // 3. Combine
    // Start with a ground plane gradient: (y - height)
    // Positive = Air, Negative = Ground
    float density = world_pos.y - base_height;
    
    // Add the 3D noise. If the 3D noise is strong enough, it will carve holes (caves)
    // or add floating islands.
    // We multiply by a factor to make the caves distinct.
    density += cave_noise * 15.0;
    
    // Optional: Hard floor to prevent infinite abyss if needed, 
    // or just let it be deep.
    
    return density;
}

void main() {
    uvec3 id = gl_GlobalInvocationID.xyz;
    
    if (id.x >= 33 || id.y >= 33 || id.z >= 33) {
        return;
    }

    uint index = id.x + (id.y * 33) + (id.z * 33 * 33);
    vec3 pos = vec3(id);
    
    density_buffer.values[index] = get_density(pos);
}