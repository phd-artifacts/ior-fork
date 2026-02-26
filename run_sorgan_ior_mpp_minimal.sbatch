#!/bin/bash
#SBATCH --job-name=ior-mpp-min
#SBATCH --partition=all
#SBATCH --nodes=2
#SBATCH --ntasks=3
#SBATCH --nodelist=sorgan-cpu[1-4],sorgan-gpu[1-4]
#SBATCH --exclude=sorgan-cpu5,sorgan-cpu6
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
BUILD_IOR="${BUILD_IOR:-1}"
SRUN_NODES="${SRUN_NODES:-2}"
SRUN_TASKS="${SRUN_TASKS:-3}"
OMPFILE_INC="${OMPFILE_INC:-${LLVM_INSTALL_ROOT}/include}"
OMPFILE_LIB="${OMPFILE_LIB:-${LLVM_ROOT}/runtimes/runtimes-bins/openmp/libompfile}"

cd "${REPO_ROOT}"

if [[ ! -f "${SIF_IMAGE}" ]]; then
  echo "Error: missing Apptainer image at ${SIF_IMAGE}" >&2
  exit 1
fi
if [[ ! -x "${RUNNER}" ]]; then
  echo "Error: missing runner script at ${RUNNER}" >&2
  exit 1
fi

COMMON_ENV="source ${REPO_ROOT}/sh-scripts/set_env.sh ${LLVM_ROOT} && \
export LLVM_ROOT=${LLVM_ROOT} && \
export LLVM_INSTALL_ROOT=${LLVM_INSTALL_ROOT} && \
export REPO_ROOT=${REPO_ROOT} && \
export PATH=/usr/local/mpich/bin:${PATH} && \
export LD_LIBRARY_PATH=/usr/local/mpich/lib:${OMPFILE_LIB}:${LLVM_ROOT}/lib:${LD_LIBRARY_PATH:-}"

if [[ "${BUILD_IOR}" == "1" || ! -x "${IOR_BIN}" ]]; then
  echo "[ior-mpp] building IOR backend binary"
  apptainer exec --userns --no-privs --bind /scratch/rodrigo.freitas/io-playground "${SIF_IMAGE}" \
    bash -lc "${COMMON_ENV} && cd ${IOR_DIR} && bash ${REPO_ROOT}/sh-scripts/register_mpi_clang.sh && CPPFLAGS='-I${OMPFILE_INC}' LDFLAGS='-L${OMPFILE_LIB}' ./configure CC=mpi_clang && make -j"
fi

if [[ ! -x "${IOR_BIN}" ]]; then
  echo "Error: expected IOR binary not found at ${IOR_BIN}" >&2
  exit 1
fi

echo "[ior-mpp] launching MPP prototype with ${SRUN_TASKS} tasks"

srun --mpi=pmi2 --nodes="${SRUN_NODES}" --ntasks="${SRUN_TASKS}" \
  apptainer exec --userns --no-privs --bind /scratch/rodrigo.freitas/io-playground "${SIF_IMAGE}" \
  bash -lc "${COMMON_ENV} && \
    export IOR_BIN=${IOR_BIN} && \
    export OMPFILE_IOR_ARGS='-a OMPFILE -w -r -t 256k -b 4m -s 4 -i 1 -F -o ${IOR_DIR}/tmp/ior-mpp-minimal.dat' && \
    bash ${RUNNER}"
