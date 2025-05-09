#!/bin/bash

set -e

echo "Using clang:"
/usr/bin/which clang

export CFLAGS="-std=c99"

source ../../sh-scripts/register_mpi_clang.sh

./configure --enable-ompfile CC=mpi_clang

echo "Building IOR with clang:"
mpi_clang --version

make -j
export LIBOMPFILE_BACKEND=POSIX


mpirun -n 1 ./src/ior -a OMPFILE -w -r -b 1m -t 1m -s 10          -o /tmp/ior_ompfile.dat
mpirun -n 1 ./src/ior -a POSIX -w -r -b 1m -t 1m -s 10          -o /tmp/ior_posix.dat