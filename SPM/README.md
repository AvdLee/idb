# Updating for SPM
We use `xcframework`s for distributing via SPM as we would otherwise have to work with workspace files.
This is also the only way to make the Objective-C projects work with SPM. In theory, SPM supports obj-c, but it's really challenging with the IDB structure to support this.

Instead, we can use generated `xcframework` files and reference those as [binary targets](https://www.avanderlee.com/swift/binary-targets-swift-package-manager/).

1. Run `./spm_create_xcframeworks.sh` from the root directory in this repo
2. Commit the newly generated `xcframework` files
3. Reference this repo using `.package(url: "https://github.com/AvdLee/idb.git", branch: "main")`