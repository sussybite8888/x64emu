#!/bin/sh
# Differential test: same instructions, real silicon versus the emulator.
#   ./run.sh [count] [seed]
set -e
cd "$(dirname "$0")"
N=${1:-20000}; SEED=${2:-1}
HOST=ubuntu@p1g4.local
python3 gen.py "$N" "$SEED"
scp -q cases.s init.bin runner.c "$HOST:~/difftest/"
ssh "$HOST" 'cd ~/difftest && as cases.s -o cases.o && \
  objcopy -O binary --only-section=.text cases.o cases.bin && \
  gcc -O2 -o runner runner.c && ./runner cases.bin init.bin results.bin'
scp -q "$HOST:~/difftest/cases.bin" "$HOST:~/difftest/results.bin" .
node local.mjs
