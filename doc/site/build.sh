#!/usr/bin/env bash
# Assemble the GitHub Pages site into ./_site:
#   index.html  <- README.md          (pandoc)
#   guide.html  <- docs/GUIDE.md      (pandoc)
#   api/        <- dune build @doc    (odoc HTML, package "vulkan")
# Requires: pandoc, dune + odoc in the current opam switch.
set -euo pipefail
cd "$(dirname "$0")/../.."
OUT=${1:-_site}
rm -rf "$OUT"
mkdir -p "$OUT"

dune build @doc
cp -r _build/default/_doc/_html "$OUT/api"
chmod -R u+w "$OUT/api"

render() { # render <markdown> <html> <title>
  local src=$1 dst=$2 title=$3 tmp
  tmp=$(mktemp)
  # Repository-relative links -> site links.
  sed -e 's#(docs/GUIDE\.md#(guide.html#g' \
      -e 's#(\./LICENSE)#(https://github.com/lloyd-g-w/ocaml-vulkan/blob/main/LICENSE)#g' \
      -e 's#(README\.md#(index.html#g' \
      -e 's#(\.\./README\.md#(index.html#g' \
      -e 's#](\.\./\(examples[^)]*\))#](https://github.com/lloyd-g-w/ocaml-vulkan/blob/main/\1)#g' \
      -e 's#\](\(DESIGN\.md\|CHANGELOG\.md\|examples/[^)]*\|test/[^)]*\|gen/[^)]*\|scripts/[^)]*\|registry/[^)]*\|lib/[^)]*\))#](https://github.com/lloyd-g-w/ocaml-vulkan/blob/main/\1)#g' \
      "$src" > "$tmp"
  pandoc "$tmp" --from gfm --to html5 --standalone --toc --toc-depth=3 \
    --metadata pagetitle="$title" \
    --css style.css \
    --include-before-body doc/site/nav.html --include-after-body doc/site/footer.html \
    --output "$dst"
  rm -f "$tmp"
}
render README.md "$OUT/index.html" "ocaml-vulkan"
render docs/GUIDE.md "$OUT/guide.html" "ocaml-vulkan — guide"
cp doc/site/style.css "$OUT/style.css"
touch "$OUT/.nojekyll"
echo "site assembled in $OUT: $(find "$OUT" -type f | wc -l) files, $(du -sh "$OUT" | cut -f1)"
