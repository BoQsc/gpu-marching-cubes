#[compute]
#version 450

// We dispatch 1 thread per voxel.
layout(local_size_x = 8, local_size_y = 8, local_size_z = 8) in;

// BINDINGS
layout(set = 0, binding = 0, std430) restrict buffer OutputVertices {
    float vertices[]; 
} mesh_output;

layout(set = 0, binding = 1, std430) restrict buffer CounterBuffer {
    uint triangle_count;
} counter;

// New Binding: Input Density Map
layout(set = 0, binding = 2, std430) restrict buffer DensityBuffer {
    float values[];
} density_buffer;

// New Binding: Input Material Map
layout(set = 0, binding = 3, std430) restrict buffer MaterialBuffer {
    uint values[];
} material_buffer;

layout(push_constant) uniform PushConstants {
    vec4 chunk_offset; // .xyz is position
    float noise_freq;
    float terrain_height;
} params;

const int CHUNK_SIZE = 32;
const float ISO_LEVEL = 0.0;

#include "res://world_marching_cubes/marching_cubes_lookup_table.glslinc"

float get_density_from_buffer(vec3 p) {
    // p is local coordinates (0..32)
    // The buffer is 33x33x33
    int x = int(round(p.x));
    int y = int(round(p.y));
    int z = int(round(p.z));
    
    // Clamp to safe bounds
    x = clamp(x, 0, 32);
    y = clamp(y, 0, 32);
    z = clamp(z, 0, 32);
    
    uint index = x + (y * 33) + (z * 33 * 33);
    return density_buffer.values[index];
}

uint get_material_from_buffer(vec3 p) {
    int x = int(round(p.x));
    int y = int(round(p.y));
    int z = int(round(p.z));
    x = clamp(x, 0, 32);
    y = clamp(y, 0, 32);
    z = clamp(z, 0, 32);
    uint index = x + (y * 33) + (z * 33 * 33);
    return material_buffer.values[index];
}

// Convert material ID to RGB color for vertex color
// R channel encodes material ID (0-255), G=1 marks valid material
// Material IDs: 0=Grass, 1=Stone, 2=Ore, 3=Sand, 4=Gravel, 5=Snow, 6=Road, 100+=Player
vec3 material_to_color(uint mat_id) {
    // Encode material ID in R channel (normalized to 0-1)
    // Fragment shader decodes: int id = int(round(color.r * 255.0))
    float encoded_id = float(mat_id) / 255.0;
    return vec3(encoded_id, 1.0, 0.0);  // G=1 marks valid, B unused
}

vec3 get_normal(vec3 pos) {
    // Calculate gradient from the buffer
    // We can't sample arbitrarily small delta 'd' because we are on a grid.
    // We must sample neighbors.
    
    vec3 n;
    float d = 1.0;
    
    float v_xp = get_density_from_buffer(pos + vec3(d, 0, 0));
    float v_xm = get_density_from_buffer(pos - vec3(d, 0, 0));
    float v_yp = get_density_from_buffer(pos + vec3(0, d, 0));
    float v_ym = get_density_from_buffer(pos - vec3(0, d, 0));
    float v_zp = get_density_from_buffer(pos + vec3(0, 0, d));
    float v_zm = get_density_from_buffer(pos - vec3(0, 0, d));
    
    n.x = v_xp - v_xm;
    n.y = v_yp - v_ym;
    n.z = v_zp - v_zm;
    
    return normalize(n);
}

vec3 interpolate_vertex(vec3 p1, vec3 p2, float v1, float v2) {
    if (abs(ISO_LEVEL - v1) < 0.00001) return p1;
    if (abs(ISO_LEVEL - v2) < 0.00001) return p2;
    if (abs(v1 - v2) < 0.00001) return p1;
    return p1 + (ISO_LEVEL - v1) * (p2 - p1) / (v2 - v1);
}

