extends RefCounted
class_name ChunkData

var node_terrain: Node3D
var node_water: Node3D
var density_buffer_terrain: RID
var density_buffer_water: RID
var material_buffer_terrain: RID # Material IDs per voxel (GPU)

# Optimization: Use PhysicsServer3D RIDs directly instead of Nodes for terrain collision
var body_rid_terrain: RID

var collision_shape_terrain: CollisionShape3D # For dynamic enable/disable
var terrain_shape: Shape3D # Store the shape for lazy creation
# CPU mirrors for physics detection
var cpu_density_water: PackedFloat32Array = PackedFloat32Array()
var cpu_density_terrain: PackedFloat32Array = PackedFloat32Array()
# CPU mirror for materials (for 3D texture creation)
var cpu_material_terrain: PackedByteArray = PackedByteArray()
# 3D texture for fragment shader sampling
var material_texture: ImageTexture3D = null
var chunk_material: ShaderMaterial = null # Per-chunk material instance
# Modification version - incremented on each modify, used to skip stale updates
var mod_version: int = 0
