#[compute]
#version 450

layout(local_size_x = 8, local_size_y = 8, local_size_z = 8) in;

// BINDINGS
layout(set = 0, binding = 0, std430) restrict buffer OutputVerticesTerrain {
    float vertices[]; 
} mesh_output_terrain;

layout(set = 0, binding = 1, std430) restrict buffer OutputVerticesWater {
    float vertices[]; 
} mesh_output_water;

layout(set = 0, binding = 2, std430) restrict buffer CounterBuffer {
    uint count_terrain;
    uint count_water;
} counter;

layout(set = 0, binding = 3, std430) restrict buffer DensityBuffer {
    vec2 values[];
} density_buffer;

layout(push_constant) uniform PushConstants {
    vec4 chunk_offset;
    float noise_freq;
    float terrain_height;
} params;

const int CHUNK_SIZE = 32;
const float ISO_LEVEL = 0.0;

#include "res://marching_cubes/marching_cubes_lookup_table.glsl"

vec2 get_voxel_data(vec3 p) {
    int x = int(round(p.x));
    int y = int(round(p.y));
    int z = int(round(p.z));
    x = clamp(x, 0, 32);
    y = clamp(y, 0, 32);
    z = clamp(z, 0, 32);
    uint index = x + (y * 33) + (z * 33 * 33);
    return density_buffer.values[index];
}

// Calculate normal based on the density field of the SPECIFIC material pass
// If we are meshing Terrain, we treat Water as Air (+1.0) for gradient calc too
vec3 get_normal_for_pass(vec3 pos, int pass_id) {
    // pass_id: 1 = Terrain, 2 = Water
    vec3 n;
    float d = 1.0;
    
    // Helper to sample density with masking
    // We need to sample 6 neighbors. This is expensive but necessary for correct normals at the interface.
    vec3 offsets[6] = {
        vec3(d,0,0), vec3(-d,0,0),
        vec3(0,d,0), vec3(0,-d,0),
        vec3(0,0,d), vec3(0,0,-d)
    };
    
    float samples[6];
    for(int i=0; i<6; i++) {
        vec2 data = get_voxel_data(pos + offsets[i]);
        float val = data.x;
        float mat = data.y;
        
        if (pass_id == 1) { // Terrain Pass
            if (mat > 1.5) val = 0.0; // Treat Water as Surface (0.0) to extend mesh to it
        } else { // Water Pass
            if (mat > 0.5 && mat < 1.5) val = 0.0; // Treat Terrain as Surface (0.0) to extend mesh to it
        }
        samples[i] = val;
    }
    
    n.x = samples[0] - samples[1];
    n.y = samples[2] - samples[3];
    n.z = samples[4] - samples[5];
    
    return normalize(n);
}

vec3 interpolate_vertex(vec3 p1, vec3 p2, float v1, float v2) {
    if (abs(ISO_LEVEL - v1) < 0.00001) return p1;
    if (abs(ISO_LEVEL - v2) < 0.00001) return p2;
    if (abs(v1 - v2) < 0.00001) return p1;
    return p1 + (ISO_LEVEL - v1) * (p2 - p1) / (v2 - v1);
}

