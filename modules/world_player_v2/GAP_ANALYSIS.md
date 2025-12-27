# V1 vs V2 Deep Function Gap Analysis

## Summary of Missing Functions

The following V1 functions status after deep audit:

### From `mode_play.gd` (62 functions total)

| V1 Function | Lines | V2 Status | Priority |
|-------------|-------|-----------|----------|
| `_do_bucket_collect()` | 731-765 | ✅ FIXED | MEDIUM |
| `_do_vegetation_place(veg_type)` | 818-846 | ✅ FIXED | MEDIUM |
| `_try_pickup_item()` | 1149-1190 | ✅ In interaction | LOW |
| `_get_item_data_from_pickup(target)` | 1191-1223 | ⚠️ Simplified | LOW |
| `_create_material_target_marker()` | 1202-1223 | ⚠️ Not needed | LOW |
| `_update_target_material()` | 1224-1275 | ✅ FIXED | MEDIUM |
| `_get_material_from_mesh()` | 1279-1345 | ⚠️ Uses terrain_manager | LOW |
| `_barycentric()` | 1346-1368 | ⚠️ Not needed | LOW |
| `_closest_point_on_triangle()` | 1369-1419 | ⚠️ Not needed | LOW |
| `_get_material_at()` | 1414-1419 | ✅ Uses terrain_manager | LOW |
| `_collect_building_resource(block_id)` | 1479-1505 | ✅ FIXED | HIGH |

### From `player_interaction.gd` (14 functions)

| V1 Function | V2 Status |
|-------------|-----------|
| All 14 functions | ✅ Covered |

### From `hotbar.gd` (10 functions)

| V1 Function | V2 Status |
|-------------|-----------|
| All 10 functions | ✅ Covered |

### From `player_movement.gd` (8 functions)

| V1 Function | V2 Status |
|-------------|-----------|
| All 8 functions | ✅ Covered |

---

## Critical Gaps to Fix

### 1. `_collect_building_resource(block_id)` - HIGH PRIORITY
When breaking building blocks, V1 collects a resource item. V2's mining_feature doesn't have this.

### 2. `_update_target_material()` - MEDIUM PRIORITY
Shows material name in HUD when looking at terrain. V2 has the signal but doesn't emit it.

### 3. `_do_bucket_collect()` / `_do_vegetation_place()` - MEDIUM PRIORITY
Bucket water collection and vegetation placement not implemented.

---

## What V2 HAS but could be improved:

1. Mining feature has `_collect_terrain_resource()` but NOT `_collect_building_resource()`
2. No vegetation placement from resources
3. No bucket water collection
4. No target material display update

---

## Action Items

1. Add `_collect_building_resource()` to mining_feature.gd
2. Add `_update_target_material()` to modes_feature.gd  
3. Add bucket/vegetation placement to modes_feature.gd
4. Verify building block destruction collects resources
