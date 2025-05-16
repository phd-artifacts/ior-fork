#!/bin/bash

set -e

echo "Using clang:"
/usr/bin/which clang

# Check if block_size or ior_mode are undefined or empty
if [ -z "${block_size}" ] || [ -z "${ior_mode}" ]; then
  echo "Error: Required environment variables 'block_size' or 'ior_mode' are not set."
  return 1
fi

export CFLAGS="-std=c99"

source ../../sh-scripts/register_mpi_clang.sh

echo "Building IOR with clang:"
mpi_clang --version

mkdir -p ./tmp

if [ "${SKIP_COMPILE}" != "1" ]; then
  echo "Compiling the project..."
  ./configure --enable-ompfile CC=mpi_clang
  make -j
else
  echo "Skipping compilation as SKIP_COMPILE is set to 1."
fi

read_or_write_flag=0
if [ "${read_or_write}" = "read" ]; then
  echo "Performing read operation..."
  read_or_write_flag="-r -w"
elif [ "${read_or_write}" = "write" ]; then
  echo "Performing write operation..."
  read_or_write_flag="-w"
else
  echo "Error: 'read_or_write' must be either 'read' or 'write'."
  exit 1
fi

if [ "${ior_mode}" = "posix" ]; then
  echo "IOR mode: POSIX"

  mpirun -n 1 ./src/ior -a POSIX $read_or_write_flag -b $block_size -t 16k -s 100 -o ./tmp/$ior_backend_$block_size.dat

elif [ "${ior_mode}" = "ompfile_posix" ]; then
  echo "IOR mode: OMPFile POSIX"
  export LIBOMPFILE_BACKEND=POSIX
  mpirun -n 1 ./src/ior -a OMPFILE $read_or_write_flag -b $block_size -t 16k -s 100 -o ./tmp/$ior_backend_$block_size.dat

elif [ "${ior_mode}" = "ompfile_io_uring" ]; then
  echo "IOR mode: OMPFile IO_URING"
  export LIBOMPFILE_BACKEND="IO_URING"
  mpirun -n 1 ./src/ior -a OMPFILE $read_or_write_flag -b $block_size -t 16k -s 100 -o ./tmp/$ior_backend_$block_size.dat

elif [ "${ior_mode}" = "ompfile_mpi_io" ]; then
  echo "IOR mode: OMPFile MPI I/O"
  export LIBOMPFILE_BACKEND="MPI"
  mpirun -n 1 ./src/ior -a OMPFILE $read_or_write_flag -b $block_size -t 16k -s 100 -o ./tmp/$ior_backend_$block_size.dat

else
  echo "Error: Invalid IOR mode '${ior_mode}'. Valid options are: posix, ompfile_posix, ompfile_io_uring, ompfile_mpi_io."
  exit 1
fi

echo "IOR operation completed successfully."
