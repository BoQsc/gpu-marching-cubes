#!/usr/bin/env python3
"""
V1 vs V2 Verification Script
Compares world_player (V1) and world_player_v2 (V2) implementations
to verify feature parity.
"""

import os
import re
import sys
from pathlib import Path
from dataclasses import dataclass
from typing import Dict, List, Set, Tuple

# Paths
V1_PATH = Path("modules/world_player")
V2_PATH = Path("modules/world_player_v2")

@dataclass
class FunctionInfo:
    name: str
    file: str
    line: int
    signature: str

@dataclass
class SignalInfo:
    name: str
    file: str
    line: int
    params: str

@dataclass
class ConstantInfo:
    name: str
    file: str
    line: int
    value: str

def extract_functions(file_path: Path) -> List[FunctionInfo]:
    """Extract all function definitions from a GDScript file."""
    functions = []
    try:
        with open(file_path, 'r', encoding='utf-8') as f:
            lines = f.readlines()
        
        for i, line in enumerate(lines, 1):
            # Match: func function_name(...) -> ...:
            match = re.match(r'^func\s+(\w+)\s*\((.*?)\)', line)
            if match:
                name = match.group(1)
                params = match.group(2)
                functions.append(FunctionInfo(
                    name=name,
                    file=str(file_path),
                    line=i,
                    signature=f"func {name}({params})"
                ))
    except Exception as e:
        print(f"Error reading {file_path}: {e}")
    
    return functions

def extract_signals(file_path: Path) -> List[SignalInfo]:
    """Extract all signal definitions from a GDScript file."""
    signals = []
    try:
        with open(file_path, 'r', encoding='utf-8') as f:
            lines = f.readlines()
        
        for i, line in enumerate(lines, 1):
            # Match: signal signal_name(...) or signal signal_name
            match = re.match(r'^signal\s+(\w+)\s*\(?([^)]*)\)?', line)
            if match:
                name = match.group(1)
                params = match.group(2) or ""
                signals.append(SignalInfo(
                    name=name,
                    file=str(file_path),
                    line=i,
                    params=params
                ))
    except Exception as e:
        print(f"Error reading {file_path}: {e}")
    
    return signals

def extract_constants(file_path: Path) -> List[ConstantInfo]:
    """Extract all constant definitions from a GDScript file."""
    constants = []
    try:
        with open(file_path, 'r', encoding='utf-8') as f:
            lines = f.readlines()
        
        for i, line in enumerate(lines, 1):
            # Match: const NAME = value or const NAME: type = value
            match = re.match(r'^const\s+(\w+)\s*(?::\s*\w+)?\s*=\s*(.+)', line)
            if match:
                name = match.group(1)
                value = match.group(2).strip()
                constants.append(ConstantInfo(
                    name=name,
                    file=str(file_path),
                    line=i,
                    value=value
                ))
    except Exception as e:
        print(f"Error reading {file_path}: {e}")
    
    return constants

def get_gd_files(path: Path) -> List[Path]:
    """Get all .gd files in a directory recursively."""
    if not path.exists():
        print(f"Path does not exist: {path}")
        return []
    return list(path.rglob("*.gd"))

def analyze_version(path: Path) -> Tuple[Dict[str, FunctionInfo], Dict[str, SignalInfo], Dict[str, ConstantInfo]]:
    """Analyze all files in a version directory."""
    all_functions = {}
    all_signals = {}
    all_constants = {}
    
    for file_path in get_gd_files(path):
        # Skip README and doc files
        if file_path.suffix != '.gd':
            continue
        
        # Extract functions
        for func in extract_functions(file_path):
            key = func.name
            # Prefer non-private functions, but track all
            if key not in all_functions or not key.startswith('_'):
                all_functions[key] = func
        
        # Extract signals
        for sig in extract_signals(file_path):
            all_signals[sig.name] = sig
        
        # Extract constants
        for const in extract_constants(file_path):
            all_constants[const.name] = const
    
    return all_functions, all_signals, all_constants

