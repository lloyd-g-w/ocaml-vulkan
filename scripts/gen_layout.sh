#!/usr/bin/env bash
# Generate test/layout/<arch>.txt: for every Vulkan struct/union declared by
# the real <vulkan/vulkan.h> (VK_ENABLE_BETA_EXTENSIONS defined, no
# VK_USE_PLATFORM_* macro), print `Name sizeof` + `  member offsetof` lines.
#
# Pipeline: gen/layout_check.py emits a C11 probe program from registry/vk.xml
# -> gcc -Wall compiles it against $VULKAN_HEADERS/include -> we run it and
# capture stdout as the golden file. If the pinned registry (registry/VERSION)
# and the installed Vulkan-Headers ever drift apart, some struct/member might
# be in the XML but not the headers (or vice versa); rather than fail the
# whole build we scan the compiler errors, exclude exactly the offending
# type/member and retry, capped at a handful of attempts.
#
# Usage: scripts/gen_layout.sh [output-file]
#   (default output-file: test/layout/<gcc -dumpmachine>.txt, i.e.
#   test/layout/x86_64-linux-gnu.txt on this box)
set -euo pipefail
cd "$(dirname "$0")/.."

registry=registry/vk.xml
arch="$(gcc -dumpmachine)"
out="${1:-test/layout/${arch}.txt}"
max_attempts=8

if [ -n "${VULKAN_HEADERS:-}" ]; then
  include_flags=(-I"${VULKAN_HEADERS}/include")
else
  echo "gen_layout.sh: warning: VULKAN_HEADERS is not set (source vk-env.sh);" \
       "falling back to the compiler's default include path" >&2
  include_flags=()
fi

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT
c_file="$workdir/layout_check.c"
bin_file="$workdir/layout_check"
err_file="$workdir/gcc.err"

exclude_type_args=()
exclude_member_args=()

mkdir -p "$(dirname "$out")"

attempt=1
while :; do
  python3 gen/layout_check.py --registry "$registry" --out "$c_file" \
    "${exclude_type_args[@]}" "${exclude_member_args[@]}"

  if gcc -std=c11 -Wall "${include_flags[@]}" -o "$bin_file" "$c_file" 2>"$err_file"; then
    cat "$err_file" >&2 # forward any (non-fatal) warnings; expected to be empty
    break
  fi

  echo "gen_layout.sh: attempt $attempt/$max_attempts: gcc failed, scanning errors for" \
       "types/members the installed headers don't declare" >&2
  cat "$err_file" >&2

  if [ "$attempt" -ge "$max_attempts" ]; then
    echo "gen_layout.sh: giving up after $max_attempts attempts" >&2
    exit 1
  fi

  mapfile -t new_excludes < <(python3 - "$err_file" << 'PY'
import re
import sys

text = open(sys.argv[1]).read()
# gcc renders diagnostic quotes as Unicode U+2018/U+2019 whenever the locale
# allows it, not ASCII apostrophes; normalise so the patterns below match
# regardless of the environment's locale.
text = text.replace("\u2018", "'").replace("\u2019", "'")
types = set()
members = set()
for m in re.finditer(
    r"error: (?:unknown type name |storage size of '[^']*' isn't known)?"
    r"'(?:struct |union )?(Vk\w+)'(?: undeclared| has incomplete type)?",
    text,
):
    types.add(m.group(1))
for m in re.finditer(r"error: '(Vk\w+)' has no member named '(\w+)'", text):
    members.add((m.group(1), m.group(2)))
    types.discard(m.group(1))  # struct itself is fine, only this member isn't
for t in sorted(types):
    print(f"type\t{t}")
for s, mem in sorted(members):
    print(f"member\t{s}.{mem}")
PY
)

  if [ "${#new_excludes[@]}" -eq 0 ]; then
    echo "gen_layout.sh: gcc failed but no known 'unknown type/member' pattern" \
         "was found in its output; giving up (see errors above)" >&2
    exit 1
  fi

  for entry in "${new_excludes[@]}"; do
    kind="${entry%%$'\t'*}"
    value="${entry#*$'\t'}"
    if [ "$kind" = type ]; then
      exclude_type_args+=(--exclude-type "$value")
      echo "gen_layout.sh: excluding struct/union not declared by these headers: $value" >&2
    else
      exclude_member_args+=(--exclude-member "$value")
      echo "gen_layout.sh: excluding member not declared by these headers: $value" >&2
    fi
  done

  attempt=$((attempt + 1))
done

"$bin_file" > "$out"
lines=$(wc -l < "$out")
entries=$(grep -c -v '^  ' "$out" || true)
echo "gen_layout.sh: wrote $out ($lines lines, $entries struct/union entries)" >&2
