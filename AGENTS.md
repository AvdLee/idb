Workflow for updating RocketSim’s idb binary:
1) Apply changes in this fork.
2) Build updated XCFrameworks with `./spm_create_xcframeworks.sh`.
3) Commit and push the changes to a ref reachable by SPM (merge to `main` or create a tag).
4) Update RocketSim to the new idb revision (Vendor/SimulatorControl Package.swift + Package.resolved).
5) Build RocketSim: `xcodebuild -project RocketSim.xcodeproj -scheme RocketSim -destination 'platform=macOS' build 2>&1 | xcsift -f toon -w`

