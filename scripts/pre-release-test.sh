#!/usr/bin/env bash
# pre-release-test.sh — run all tests before building a release
set -euo pipefail

export PATH="$HOME/.cargo/bin:/opt/homebrew/bin:$PATH"
cd "$(dirname "$0")/.."

echo "═══════════════════════════════════════"
echo "  Murmur Pre-Release Tests"
echo "═══════════════════════════════════════"

# ── 1. Rust unit tests ──────────────────
echo ""
echo "▶ Rust tests (cargo test)..."
cargo test --manifest-path src-tauri/Cargo.toml 2>&1
echo "✓ Rust tests passed"

# ── 2. TypeScript type check ────────────
echo ""
echo "▶ TypeScript type check (tsc)..."
pnpm exec tsc --noEmit
echo "✓ TypeScript types OK"

# ── 3. TypeScript unit tests ────────────
echo ""
echo "▶ TypeScript tests (vitest)..."
pnpm test
echo "✓ TypeScript tests passed"

echo ""
echo "═══════════════════════════════════════"
echo "  All tests passed — ready to release"
echo "═══════════════════════════════════════"
