#!/bin/zsh
set -euo pipefail
cli="${1:A}"
icon="${0:A:h:h}/Support/Sill.icns"
fixture=$(mktemp -d)
trap 'rm -rf -- "$fixture"' EXIT
mkdir "$fixture"/{in,out}
sips -s format jpeg -Z 128 "$icon" --out "$fixture/in/2.jpg" >/dev/null
sips -s format png -Z 64 "$icon" --out "$fixture/in/10.png" >/dev/null
print 'checking CLI info and exact copy'
"$cli" info "$fixture/in/2.jpg" | grep -q '128 × 128 px'
"$cli" export "$fixture/in/2.jpg" --to "$fixture/out" --format original
cmp "$fixture/in/2.jpg" "$fixture/out/2.jpg"
"$cli" export "$fixture/in/2.jpg" --to "$fixture/out" --format original
cmp "$fixture/in/2.jpg" "$fixture/out/2 2.jpg"
print 'checking CLI batch conversion and rename'
"$cli" batch "$fixture/in" --to "$fixture/out" --prefix cli- --number --format png --resize 48
"$cli" info "$fixture/out/cli-1.png" | grep -q '48 × 48 px'
"$cli" info "$fixture/out/cli-2.png" | grep -q '48 × 48 px'
print 'checking CLI corrupt-file exit and partial success'
print 'broken' > "$fixture/in/3.png"
if "$cli" batch "$fixture/in" --to "$fixture/out" --prefix mixed- --number --format tiff; then
    print -u2 'Expected a failure status for corrupt input.'
    exit 1
fi
[[ -f "$fixture/out/mixed-1.tiff" && ! -e "$fixture/out/mixed-2.tiff" && -f "$fixture/out/mixed-3.tiff" ]]
print 'PASS  CLI info, copy, collisions, rename, conversion, and partial failure'