// Generic function to generate mesh for a specific material ID
// target_mat_id: 1 = Terrain, 2 = Water
void generate_mesh_for_material(uvec3 id, int target_mat_id) {
    vec3 pos = vec3(id);
    vec3 corners[8] = vec3[](
        pos + vec3(0,0,0), pos + vec3(1,0,0), pos + vec3(1,0,1), pos + vec3(0,0,1),
        pos + vec3(0,1,0), pos + vec3(1,1,0), pos + vec3(1,1,1), pos + vec3(0,1,1)
    );

    float densities[8];
    for(int i = 0; i < 8; i++) {
        vec2 data = get_voxel_data(corners[i]);
        float d = data.x;
        float m = data.y;
        
        // MASKING LOGIC
        if (target_mat_id == 1) { // Terrain Pass
            // Ignore Water (Treat as Surface 0.0)
            // This causes the terrain to "reach out" and touch the water voxel center
            if (m > 1.5) d = 0.0;
        } else { // Water Pass
            // Ignore Terrain (Treat as Surface 0.0)
            if (m > 0.5 && m < 1.5) d = 0.0;
        }
        
        densities[i] = d;
    }

    int cubeIndex = 0;
    if (densities[0] < ISO_LEVEL) cubeIndex |= 1;
    if (densities[1] < ISO_LEVEL) cubeIndex |= 2;
    if (densities[2] < ISO_LEVEL) cubeIndex |= 4;
    if (densities[3] < ISO_LEVEL) cubeIndex |= 8;
    if (densities[4] < ISO_LEVEL) cubeIndex |= 16;
    if (densities[5] < ISO_LEVEL) cubeIndex |= 32;
    if (densities[6] < ISO_LEVEL) cubeIndex |= 64;
    if (densities[7] < ISO_LEVEL) cubeIndex |= 128;

    if (edgeTable[cubeIndex] == 0) return;

    vec3 vertList[12];
    // Interpolate vertices on edges
    if ((edgeTable[cubeIndex] & 1) != 0)    vertList[0] = interpolate_vertex(corners[0], corners[1], densities[0], densities[1]);
    if ((edgeTable[cubeIndex] & 2) != 0)    vertList[1] = interpolate_vertex(corners[1], corners[2], densities[1], densities[2]);
    if ((edgeTable[cubeIndex] & 4) != 0)    vertList[2] = interpolate_vertex(corners[2], corners[3], densities[2], densities[3]);
    if ((edgeTable[cubeIndex] & 8) != 0)    vertList[3] = interpolate_vertex(corners[3], corners[0], densities[3], densities[0]);
    if ((edgeTable[cubeIndex] & 16) != 0)   vertList[4] = interpolate_vertex(corners[4], corners[5], densities[4], densities[5]);
    if ((edgeTable[cubeIndex] & 32) != 0)   vertList[5] = interpolate_vertex(corners[5], corners[6], densities[5], densities[6]);
    if ((edgeTable[cubeIndex] & 64) != 0)   vertList[6] = interpolate_vertex(corners[6], corners[7], densities[6], densities[7]);
    if ((edgeTable[cubeIndex] & 128) != 0)  vertList[7] = interpolate_vertex(corners[7], corners[4], densities[7], densities[4]);
    if ((edgeTable[cubeIndex] & 256) != 0)  vertList[8] = interpolate_vertex(corners[0], corners[4], densities[0], densities[4]);
    if ((edgeTable[cubeIndex] & 512) != 0)  vertList[9] = interpolate_vertex(corners[1], corners[5], densities[1], densities[5]);
    if ((edgeTable[cubeIndex] & 1024) != 0) vertList[10] = interpolate_vertex(corners[2], corners[6], densities[2], densities[6]);
    if ((edgeTable[cubeIndex] & 2048) != 0) vertList[11] = interpolate_vertex(corners[3], corners[7], densities[3], densities[7]);

    for (int i = 0; triTable[cubeIndex * 16 + i] != -1; i += 3) {
        
        uint idx;
        if (target_mat_id == 1) idx = atomicAdd(counter.count_terrain, 1);
        else idx = atomicAdd(counter.count_water, 1);
        
        uint start_ptr = idx * 18; 

        vec3 v1 = vertList[triTable[cubeIndex * 16 + i]];
        vec3 v2 = vertList[triTable[cubeIndex * 16 + i + 1]];
        vec3 v3 = vertList[triTable[cubeIndex * 16 + i + 2]];

        vec3 n1 = get_normal_for_pass(v1, target_mat_id);
        vec3 n2 = get_normal_for_pass(v2, target_mat_id);
        vec3 n3 = get_normal_for_pass(v3, target_mat_id);
        
        // Write
        if (target_mat_id == 1) {
            mesh_output_terrain.vertices[start_ptr + 0] = v1.x;
            mesh_output_terrain.vertices[start_ptr + 1] = v1.y;
            mesh_output_terrain.vertices[start_ptr + 2] = v1.z;
            mesh_output_terrain.vertices[start_ptr + 3] = n1.x;
            mesh_output_terrain.vertices[start_ptr + 4] = n1.y;
            mesh_output_terrain.vertices[start_ptr + 5] = n1.z;
            
            mesh_output_terrain.vertices[start_ptr + 6] = v3.x;
            mesh_output_terrain.vertices[start_ptr + 7] = v3.y;
            mesh_output_terrain.vertices[start_ptr + 8] = v3.z;
            mesh_output_terrain.vertices[start_ptr + 9] = n3.x;
            mesh_output_terrain.vertices[start_ptr + 10] = n3.y;
            mesh_output_terrain.vertices[start_ptr + 11] = n3.z;
            
            mesh_output_terrain.vertices[start_ptr + 12] = v2.x;
            mesh_output_terrain.vertices[start_ptr + 13] = v2.y;
            mesh_output_terrain.vertices[start_ptr + 14] = v2.z;
            mesh_output_terrain.vertices[start_ptr + 15] = n2.x;
            mesh_output_terrain.vertices[start_ptr + 16] = n2.y;
            mesh_output_terrain.vertices[start_ptr + 17] = n2.z;
        } else {
            mesh_output_water.vertices[start_ptr + 0] = v1.x;
            mesh_output_water.vertices[start_ptr + 1] = v1.y;
            mesh_output_water.vertices[start_ptr + 2] = v1.z;
            mesh_output_water.vertices[start_ptr + 3] = n1.x;
            mesh_output_water.vertices[start_ptr + 4] = n1.y;
            mesh_output_water.vertices[start_ptr + 5] = n1.z;
            
            mesh_output_water.vertices[start_ptr + 6] = v3.x;
            mesh_output_water.vertices[start_ptr + 7] = v3.y;
            mesh_output_water.vertices[start_ptr + 8] = v3.z;
            mesh_output_water.vertices[start_ptr + 9] = n3.x;
            mesh_output_water.vertices[start_ptr + 10] = n3.y;
            mesh_output_water.vertices[start_ptr + 11] = n3.z;
            
            mesh_output_water.vertices[start_ptr + 12] = v2.x;
            mesh_output_water.vertices[start_ptr + 13] = v2.y;
            mesh_output_water.vertices[start_ptr + 14] = v2.z;
            mesh_output_water.vertices[start_ptr + 15] = n2.x;
            mesh_output_water.vertices[start_ptr + 16] = n2.y;
            mesh_output_water.vertices[start_ptr + 17] = n2.z;
        }
    }
}

void main() {
    uvec3 id = gl_GlobalInvocationID.xyz;
    if (id.x >= CHUNK_SIZE - 1 || id.y >= CHUNK_SIZE - 1 || id.z >= CHUNK_SIZE - 1) return;
    
    // Pass 1: Terrain (Mat ID 1)
    generate_mesh_for_material(id, 1);
    
    // Pass 2: Water (Mat ID 2)
    generate_mesh_for_material(id, 2);
}