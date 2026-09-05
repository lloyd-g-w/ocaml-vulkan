#!/usr/bin/env bash
# Generate test/enum_values/<arch>.txt: for every Vulkan enum constant and
# bitmask bit declared by the real <vulkan/vulkan.h> (VK_ENABLE_BETA_EXTENSIONS
# defined, no VK_USE_PLATFORM_* macro), print `NAME <value>` as computed by
# the real C compiler.
#
# Pipeline: gen/enum_check.py emits a C11 probe program from registry/vk.xml
# -> gcc -Wall compiles it against $VULKAN_HEADERS/include -> we run it and
# capture stdout as the golden file. Mirrors scripts/gen_layout.sh: if the
# pinned registry (registry/VERSION) and the installed Vulkan-Headers ever
# drift apart, gcc might reject a name that the XML claims exists (or vice
# versa); rather than fail the whole build we scan the compiler errors,
# exclude exactly the offending constant(s) and retry, capped at a handful
# of attempts.
#
# Usage: scripts/gen_enum_values.sh [output-file]
#   (default output-file: test/enum_values/<gcc -dumpmachine>.txt, i.e.
#   test/enum_values/x86_64-linux-gnu.txt on this box)
set -euo pipefail
cd "$(dirname "$0")/.."

registry=registry/vk.xml
arch="$(gcc -dumpmachine)"
out="${1:-test/enum_values/${arch}.txt}"
max_attempts=8

if [ -n "${VULKAN_HEADERS:-}" ]; then
  include_flags=(-I"${VULKAN_HEADERS}/include")
else
  echo "gen_enum_values.sh: warning: VULKAN_HEADERS is not set (source vk-env.sh);" \
       "falling back to the compiler's default include path" >&2
  include_flags=()
fi

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT
c_file="$workdir/enum_check.c"
bin_file="$workdir/enum_check"
err_file="$workdir/gcc.err"

exclude_args=()

mkdir -p "$(dirname "$out")"

attempt=1
while :; do
  python3 gen/enum_check.py --registry "$registry" --out "$c_file" "${exclude_args[@]}"

  if gcc -std=c11 -Wall "${include_flags[@]}" -o "$bin_file" "$c_file" 2>"$err_file"; then
    cat "$err_file" >&2 # forward any (non-fatal) warnings; expected to be empty
    break
  fi

  echo "gen_enum_values.sh: attempt $attempt/$max_attempts: gcc failed, scanning errors for" \
       "constants the installed headers don't declare" >&2
  cat "$err_file" >&2

  if [ "$attempt" -ge "$max_attempts" ]; then
    echo "gen_enum_values.sh: giving up after $max_attempts attempts" >&2
    exit 1
  fi

  mapfile -t new_excludes < <(python3 - "$err_file" << 'PY'
import re
import sys

text = open(sys.argv[1]).read()
# gcc renders diagnostic quotes as Unicode U+2018/U+2019 whenever the locale
# allows it, not ASCII apostrophes; normalise so the pattern below matches
# regardless of the environment's locale.
text = text.replace("\u2018", "'").replace("\u2019", "'")
names = set()
for m in re.finditer(r"error: '(VK_\w+)' undeclared", text):
    names.add(m.group(1))
for name in sorted(names):
    print(name)
PY
)

  if [ "${#new_excludes[@]}" -eq 0 ]; then
    echo "gen_enum_values.sh: gcc failed but no known 'undeclared constant' pattern" \
         "was found in its output; giving up (see errors above)" >&2
    exit 1
  fi

  for name in "${new_excludes[@]}"; do
    exclude_args+=(--exclude-value "$name")
    echo "gen_enum_values.sh: excluding constant not declared by these headers: $name" >&2
  done

  attempt=$((attempt + 1))
done

"$bin_file" > "$out"
lines=$(wc -l < "$out")
echo "gen_enum_values.sh: wrote $out ($lines constants)" >&2
