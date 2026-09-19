#!/usr/bin/env bash
# scripts/reconstitute.sh
#
# Reconstitutes the typed-language-model-arena workspace by cloning and pinning
# Nadeem Bitar's typed language model ecosystem repositories (shikumi, baikai,
# keiro, kioku, etc.) alongside this repository in the parent directory.
#
# Usage:
#   ./scripts/reconstitute.sh [--build]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARENA_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PARENT_DIR="$(cd "$ARENA_DIR/.." && pwd)"

echo "=== Reconstituting typed-language-model-arena workspace ==="
echo "Arena directory:  $ARENA_DIR"
echo "Target directory: $PARENT_DIR"
echo ""

# Declarative manifest of sibling repositories, URLs, and tested commit hashes.
declare -A REPOS=(
  ["shikumi"]="https://github.com/shinzui/shikumi.git ca207c9384816d996bf207c066baae2bfd134e3b"
  ["baikai"]="https://github.com/shinzui/baikai.git 4a9547b00de18b095259e3720e1ede82670787c9"
  ["keiki"]="https://github.com/shinzui/keiki.git 97d8b07e87ceb2d9b6e6b2b8a60a7de84e15e2bb"
  ["kiroku"]="https://github.com/shinzui/kiroku.git 09b7005382750e851f841079ba72b4d666006537"
  ["shibuya"]="https://github.com/shinzui/shibuya.git daa1e0c8726bd407288bbeb065146e01a63a4046"
  ["keiro"]="https://github.com/shinzui/keiro.git 0ab397f710a4ef73ead14d17a519545209d92ca3"
  ["kioku"]="https://github.com/shinzui/kioku.git 1fb4fa39747f03ff5be6c5f07ae3a1d385cdfbee"
  ["pgmq-hs"]="https://github.com/shinzui/pgmq-hs.git 8a704c336dea742a426eb737848367681dc9ebf7"
  ["shibuya-pgmq-adapter"]="https://github.com/shinzui/shibuya-pgmq-adapter.git fee9b3a8670e41baaa41388cfe9235aa03a5caf2"
)

# Portfolio runtime verification and domain dependencies
declare -A OPTIONAL_REPOS=(
  ["pgcl"]="https://github.com/NadiaYvette/pgcl-testscripts.git 542bf6e176ae69e32bd0f318cd3484324e7571cf"
  ["telix"]="https://github.com/NadiaYvette/telix.git b0879d7fc2c9ff0aba6693c36db8b23a1aaf0b9c"
  ["tessera"]="https://github.com/NadiaYvette/tessera.git 97c6312d3dcabb2f04a24ee205f60d441b01e109"
  ["organ-bank"]="https://github.com/NadiaYvette/organ-bank.git 759ecf0ab3dbfb0b345f79b8fa0fd14deee7648a"
  ["frankenstein"]="https://github.com/NadiaYvette/frankenstein.git 82ac89364c9127bf15f0a8e257cb72b693b8e83a"
  ["mowgli"]="https://github.com/NadiaYvette/mowgli.git 04a5ccf59e933997cb90e0b0e0e0aced08022e3b"
  ["peirce"]="https://github.com/NadiaYvette/peirce.git d9d1b78245461352e919e4682c17b186dc051a9f"
)

clone_and_pin() {
  local name="$1"
  local url="$2"
  local commit="$3"
  local dest="$PARENT_DIR/$name"

  if [ -d "$dest/.git" ]; then
    echo "  [$name] already present at $dest"
  else
    echo "  [$name] cloning from $url..."
    git clone "$url" "$dest"
    echo "  [$name] pinning to commit $commit..."
    git -C "$dest" checkout "$commit"
  fi
}

echo "--- 1. Cloning / verifying Haskell workspace dependencies ---"
for name in "${!REPOS[@]}"; do
  read -r url commit <<< "${REPOS[$name]}"
  clone_and_pin "$name" "$url" "$commit"
done

echo ""
echo "--- 2. Cloning / verifying runtime verification targets (optional for unit acts) ---"
for name in "${!OPTIONAL_REPOS[@]}"; do
  read -r url commit <<< "${OPTIONAL_REPOS[$name]}"
  clone_and_pin "$name" "$url" "$commit"
done

echo ""
echo "=== Workspace reconstitution complete ==="
echo "All sibling checkouts are ready in $PARENT_DIR."
echo "Assistant REPL & Reviewer tools:"
echo "  - CLI bridge:  $ARENA_DIR/scripts/campaign-cli.py status|discover|schedule|verify"
echo "  - MCP server:  $ARENA_DIR/scripts/campaign-mcp.py --mcp"
echo "  - Antigravity: $ARENA_DIR/.agents/skills/shikumi-campaign/SKILL.md"
echo ""
echo "You can now run 'cabal build all' or 'cabal run campaign-demo' from $ARENA_DIR."

if [[ "${1:-}" == "--build" ]]; then
  echo ""
  echo "--- 3. Running cabal build all ---"
  cd "$ARENA_DIR"
  cabal build all
fi
