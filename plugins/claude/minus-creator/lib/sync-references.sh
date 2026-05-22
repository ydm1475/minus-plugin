#!/bin/bash
# Update the References/ snapshot after sync is complete.

REPO_ROOT="$(cd "$(dirname "$0")/../../../.." && pwd)"
REFERENCES_DIR="$REPO_ROOT/References"
SNAPSHOT_FILE="$REPO_ROOT/.minus/references-snapshot"

if [ ! -d "$REFERENCES_DIR" ]; then
  echo "No References/ directory found."
  exit 1
fi

mkdir -p "$(dirname "$SNAPSHOT_FILE")"

find "$REFERENCES_DIR" -type f -not -name '.DS_Store' | sort | while IFS= read -r f; do
  rel="${f#$REPO_ROOT/}"
  hash=$(md5 -q "$f" 2>/dev/null)
  echo "$hash  $rel"
done > "$SNAPSHOT_FILE"

echo "References snapshot updated."