def compare_functions(v1_funcs: Dict[str, FunctionInfo], v2_funcs: Dict[str, FunctionInfo]) -> Tuple[Set[str], Set[str], Set[str]]:
    """Compare functions between V1 and V2."""
    v1_names = set(v1_funcs.keys())
    v2_names = set(v2_funcs.keys())
    
    only_v1 = v1_names - v2_names
    only_v2 = v2_names - v1_names
    common = v1_names & v2_names
    
    return only_v1, only_v2, common

def compare_signals(v1_sigs: Dict[str, SignalInfo], v2_sigs: Dict[str, SignalInfo]) -> Tuple[Set[str], Set[str], Set[str]]:
    """Compare signals between V1 and V2."""
    v1_names = set(v1_sigs.keys())
    v2_names = set(v2_sigs.keys())
    
    only_v1 = v1_names - v2_names
    only_v2 = v2_names - v1_names
    common = v1_names & v2_names
    
    return only_v1, only_v2, common

def compare_constants(v1_consts: Dict[str, ConstantInfo], v2_consts: Dict[str, ConstantInfo]) -> Tuple[Set[str], Set[str], Dict[str, Tuple[str, str]]]:
    """Compare constants between V1 and V2."""
    v1_names = set(v1_consts.keys())
    v2_names = set(v2_consts.keys())
    
    only_v1 = v1_names - v2_names
    only_v2 = v2_names - v1_names
    
    # Check for value mismatches
    common = v1_names & v2_names
    mismatches = {}
    for name in common:
        v1_val = v1_consts[name].value
        v2_val = v2_consts[name].value
        # Normalize values for comparison
        v1_clean = v1_val.replace(" ", "")
        v2_clean = v2_val.replace(" ", "")
        if v1_clean != v2_clean:
            mismatches[name] = (v1_val, v2_val)
    
    return only_v1, only_v2, mismatches

def print_section(title: str, char: str = "="):
    """Print a section header."""
    print(f"\n{char * 60}")
    print(f" {title}")
    print(f"{char * 60}")

