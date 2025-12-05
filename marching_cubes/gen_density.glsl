#[compute]
#version 450

// 33x33x33 grid points to cover a 32x32x32 voxel chunk + 1 neighbor edge
layout(local_size_x = 4, local_size_y = 4, local_size_z = 4) in;

// Output: Density values (vec2: x = density, y = material_id)
// material_id: 0=Air, 1=Terrain, 2=Water
layout(set = 0, binding = 0, std430) restrict buffer DensityBuffer {
    vec2 values[];
} density_buffer;

layout(push_constant) uniform PushConstants {
    vec4 chunk_offset; // .xyz is position
    float noise_freq;
    float terrain_height;
    float water_level;
} params;

// Include noise functions (or duplicate them if include fails/is annoying to manage)
// We'll duplicate for simplicity to ensure self-containment in this step.

float hash(vec3 p) {
    p = fract(p * 0.3183099 + .1);
    p *= 17.0;
    return fract(p.x * p.y * p.z * (p.x + p.y + p.z));
}

float noise(vec3 x) {
    vec3 i = floor(x);
    vec3 f = fract(x);
    f = f * f * (3.0 - 2.0 * f);
    return mix(mix(mix( hash(i + vec3(0,0,0)), hash(i + vec3(1,0,0)), f.x),
                   mix( hash(i + vec3(0,1,0)), hash(i + vec3(1,1,0)), f.x), f.y),
               mix(mix( hash(i + vec3(0,0,1)), hash(i + vec3(1,0,1)), f.x),
                   mix( hash(i + vec3(0,1,1)), hash(i + vec3(1,1,1)), f.x), f.y), f.z);
}

// Standard SDF: Negative = Inside/Solid, Positive = Outside/Air
float get_terrain_density(vec3 world_pos) {
    float base_height = params.terrain_height;
    float hill_height = noise(vec3(world_pos.x, 0.0, world_pos.z) * params.noise_freq) * params.terrain_height; 
    float terrain_height = base_height + hill_height;
    return world_pos.y - terrain_height;
}

// Polynomial Smooth Max (for smooth intersection)
// k = smoothing radius
float smax(float a, float b, float k) {
    float h = clamp(0.5 + 0.5 * (a - b) / k, 0.0, 1.0);
    return mix(b, a, h) + k * h * (1.0 - h);
}

void main() {
    uvec3 id = gl_GlobalInvocationID.xyz;
    
    // We need 33 points per axis (0..32)
    if (id.x >= 33 || id.y >= 33 || id.z >= 33) {
        return;
    }

    uint index = id.x + (id.y * 33) + (id.z * 33 * 33);
    vec3 pos = vec3(id);
    vec3 world_pos = pos + params.chunk_offset.xyz;
    
    float d_terrain = get_terrain_density(world_pos);
    float d_water = world_pos.y - params.water_level; // Negative = Water, Positive = Air
    
    float final_density = 0.0;
    float material = 0.0; // 0 = Air
    
    // Priority: Terrain overwrites Water
    if (d_terrain < 0.0) {
        // Inside Terrain
        final_density = d_terrain;
        material = 1.0; // Terrain
    } else if (d_water < 0.0) {
        // Inside Water (and NOT inside terrain)
        // Use smax to create a smooth meniscus/shoreline for water blocks
        // The second term (-d_terrain) represents the "Air Volume" (solid when above ground).
        // Bias by -1.0 to ensure aggressive overlap and counteract smax erosion.
        final_density = smax(d_water, -d_terrain - 1.0, 4.0) - 1.0;
        material = 2.0; // Water
    } else {
        // Air - distance to closest solid surface (terrain or water)
        // This makes air regions have a proper SDF to a surface.
        final_density = min(d_terrain, d_water); 
        material = 0.0;
    }
    
    density_buffer.values[index] = vec2(final_density, material);
}
