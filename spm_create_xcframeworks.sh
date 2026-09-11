#!/bin/bash

set -e
set -o pipefail

# Temporary-directory generation rewrites nested-worktree paths incorrectly.
# Generate projects in place for this packaging pipeline.
export XCODEGEN_STRIP_XATTRS=false

# Fail fast when the working tree is dirty: the artifacts and the
# recorded provenance must correspond to a committed source revision.
if [ -n "$(git status --porcelain)" ]; then
    echo "error: working tree is dirty; commit, stash, or clean all changes before building artifacts so ARTIFACT_PROVENANCE.json reflects the true source revision." >&2
    git status --porcelain >&2
    exit 1
fi

source_revision="$(git rev-parse HEAD)"
developer_directory="${DEVELOPER_DIR:-$(xcode-select -p)}"
xcode_version="$(DEVELOPER_DIR="$developer_directory" xcodebuild -version | awk 'NR == 1 { print $2 }')"
xcode_build="$(DEVELOPER_DIR="$developer_directory" xcodebuild -version | awk '/Build version/ { print $3 }')"

# Ensure Xcode projects are generated (xcodegen).
./build.sh generate

# FBSimulatorControl's framework target copies these generated runtime helpers into
# its Resources directory. Build them explicitly so an XCFramework build never
# relies on products left behind by an earlier companion build.
./build.sh build shims
./build.sh build SimulatorFrameworkBridge-iOS
./build.sh build SimulatorFrameworkBridge-tvOS

# Function to archive and create xcframework
build_xcframework() {
    local framework_name="$1"
    local project_name="FBSimulatorControl.xcodeproj"
    local archive_path="SPM/archives/${framework_name}"
    local framework_path="${archive_path}.xcarchive/Products/Library/Frameworks/${framework_name}.framework"
    local xcframework_path="SPM/xcframeworks/${framework_name}.xcframework"
    
    # Delete existing .xcframework file if it exists
    if [ -e "$xcframework_path" ]; then
        rm -rf "$xcframework_path"
        echo "Existing xcframework deleted."
    fi
    
    # Archive the project.
    # -module-interface-preserve-types-as-written: the FBSimulatorControl module contains a
    # class also named FBSimulatorControl, so the default module-qualified names in the emitted
    # swiftinterface ("FBSimulatorControl.FBSimulatorVideo") resolve to the class instead of the
    # module and the interface fails to compile in consumers.
    # MACH_O_TYPE=mh_dylib: the project builds static frameworks for the companion/OSS build,
    # but the distributed xcframeworks must be dynamic so the weak link against the private
    # CoreSimulator tbd stub is bound inside the dylib. A static archive would push those
    # undefined symbols onto consumers, which cannot resolve them.
    local mach_o_setting="MACH_O_TYPE=mh_dylib"
    if [ "$framework_name" = "FBSimulatorControl" ]; then
        # Do not turn FBSimulatorControl's static dependency targets into dylibs as well.
        # Their implicit framework links include SDK-private implementation details that
        # are not legal direct dependencies of a third-party dylib.
        mach_o_setting="FBSIMULATORCONTROL_MACH_O_TYPE=mh_dylib"
    fi
    xcodebuild archive -project "$project_name" -archivePath "$archive_path" SKIP_INSTALL=NO BUILD_LIBRARY_FOR_DISTRIBUTION=YES "$mach_o_setting" OTHER_SWIFT_FLAGS='$(inherited) -Xfrontend -module-interface-preserve-types-as-written' -scheme "$framework_name" -destination generic/platform=macOS
    
    # The FBSimulatorControl module contains a class also named FBSimulatorControl, so
    # module-qualified names in the emitted swiftinterface ("FBSimulatorControl.FBSimulatorVideo")
    # resolve to the class instead of the module and fail to compile in consumers.
    # -module-interface-preserve-types-as-written (above) fixes hand-written declarations;
    # compiler-synthesized ones (CaseIterable/Equatable conformances etc.) are still qualified,
    # so strip the module qualifier from the interfaces before packaging.
    if [ "$framework_name" = "FBSimulatorControl" ]; then
        find "${framework_path}/Modules/${framework_name}.swiftmodule" -name '*.swiftinterface' \
            -exec sed -i '' -e '/import CoreSimulator/d' -e 's/\([^A-Za-z0-9_.]\)FBSimulatorControl\./\1/g' -e 's/^FBSimulatorControl\.//' -e 's/FBSimulatorControl:://g' {} +

        # The standalone archive does not run the companion's distribution assembly.
        # Install the guests into the framework bundle so BundledResources can resolve
        # them when this XCFramework is embedded in another app.
        mkdir -p "${framework_path}/Versions/A/Resources"
        cp Build/Products/Release-iphonesimulator/SimulatorFrameworkBridge-iOS \
            "${framework_path}/Versions/A/Resources/"
        cp Build/Products/Release-appletvsimulator/SimulatorFrameworkBridge-tvOS \
            "${framework_path}/Versions/A/Resources/"

        # The archive was signed before the interfaces and resources were updated.
        codesign --force --sign - --timestamp=none "${framework_path}"
    fi

    # Create xcframework
    xcodebuild -create-xcframework -framework "$framework_path" -output "$xcframework_path"

    if [ "$framework_name" = "FBSimulatorControl" ]; then
        local resources_path="${xcframework_path}/macos-arm64_x86_64/${framework_name}.framework/Versions/A/Resources"
        for resource in SimulatorFrameworkBridge-iOS SimulatorFrameworkBridge-tvOS; do
            if [ ! -x "${resources_path}/${resource}" ]; then
                echo "error: ${resource} was not packaged as an executable FBSimulatorControl resource" >&2
                exit 1
            fi
        done
    fi
}

# XCTestBootstrap's generated target is a static framework whose archive cannot be
# converted to a dylib independently (its FBControlCore symbols are intentionally
# resolved by the companion). Keep its checked-in binary artifact unchanged.
build_xcframework "FBControlCore"
build_xcframework "FBSimulatorControl"

./verify_fbsimulatorcontrol_runtime_linkage.sh

jq -n \
  --arg source_revision "$source_revision" \
  --arg developer_directory "$developer_directory" \
  --arg xcode_version "$xcode_version" \
  --arg xcode_build "$xcode_build" \
  '{
    source_revision: $source_revision,
    toolchain: {
      developer_directory: $developer_directory,
      xcode_version: $xcode_version,
      xcode_build: $xcode_build
    }
  }' > SPM/ARTIFACT_PROVENANCE.json