def main():
    print("=" * 60)
    print(" V1 vs V2 Verification Report")
    print(" Generated: " + __import__('datetime').datetime.now().strftime("%Y-%m-%d %H:%M:%S"))
    print("=" * 60)
    
    # Check paths exist
    if not V1_PATH.exists():
        print(f"ERROR: V1 path not found: {V1_PATH}")
        return 1
    if not V2_PATH.exists():
        print(f"ERROR: V2 path not found: {V2_PATH}")
        return 1
    
    # Analyze both versions
    print("\nAnalyzing V1...")
    v1_funcs, v1_sigs, v1_consts = analyze_version(V1_PATH)
    print(f"  Found {len(v1_funcs)} functions, {len(v1_sigs)} signals, {len(v1_consts)} constants")
    
    print("\nAnalyzing V2...")
    v2_funcs, v2_sigs, v2_consts = analyze_version(V2_PATH)
    print(f"  Found {len(v2_funcs)} functions, {len(v2_sigs)} signals, {len(v2_consts)} constants")
    
    # Compare Functions
    print_section("FUNCTION COMPARISON")
    only_v1, only_v2, common = compare_functions(v1_funcs, v2_funcs)
    
    print(f"\nFunctions in BOTH: {len(common)}")
    print(f"Functions ONLY in V1: {len(only_v1)}")
    print(f"Functions ONLY in V2: {len(only_v2)}")
    
    if only_v1:
        print("\n[!] Functions in V1 but NOT in V2 (potential gaps):")
        # Filter out truly private/internal functions
        important_missing = [f for f in sorted(only_v1) if not f.startswith('__')]
        for name in important_missing[:30]:  # Limit output
            info = v1_funcs[name]
            rel_path = Path(info.file).relative_to(V1_PATH) if V1_PATH in Path(info.file).parents or Path(info.file).parent == V1_PATH.parent else info.file
            print(f"    - {name}() in {rel_path}:{info.line}")
        if len(important_missing) > 30:
            print(f"    ... and {len(important_missing) - 30} more")
    
    # Compare Signals
    print_section("SIGNAL COMPARISON")
    only_v1_sig, only_v2_sig, common_sig = compare_signals(v1_sigs, v2_sigs)
    
    print(f"\nSignals in BOTH: {len(common_sig)}")
    print(f"Signals ONLY in V1: {len(only_v1_sig)}")
    print(f"Signals ONLY in V2: {len(only_v2_sig)}")
    
    if only_v1_sig:
        print("\n[!] Signals in V1 but NOT in V2 (CRITICAL):")
        for name in sorted(only_v1_sig):
            info = v1_sigs[name]
            print(f"    - {name}({info.params})")
    
    if only_v2_sig:
        print("\n[+] New signals in V2:")
        for name in sorted(only_v2_sig):
            info = v2_sigs[name]
            print(f"    + {name}({info.params})")
    
    # Compare Constants
    print_section("CONSTANT COMPARISON")
    only_v1_const, only_v2_const, mismatches = compare_constants(v1_consts, v2_consts)
    
    print(f"\nConstants in BOTH: {len(set(v1_consts.keys()) & set(v2_consts.keys()))}")
    print(f"Constants ONLY in V1: {len(only_v1_const)}")
    print(f"Constants ONLY in V2: {len(only_v2_const)}")
    
    if only_v1_const:
        print("\n[!] Constants in V1 but NOT in V2:")
        for name in sorted(only_v1_const)[:20]:
            info = v1_consts[name]
            print(f"    - {name} = {info.value}")
        if len(only_v1_const) > 20:
            print(f"    ... and {len(only_v1_const) - 20} more")
    
    if mismatches:
        print("\n[!] Constants with DIFFERENT VALUES:")
        for name, (v1_val, v2_val) in sorted(mismatches.items()):
            print(f"    {name}:")
            print(f"      V1: {v1_val}")
            print(f"      V2: {v2_val}")
    
    # Summary
    print_section("SUMMARY")
    
    issues = 0
    if only_v1_sig:
        issues += len(only_v1_sig)
        print(f"[CRITICAL] {len(only_v1_sig)} signals missing from V2")
    if mismatches:
        issues += len(mismatches)
        print(f"[WARNING] {len(mismatches)} constants have different values")
    
    important_funcs = [f for f in only_v1 if not f.startswith('_') or f in [
        '_do_punch', '_do_pistol_fire', '_do_tool_attack', '_damage_terrain',
        '_damage_tree', '_try_grab_prop', '_drop_grabbed_prop', '_try_pickup_item',
        '_update_target_material', '_get_material_from_mesh', '_collect_terrain_resource',
        '_collect_building_resource', '_consume_selected_item', '_do_bucket_collect',
        '_do_bucket_place', '_do_resource_place', '_do_vegetation_place'
    ]]
    
    if important_funcs:
        print(f"[INFO] {len(important_funcs)} public/important functions only in V1")
    
    if issues == 0:
        print("\n[SUCCESS] No critical issues found!")
    else:
        print(f"\n[ATTENTION] {issues} issues require attention")
    
    # File count comparison
    print_section("FILE COUNT")
    v1_files = get_gd_files(V1_PATH)
    v2_files = get_gd_files(V2_PATH)
    print(f"V1 .gd files: {len(v1_files)}")
    print(f"V2 .gd files: {len(v2_files)}")
    
    # Line count
    v1_lines = sum(len(open(f, 'r', encoding='utf-8').readlines()) for f in v1_files)
    v2_lines = sum(len(open(f, 'r', encoding='utf-8').readlines()) for f in v2_files)
    print(f"V1 total lines: {v1_lines}")
    print(f"V2 total lines: {v2_lines}")
    
    return 0 if issues == 0 else 1

if __name__ == "__main__":
    os.chdir(Path(__file__).parent.parent.parent)  # Go to project root
    sys.exit(main())
