#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_DIR="$SCRIPT_DIR/slang"
PLATFORM="${1:-all}"
ENTRYPOINT="compute_main"

if [[ -n "${SLANGC:-}" ]]; then
    SLANG_COMPILER="$SLANGC"
elif command -v slangc >/dev/null 2>&1; then
    SLANG_COMPILER="$(command -v slangc)"
elif [[ -x "$HOME/Downloads/Slang 2026.19 macOS/bin/slangc" ]]; then
    SLANG_COMPILER="$HOME/Downloads/Slang 2026.19 macOS/bin/slangc"
else
    echo "slangc was not found; set SLANGC to its absolute path" >&2
    exit 1
fi

case "$PLATFORM" in
    all|macos|linux|windows) ;;
    *)
        echo "usage: $0 [all|macos|linux|windows]" >&2
        exit 2
        ;;
esac

compile_macos() {
    local source="$1"
    local name="$2"
    mkdir -p "$SCRIPT_DIR/macos"
    "$SLANG_COMPILER" "$source" \
        -entry "$ENTRYPOINT" -stage compute \
        -target metal \
        -o "$SCRIPT_DIR/macos/$name.metal"
}

compile_spirv() {
    local source="$1"
    local output_dir="$2"
    local name="$3"
    mkdir -p "$SCRIPT_DIR/$output_dir"
    "$SLANG_COMPILER" "$source" \
        -entry "$ENTRYPOINT" -stage compute \
        -target spirv -profile spirv_1_3 \
        -o "$SCRIPT_DIR/$output_dir/$name.spv"
}

shopt -s nullglob
sources=("$SOURCE_DIR"/*.slang)
if (( ${#sources[@]} == 0 )); then
    echo "no .slang kernels found in $SOURCE_DIR" >&2
    exit 1
fi

for source in "${sources[@]}"; do
    name="$(basename "$source" .slang)"

    if [[ "$PLATFORM" == all || "$PLATFORM" == macos ]]; then
        compile_macos "$source" "$name"
    fi
    if [[ "$PLATFORM" == all || "$PLATFORM" == linux ]]; then
        compile_spirv "$source" linux "$name"
    fi
    if [[ "$PLATFORM" == all || "$PLATFORM" == windows ]]; then
        compile_spirv "$source" windows "$name"
    fi
done

echo "compiled ${#sources[@]} Slang kernel(s) for $PLATFORM"
