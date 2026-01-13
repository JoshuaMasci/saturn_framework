#!/bin/bash
set -euo pipefail

INCLUDE_DIR="../shader/glsl"

SHADER_DIRS=(
    "triangle"
    "cube"
)

declare -A STAGES=(
    ["vert"]="vert"
    ["frag"]="frag"
    ["comp"]="comp"
    ["geom"]="geom"
    ["tesc"]="tesc"
    ["tese"]="tese"
)

for dir in "${SHADER_DIRS[@]}"; do
    find "$dir" -type f | while read -r shader; do
        ext="${shader##*.}"

        if [[ -n "${STAGES[$ext]:-}" ]]; then
            stage="${STAGES[$ext]}"
            output="${shader}.spv"

            echo "Compiling $shader → $output"

            glslc \
                -I "$INCLUDE_DIR" \
                -fshader-stage="$stage" \
                "$shader" \
                -o "$output"
        fi
    done
done
