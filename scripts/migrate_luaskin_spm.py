#!/usr/bin/env python3
"""Migrate LuaSkin from framework to SPM package in the Xcode project.

Line-based approach: processes pbxproj line by line for reliable insertion.
"""

import re
import hashlib

PBXPROJ = "Hammerspoon.xcodeproj/project.pbxproj"

LUASKIN_FRAMEWORK_FILEREF = "4FB852342735B02400462DD0"
LUASKIN_EMBED_BUILDFILE = "4FB852362735B02400462DD0"
LUASKIN_EMBED_PHASE = "4FB852372735B02400462DD0"


def gen_id(seed):
    return hashlib.md5(seed.encode()).hexdigest()[:24].upper()


LUASKIN_PKG_REF_ID = gen_id("XCLocalSwiftPackageReference_LuaSkin")


def main():
    with open(PBXPROJ, "r") as f:
        lines = f.readlines()

    # --- Pass 1: Collect IDs ---
    # Build file IDs for "LuaSkin.framework in Frameworks"
    fw_buildfile_ids = set()
    for line in lines:
        m = re.match(r'\s+(\w{24}) /\* LuaSkin\.framework in Frameworks \*/ = \{', line)
        if m:
            fw_buildfile_ids.add(m.group(1))
    print(f"Found {len(fw_buildfile_ids)} LuaSkin.framework build file IDs")

    # Find which PBXNativeTargets need LuaSkin (by checking the original Frameworks phases)
    # We'll parse: for each target, find its Frameworks build phase ID,
    # then check if that phase's files list contains any fw_buildfile_ids.

    # First, find framework phase IDs that contain LuaSkin refs
    phases_with_luaskin = set()
    in_phase = None
    for line in lines:
        m = re.match(r'\s+(\w{24}) /\* Frameworks \*/ = \{', line)
        if m:
            in_phase = m.group(1)
            continue
        if in_phase:
            for bid in fw_buildfile_ids:
                if bid in line:
                    phases_with_luaskin.add(in_phase)
                    break
            if re.match(r'\s+\};', line):
                in_phase = None

    print(f"Found {len(phases_with_luaskin)} framework phases with LuaSkin")

    # Now find which targets reference these phases
    targets_needing_luaskin = []  # (target_id, target_name)
    in_target = None
    target_id = None
    target_name = None
    target_has_phase = False

    for line in lines:
        m = re.match(r'\s+(\w{24}) /\* (.+?) \*/ = \{\s*$', line)
        if m and not in_target:
            candidate_id = m.group(1)
            candidate_name = m.group(2)
            # Check next few lines for "isa = PBXNativeTarget"
            continue

        if 'isa = PBXNativeTarget;' in line and not in_target:
            # We need to go back and get the ID - but line-based parsing makes this hard.
            # Let me use a different approach below.
            pass

    # Better approach: two-pass parse for targets
    i = 0
    while i < len(lines):
        m = re.match(r'\s+(\w{24}) /\* (.+?) \*/ = \{', lines[i])
        if m and i + 1 < len(lines) and 'isa = PBXNativeTarget;' in lines[i + 1]:
            target_id = m.group(1)
            target_name = m.group(2)
            # Scan this target's buildPhases for our framework phases
            j = i + 2
            while j < len(lines) and not re.match(r'\s+\};$', lines[j]):
                for phase_id in phases_with_luaskin:
                    if phase_id in lines[j]:
                        targets_needing_luaskin.append((target_id, target_name))
                        break
                j += 1
                if targets_needing_luaskin and targets_needing_luaskin[-1][0] == target_id:
                    break
            i = j
        else:
            i += 1

    print(f"Found {len(targets_needing_luaskin)} targets needing LuaSkin SPM dependency")

    # Generate dep IDs for each target
    target_dep_ids = {}
    for target_id, name in targets_needing_luaskin:
        target_dep_ids[target_id] = gen_id(f"LuaSkin_pkg_dep_{target_id}")

    # --- Pass 2: Transform ---
    output = []
    i = 0
    while i < len(lines):
        line = lines[i]

        # Skip PBXBuildFile entries for LuaSkin.framework
        if 'LuaSkin.framework in Frameworks' in line and any(bid in line for bid in fw_buildfile_ids):
            i += 1
            continue

        # Skip the Embed Frameworks build file entry
        if LUASKIN_EMBED_BUILDFILE in line and 'LuaSkin.framework in Embed Frameworks' in line:
            i += 1
            continue

        # Skip the LuaSkin.framework PBXFileReference
        if LUASKIN_FRAMEWORK_FILEREF in line and 'PBXFileReference' in line and 'LuaSkin.framework' in line:
            i += 1
            continue

        # Remove LuaSkin.framework from group children lists
        if LUASKIN_FRAMEWORK_FILEREF in line and 'LuaSkin.framework' in line and line.strip().startswith(LUASKIN_FRAMEWORK_FILEREF):
            i += 1
            continue

        # Skip LuaSkin refs inside Frameworks build phases' files lists
        if any(bid in line for bid in fw_buildfile_ids) and 'LuaSkin.framework in Frameworks' in line:
            i += 1
            continue

        # Skip LuaSkin ref inside Embed Frameworks build phase
        if LUASKIN_EMBED_BUILDFILE in line and 'LuaSkin.framework in Embed Frameworks' in line:
            i += 1
            continue

        # Handle Embed Frameworks build phase - remove if now empty
        if LUASKIN_EMBED_PHASE in line and 'Embed Frameworks' in line and 'isa = PBXCopyFilesBuildPhase' not in line:
            # Check if this is the reference in buildPhases array (just the ID line)
            stripped = line.strip()
            if stripped.startswith(LUASKIN_EMBED_PHASE) and stripped.endswith(','):
                # Check if the actual phase will be empty - look ahead in the original
                # For now, keep the phase reference; we'll remove the phase body separately
                pass

        # For PBXNativeTarget sections: insert packageProductDependencies
        m = re.match(r'(\s+)(\w{24}) /\* (.+?) \*/ = \{', line)
        if m and i + 1 < len(lines) and 'isa = PBXNativeTarget;' in lines[i + 1]:
            target_id = m.group(2)
            indent = m.group(1)
            if target_id in target_dep_ids:
                dep_id = target_dep_ids[target_id]
                # Output the target header and scan for productType to insert before it
                # Also check if target already has packageProductDependencies
                output.append(line)
                i += 1
                has_pkg_deps = False
                inserted = False

                target_indent = len(line) - len(line.lstrip())
                while i < len(lines):
                    curr = lines[i]

                    # Check if we reached end of target (same indentation as opening)
                    curr_indent = len(curr) - len(curr.lstrip())
                    if curr.strip() == '};' and curr_indent == target_indent:
                        if not inserted and not has_pkg_deps:
                            prop = '\t' * (target_indent + 1)
                            item = '\t' * (target_indent + 2)
                            output.append(f"{prop}packageProductDependencies = (\n")
                            output.append(f"{item}{dep_id} /* LuaSkin */,\n")
                            output.append(f"{prop});\n")
                            inserted = True
                        output.append(curr)
                        i += 1
                        break

                    if 'packageProductDependencies = (' in curr:
                        has_pkg_deps = True
                        output.append(curr)
                        i += 1
                        item = '\t' * (target_indent + 2)
                        output.append(f"{item}{dep_id} /* LuaSkin */,\n")
                        continue

                    if 'productType = ' in curr and not inserted and not has_pkg_deps:
                        prop = '\t' * (target_indent + 1)
                        item = '\t' * (target_indent + 2)
                        output.append(f"{prop}packageProductDependencies = (\n")
                        output.append(f"{item}{dep_id} /* LuaSkin */,\n")
                        output.append(f"{prop});\n")
                        inserted = True

                    output.append(curr)
                    i += 1
                continue

        # Add LuaSkin to packageReferences
        if '4F1D462818414FC78DA1D6A5 /* XCLocalSwiftPackageReference "CocoaHTTPServer" */,' in line:
            output.append(line)
            indent = line[:len(line) - len(line.lstrip())]
            output.append(f"{indent}{LUASKIN_PKG_REF_ID} /* XCLocalSwiftPackageReference \"LuaSkin\" */,\n")
            i += 1
            continue

        # Add XCLocalSwiftPackageReference entry for LuaSkin
        if '/* End XCLocalSwiftPackageReference section */' in line:
            output.append(f"\t\t{LUASKIN_PKG_REF_ID} /* XCLocalSwiftPackageReference \"LuaSkin\" */ = {{\n")
            output.append(f"\t\t\tisa = XCLocalSwiftPackageReference;\n")
            output.append(f"\t\t\trelativePath = Packages/LuaSkin;\n")
            output.append(f"\t\t}};\n")
            output.append(line)
            i += 1
            continue

        # Add XCSwiftPackageProductDependency entries for all targets
        if '/* End XCSwiftPackageProductDependency section */' in line:
            for target_id, name in targets_needing_luaskin:
                dep_id = target_dep_ids[target_id]
                output.append(f"\t\t{dep_id} /* LuaSkin */ = {{\n")
                output.append(f"\t\t\tisa = XCSwiftPackageProductDependency;\n")
                output.append(f"\t\t\tproductName = LuaSkin;\n")
                output.append(f"\t\t}};\n")
            output.append(line)
            i += 1
            continue

        output.append(line)
        i += 1

    with open(PBXPROJ, "w") as f:
        f.writelines(output)

    print("Migration complete!")
    print(f"  Removed {len(fw_buildfile_ids)} framework build file entries")
    print(f"  Added {len(targets_needing_luaskin)} package product dependencies")


if __name__ == "__main__":
    main()
