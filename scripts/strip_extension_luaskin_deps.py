#!/usr/bin/env python3
"""Remove LuaSkin packageProductDependencies from extension targets.
Keep only on: Hammerspoon app, hs CLI, test targets."""

import re

PBXPROJ = "Hammerspoon.xcodeproj/project.pbxproj"

KEEP_TARGETS = {
    "9445CA0A19083251002568BB",  # Hammerspoon (app)
    "4FD0AC081B74BACD00A82496",  # hs (CLI)
    "D02F95231A00221C00E28BB2",  # Hammerspoon Tests
    "4F20B5281C1F1C5B00F52437",  # Hammerspoon UI Tests
}

def main():
    with open(PBXPROJ, "r") as f:
        lines = f.readlines()

    output = []
    i = 0
    removed_dep_ids = set()
    removed_count = 0

    while i < len(lines):
        line = lines[i]

        # Detect PBXNativeTarget sections
        m = re.match(r'(\s+)(\w{24}) /\* (.+?) \*/ = \{', line)
        if m and i + 1 < len(lines) and 'isa = PBXNativeTarget;' in lines[i + 1]:
            target_id = m.group(2)

            if target_id not in KEEP_TARGETS:
                # This is an extension target - remove its LuaSkin packageProductDependencies
                output.append(line)
                i += 1

                while i < len(lines):
                    curr = lines[i]

                    if 'packageProductDependencies = (' in curr:
                        # Check if this block ONLY has LuaSkin
                        # Read the whole block
                        block_lines = [curr]
                        j = i + 1
                        while j < len(lines) and ');\n' not in lines[j - 1]:
                            block_lines.append(lines[j])
                            if lines[j].strip() == ');':
                                break
                            j += 1

                        # Check entries
                        luaskin_entries = []
                        other_entries = []
                        for bl in block_lines:
                            if '/* LuaSkin */' in bl:
                                # Extract the dep ID
                                dm = re.search(r'(\w{24}) /\* LuaSkin \*/', bl)
                                if dm:
                                    removed_dep_ids.add(dm.group(1))
                                luaskin_entries.append(bl)
                            elif 'packageProductDependencies' not in bl and ');' not in bl:
                                other_entries.append(bl)

                        if other_entries:
                            # Keep the block but remove LuaSkin entries
                            output.append(block_lines[0])  # packageProductDependencies = (
                            for oe in other_entries:
                                output.append(oe)
                            output.append(block_lines[-1])  # );
                        else:
                            # Remove the entire packageProductDependencies block
                            pass  # Don't output anything

                        removed_count += 1
                        i = j + 1
                        continue

                    # Check for target end
                    target_indent = len(m.group(1))
                    curr_indent = len(curr) - len(curr.lstrip())
                    if curr.strip() == '};' and curr_indent == target_indent:
                        output.append(curr)
                        i += 1
                        break

                    output.append(curr)
                    i += 1
                continue

        output.append(line)
        i += 1

    # Also remove the XCSwiftPackageProductDependency entries for removed deps
    final = []
    skip_until_close = False
    for line in output:
        if skip_until_close:
            if line.strip() == '};':
                skip_until_close = False
            continue

        skip = False
        for dep_id in removed_dep_ids:
            if dep_id in line and 'XCSwiftPackageProductDependency' in line:
                skip_until_close = True
                skip = True
                break
            if dep_id in line and '/* LuaSkin */' in line:
                skip_until_close = True
                skip = True
                break

        if not skip:
            final.append(line)

    with open(PBXPROJ, "w") as f:
        f.writelines(final)

    print(f"Removed LuaSkin deps from {removed_count} extension targets")
    print(f"Removed {len(removed_dep_ids)} XCSwiftPackageProductDependency entries")


if __name__ == "__main__":
    main()
