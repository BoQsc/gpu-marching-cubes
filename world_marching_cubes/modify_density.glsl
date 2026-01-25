#[compute]
#version 450

// Dispatch over the whole chunk 33x33x33.
layout(local_size_x = 4, local_size_y = 4, local_size_z = 4) in;

layout(set = 0, binding = 0, std430) restrict buffer DensityBuffer {
    float values[];
} density_buffer;

layout(set = 0, binding = 1, std430) restrict buffer MaterialBuffer {
    uint values[];
} material_buffer;

layout(push_constant) uniform PushConstants {
    vec4 chunk_offset;   // .xyz = position, .w = y_min (for Column shape)
    vec4 brush_pos;      // .xyz = world pos, .w = radius (or y_max for Column)
    float brush_value;   // +1 to dig, -1 to place
    int shape_type;      // 0 = Sphere, 1 = Box, 2 = Column
    int material_id;     // -1 = no change, 0+ = specific material
    float y_max;         // For Column shape: max Y bound
    int brush_mode;      // 0=ADD, 1=SUBTRACT, 2=PAINT, 3=FLATTEN, 4=SMOOTH
} params;

void main() {
    uvec3 id = gl_GlobalInvocationID.xyz;
    if (id.x >= 33 || id.y >= 33 || id.z >= 33) return;

    uint index = id.x + (id.y * 33) + (id.z * 33 * 33);
    
    vec3 local_pos = vec3(id);
    vec3 world_pos = local_pos + vec3(params.chunk_offset.xyz);
    
    
    bool modified = false;
    
    // --- MODE 3: FLATTEN (Overrides normal digging behavior) ---
    if (params.brush_mode == 3) {
        // Flatten forces density to be distance from plane.
        // Target Y is passed in params.brush_pos.y (if we decide to override it there)
        // OR we use the brush position as the target plane.
        // Let's assume params.brush_pos.y IS the target plane height.
        
        // Check horizontal radius
        float dist_xz = distance(world_pos.xz, params.brush_pos.xz);
        
        if (dist_xz <= params.brush_pos.w) {
            float target_height = params.brush_pos.y;
            float current_y = world_pos.y;
            
            // Calculate signed distance to plane
            // Below plane: negative (Solid)
            // Above plane: positive (Air)
            // Standard MC convention: >0 Air, <0 Solid.
            float ideal_density = (current_y - target_height);
            
            // Soften the transition (Multiplier makes it sharper/harder)
            // A multiplier of 1.0 means density increases by 1.0 per meter.
            float new_density = ideal_density; 
            
            // Blend with existing density to avoid destroying everything outside radius?
            // No, Flatten is usually destructive.
            // But we only want to affect the cylinder we are clicking in.
            
            // Falloff for smooth edges? 
            // Box/Cylinder shape logic applies here too.
            // Let's use simple cylinder override for now.
            density_buffer.values[index] = clamp(new_density, -1.0, 1.0);
            modified = true;
        }
    } 
    // --- MODE 4: SMOOTH ---
    else if (params.brush_mode == 4) {
        // Smooth requires reading neighbors (kernels). 
        // This is complex in a compute shader without shared memory or multi-pass.
        // Simple approximation: blur with current value (weak effect) or just skip for now.
        // Placeholder: No-op
    }
    // --- STANDARD MODES (ADD/SUBTRACT) ---
    else {
        if (params.shape_type == 2) {
            // Column Shape (precise 1x1 vertical column, y_min to y_max)
            // XZ: 0.5 radius centered on brush_pos.xy
            // Y: between chunk_offset.w (y_min) and y_max
            float dist_x = abs(world_pos.x - params.brush_pos.x);
            float dist_z = abs(world_pos.z - params.brush_pos.z);
            float y_min = params.chunk_offset.w;
            float y_max_val = params.y_max;
            
            // Inside 1x1 column horizontally AND within Y bounds
            if (dist_x <= 0.5 && dist_z <= 0.5 && world_pos.y >= y_min && world_pos.y <= y_max_val) {
                density_buffer.values[index] = params.brush_value;
                modified = true;
            }
        } else if (params.shape_type == 1) {
            // Box Shape (Hard edges)
            vec3 dist_vec = abs(world_pos - params.brush_pos.xyz);
            float max_dist = max(dist_vec.x, max(dist_vec.y, dist_vec.z));
            
            if (max_dist <= params.brush_pos.w) {
                density_buffer.values[index] = params.brush_value;
                modified = true;
            }
        } else {
            // Sphere Shape (Smooth falloff)
            float dist = distance(world_pos, params.brush_pos.xyz);
            float radius = params.brush_pos.w;
            
            if (dist < radius) {
                float falloff = 1.0 - (dist / radius);
                float weight = clamp(falloff, 0.0, 1.0);
                float modification = params.brush_value * weight;
                density_buffer.values[index] += modification;
                modified = true;
            }
        }
    }
    
    // Write material when PLACING terrain (negative brush_value = adding solid)
    // Or when in FLATTEN mode and creating solid (new density < 0)
    bool is_placing = (params.brush_value < 0.0);
    if (params.brush_mode == 3 && density_buffer.values[index] < 0.0) is_placing = true;
    
    if (params.material_id >= 0 && is_placing) {
        vec3 dist_vec = abs(world_pos - params.brush_pos.xyz);
        float max_dist = max(dist_vec.x, max(dist_vec.y, dist_vec.z)); // Box approx for speed
        
        bool should_write = false;
        
        // Flatten mode needs slightly wider material application to cover the floor
        float check_radius = params.brush_pos.w;
        if (params.brush_mode == 3) check_radius += 0.5;
        
        if (max_dist <= check_radius) {
             material_buffer.values[index] = uint(params.material_id);
        }
    }
    
    // NOTE: When digging (brush_value > 0), we do NOT reset materials.
    // The underground materials (stone, ore) were already generated by gen_density.glsl
    // Digging simply reveals the existing material data.

    // CLAMP DENSITY: Prevent infinite values or extreme gradients
    // Keeps the density field within a stable "Hardware Surface" range
    if (modified) {
        density_buffer.values[index] = clamp(density_buffer.values[index], -10.0, 10.0);
    }
}