void main() {
    uvec3 id = gl_GlobalInvocationID.xyz;
    
    if (id.x >= uint(CHUNK_SIZE) - 1u || id.y >= uint(CHUNK_SIZE) - 1u || id.z >= uint(CHUNK_SIZE) - 1u) {
        return;
    }

    vec3 pos = vec3(id);

    // Sample 8 corners from the buffer
    vec3 corners[8] = vec3[](
        pos + vec3(0,0,0), pos + vec3(1,0,0), pos + vec3(1,0,1), pos + vec3(0,0,1),
        pos + vec3(0,1,0), pos + vec3(1,1,0), pos + vec3(1,1,1), pos + vec3(0,1,1)
    );

    float densities[8];
    for(int i = 0; i < 8; i++) {
        densities[i] = get_density_from_buffer(corners[i]);
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
    uint matList[12];

    // Helper macro to interpolate vertex and pick material from solid end
    #define PROCESS_EDGE(edge_idx, c1, c2) \
        if ((edgeTable[cubeIndex] & (1 << edge_idx)) != 0) { \
            vertList[edge_idx] = interpolate_vertex(corners[c1], corners[c2], densities[c1], densities[c2]); \
            uint m1 = get_material_from_buffer(corners[c1]); \
            uint m2 = get_material_from_buffer(corners[c2]); \
            matList[edge_idx] = (densities[c1] < densities[c2]) ? m1 : m2; \
        }

    PROCESS_EDGE(0, 0, 1);
    PROCESS_EDGE(1, 1, 2);
    PROCESS_EDGE(2, 2, 3);
    PROCESS_EDGE(3, 3, 0);
    PROCESS_EDGE(4, 4, 5);
    PROCESS_EDGE(5, 5, 6);
    PROCESS_EDGE(6, 6, 7);
    PROCESS_EDGE(7, 7, 4);
    PROCESS_EDGE(8, 0, 4);
    PROCESS_EDGE(9, 1, 5);
    PROCESS_EDGE(10, 2, 6);
    PROCESS_EDGE(11, 3, 7);

    for (int i = 0; triTable[cubeIndex * 16 + i] != -1; i += 3) {
        
        uint idx = atomicAdd(counter.triangle_count, 1);
        uint start_ptr = idx * 27;  // 9 floats per vertex (pos + normal + color) 

        int edge1 = triTable[cubeIndex * 16 + i];
        int edge2 = triTable[cubeIndex * 16 + i + 1];
        int edge3 = triTable[cubeIndex * 16 + i + 2];

        vec3 v1 = vertList[edge1];
        vec3 v2 = vertList[edge2];
        vec3 v3 = vertList[edge3];

        // Use precise materials derived from solid voxels
        vec3 mat_color1 = material_to_color(matList[edge1]);
        vec3 mat_color2 = material_to_color(matList[edge2]);
        vec3 mat_color3 = material_to_color(matList[edge3]);
        
        // Vertex 1
        vec3 n1 = get_normal(v1);
        
        mesh_output.vertices[start_ptr + 0] = v1.x;
        mesh_output.vertices[start_ptr + 1] = v1.y;
        mesh_output.vertices[start_ptr + 2] = v1.z;
        mesh_output.vertices[start_ptr + 3] = n1.x;
        mesh_output.vertices[start_ptr + 4] = n1.y;
        mesh_output.vertices[start_ptr + 5] = n1.z;
        mesh_output.vertices[start_ptr + 6] = mat_color1.r;
        mesh_output.vertices[start_ptr + 7] = mat_color1.g;
        mesh_output.vertices[start_ptr + 8] = mat_color1.b;
        
        // Vertex 3 (note: order is 1,3,2 for winding)
        vec3 n3 = get_normal(v3);
        
        mesh_output.vertices[start_ptr + 9] = v3.x;
        mesh_output.vertices[start_ptr + 10] = v3.y;
        mesh_output.vertices[start_ptr + 11] = v3.z;
        mesh_output.vertices[start_ptr + 12] = n3.x;
        mesh_output.vertices[start_ptr + 13] = n3.y;
        mesh_output.vertices[start_ptr + 14] = n3.z;
        mesh_output.vertices[start_ptr + 15] = mat_color3.r;
        mesh_output.vertices[start_ptr + 16] = mat_color3.g;
        mesh_output.vertices[start_ptr + 17] = mat_color3.b;
        
        // Vertex 2
        vec3 n2 = get_normal(v2);
        
        mesh_output.vertices[start_ptr + 18] = v2.x;
        mesh_output.vertices[start_ptr + 19] = v2.y;
        mesh_output.vertices[start_ptr + 20] = v2.z;
        mesh_output.vertices[start_ptr + 21] = n2.x;
        mesh_output.vertices[start_ptr + 22] = n2.y;
        mesh_output.vertices[start_ptr + 23] = n2.z;
        mesh_output.vertices[start_ptr + 24] = mat_color2.r;
        mesh_output.vertices[start_ptr + 25] = mat_color2.g;
        mesh_output.vertices[start_ptr + 26] = mat_color2.b;
    }
}