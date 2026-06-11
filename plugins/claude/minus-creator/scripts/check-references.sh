#!/bin/bash
# Detect changes in References/ since last sync.
# Snapshot format: one line per file, "md5hash  relative/path"
# Snapshot is updated only by sync-references.sh, not here.

REPO_ROOT="$(cd "$(dirname "$0")/../../../.." && pwd)"
REFERENCES_DIR="$REPO_ROOT/References"
SNAPSHOT_FILE="$REPO_ROOT/.minus/references-snapshot"

if [ ! -d "$REFERENCES_DIR" ]; then
  exit 0
fi

file_hash() {
  md5 -q "$1" 2>/dev/null || md5sum "$1" 2>/dev/null | cut -d' ' -f1
}

# Build current state: "hash  relative_path" per file
current_state=$(find "$REFERENCES_DIR" -type f -not -name '.DS_Store' | sort | while IFS= read -r f; do
  rel="${f#$REPO_ROOT/}"
  hash=$(file_hash "$f")
  echo "$hash  $rel"
done)

# First run: save snapshot and exit silently
if [ ! -f "$SNAPSHOT_FILE" ]; then
  mkdir -p "$(dirname "$SNAPSHOT_FILE")"
  echo "$current_state" > "$SNAPSHOT_FILE"
  exit 0
fi

saved_state=$(cat "$SNAPSHOT_FILE")

if [ "$current_state" = "$saved_state" ]; then
  exit 0
fi

# Diff: find added/modified/deleted files
changed=""

while IFS= read -r line; do
  hash="${line%%  *}"
  path="${line#*  }"
  old_hash=$(grep "  $path\$" <<< "$saved_state" | head -1 | cut -d' ' -f1)
  if [ -z "$old_hash" ]; then
    changed="$changed\n  + $path (new)"
  elif [ "$hash" != "$old_hash" ]; then
    changed="$changed\n  * $path (modified)"
  fi
done <<< "$current_state"

while IFS= read -r line; do
  path="${line#*  }"
  if ! grep -q "  $path\$" <<< "$current_state"; then
    changed="$changed\n  - $path (deleted)"
  fi
done <<< "$saved_state"

if [ -n "$changed" ]; then
  echo ""
  echo "[References changed]"
  echo -e "$changed"
  echo ""
  echo "Done editing? Say \"sync\" and I'll check impact & update tests."
fi
