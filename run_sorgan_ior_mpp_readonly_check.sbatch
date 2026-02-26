#!/bin/bash
#SBATCH --job-name=ior-mpp-read2n
#SBATCH --partition=all
#SBATCH --nodes=2
#SBATCH --ntasks=4
#SBATCH --ntasks-per-node=2
#SBATCH --time=00:20:00
#SBATCH --output=%x-%j.out

set -euo pipefail

REPO_ROOT="/scratch/rodrigo.freitas/io-playground"
SIF_IMAGE="${REPO_ROOT}/sifs/ompc-base_latest.sif"
LLVM_ROOT="${LLVM_ROOT:-${REPO_ROOT}/llvm-infra/llvm-builds/apptainer-Debug}"
LLVM_INSTALL_ROOT="${LLVM_INSTALL_ROOT:-${REPO_ROOT}/llvm-infra/llvm-installs/apptainer-Debug}"
IOR_DIR="${REPO_ROOT}/application/ior-fork"
IOR_BIN="${IOR_DIR}/src/ior"
RUNNER="${IOR_DIR}/run_mpp_minimal.sh"
OMPFILE_LIB="${LLVM_ROOT}/runtimes/runtimes-bins/openmp/libompfile"
OMP_RUNTIME_LIB="${LLVM_ROOT}/runtimes/runtimes-bins/openmp/runtime/src"
DATA_BASENAME="${IOR_DIR}/tmp/ior-mpp-readonly-check.dat"
DATA_FILE="${DATA_BASENAME}.00000000"

cd "${REPO_ROOT}"

if [[ ! -x "${IOR_BIN}" ]]; then
  echo "Error: missing IOR binary at ${IOR_BIN}" >&2
  exit 1
fi
if [[ ! -x "${RUNNER}" ]]; then
  echo "Error: missing runner script at ${RUNNER}" >&2
  exit 1
fi
if [[ ! -f "${SIF_IMAGE}" ]]; then
  echo "Error: missing Apptainer image at ${SIF_IMAGE}" >&2
  exit 1
fi

mkdir -p "${IOR_DIR}/tmp"
rm -f "${DATA_BASENAME}" "${DATA_FILE}"
# read-only validation still needs an existing dataset for file-per-process naming.
dd if=/dev/zero of="${DATA_FILE}" bs=1M count=16 status=none

echo "[ior-mpp-readonly] prepared data file ${DATA_FILE}"

COMMON_ENV="source ${REPO_ROOT}/sh-scripts/set_env.sh ${LLVM_ROOT} && \
export LLVM_ROOT=${LLVM_ROOT} && \
export LLVM_INSTALL_ROOT=${LLVM_INSTALL_ROOT} && \
export REPO_ROOT=${REPO_ROOT} && \
export PATH=/usr/local/mpich/bin:${PATH} && \
export LD_LIBRARY_PATH=/usr/local/mpich/lib:${OMP_RUNTIME_LIB}:${OMPFILE_LIB}:${LLVM_ROOT}/lib:${LD_LIBRARY_PATH:-}"

srun --mpi=pmi2 --nodes=2 --ntasks=4 --ntasks-per-node=2 \
  apptainer exec --userns --no-privs --bind /scratch/rodrigo.freitas/io-playground "${SIF_IMAGE}" \
  bash -lc "${COMMON_ENV} && \
    export IOR_BIN=${IOR_BIN} && \
    export OMPFILE_IOR_ARGS='-a OMPFILE -r -t 256k -b 4m -s 4 -i 1 -F -o ${DATA_BASENAME}' && \
    export PROXY_EXIT_TIMEOUT_SEC=20 && \
    export LIBOMPFILE_DEBUG_TRACE=0 && \
    export LIBOMPTARGET_DEBUG=0 && \
    export LIBOMPTARGET_INFO=0 && \
    bash ${RUNNER}"
