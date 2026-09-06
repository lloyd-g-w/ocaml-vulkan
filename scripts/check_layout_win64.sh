#!/usr/bin/env bash
# Verify every struct layout computed by ctypes (Vk.Layout.all) against the
# real Vulkan headers *as seen by a 64-bit Windows compiler*, without needing
# Windows: x86_64-w64-mingw32-gcc -fsyntax-only on a file of _Static_assert()s.
# Covers all platform-independent structs plus the Win32-only ones
# (VK_USE_PLATFORM_WIN32_KHR).
#
# Requires: dune (the vulkan library builds), x86_64-w64-mingw32-gcc
# (Debian/Ubuntu: gcc-mingw-w64-x86-64), and Vulkan headers matching
# registry/VERSION in $VULKAN_HEADERS/include (or a vulkan.h on the default
# include path).
set -euo pipefail
cd "$(dirname "$0")/.."
CC=${MINGW_CC:-x86_64-w64-mingw32-gcc}
command -v "$CC" >/dev/null || { echo "check_layout_win64: $CC not found (install gcc-mingw-w64-x86-64)"; exit 2; }
inc=()
if [ -n "${VULKAN_HEADERS:-}" ]; then inc=(-I "$VULKAN_HEADERS/include"); fi

dune build test/layout_asserts.exe
tmp=$(mktemp --suffix=.c)
trap 'rm -f "$tmp"' EXIT
{
  echo '#define VK_USE_PLATFORM_WIN32_KHR 1'
  ./_build/default/test/layout_asserts.exe test/layout/x86_64-linux-gnu.txt Win32 D3D12 FullScreenExclusive
} > "$tmp"
"$CC" -std=c11 -fsyntax-only "${inc[@]}" "$tmp"
echo "check_layout_win64: OK -- $(grep -c _Static_assert "$tmp") assertions hold under $CC"
