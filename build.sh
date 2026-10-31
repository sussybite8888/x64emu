#!/bin/sh
# Concatenate the WAT fragments into one module and assemble it.
set -e
cd "$(dirname "$0")"
OUT=build/cpu.wat
mkdir -p build
cat src/wat/*.wat > "$OUT"
wat2wasm --enable-all --debug-names "$OUT" -o build/cpu.wasm
echo "built build/cpu.wasm  ($(wc -c < build/cpu.wasm) bytes)"
