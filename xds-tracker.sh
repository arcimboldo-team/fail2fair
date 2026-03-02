#!/usr/bin/env bash
# This script searches in a drive for XDS files, looks for relevant information
# (like errors) and prints the folders/files where they have been found.

SEARCH_PATH="$1"
SEARCH_TERM="ERROR"

IDXREF_PATTERN="IDXREF.LP"
IDXREF_ERROR="!!! ERROR !!!"

echo "Looking for XDS files within path: $SEARCH_PATH"

find "$SEARCH_PATH" -type f -iname "*.lp" -exec dirname {} \; 2>/dev/null | sort -u | while read -r folder; do
    echo "--------------------------------------------------------"
    echo "XDS run found in $folder"

    #IDXREF error
    target_file="$folder/$IDXREF_PATTERN"
    if grep -q "$IDXREF_ERROR" "$target_file" 2>/dev/null; then
        echo "[!] IDXREF ERROR: "$target_file""
    fi
done