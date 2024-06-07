#!/bin/bash

# Define the source and destination directories
SOURCE_DIR=$(pwd)
DEST_DIR="$SOURCE_DIR/spm/FBControlCore"

# Create the destination directory if it doesn't exist
mkdir -p "$DEST_DIR"

## Find all files in the source directory and its subdirectories, then move them to the destination directory
#find "$SOURCE_DIR" -mindepth 2 -type f -exec cp {} "$DEST_DIR" \;
#
#find "$DEST_DIR" -type f -exec chmod u+rwx {} \;

# Find all files in the target directory and its subdirectories
find "$DEST_DIR" -type f -print0 | xargs -0 sed -i '' 's|FBControlCore/||g'

echo "All files have been moved to $DEST_DIR."
