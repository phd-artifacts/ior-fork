#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-/scratch/rodrigo.freitas/io-playground}"
LLVM_ROOT="${LLVM_ROOT:-/scratch/rodrigo.freitas/io-playground/llvm-infra/llvm-builds/apptainer-Debug}"
IOR_BIN="${IOR_BIN:-${REPO_ROOT}/application/ior-fork/src/ior}"
PROXY_BIN="${PROXY_BIN:-${LLVM_ROOT}/bin/llvm-offload-mpi-proxy-device}"
IOR_OUTFILE="${IOR_OUTFILE:-${REPO_ROOT}/application/ior-fork/tmp/ior-mpp-prototype.dat}"
LIBOMPTARGET_SO="${LIBOMPTARGET_SO:-${LLVM_ROOT}/lib/libomptarget.so.20.0git}"
OMP_RUNTIME_LIB="${OMP_RUNTIME_LIB:-${LLVM_ROOT}/runtimes/runtimes-bins/openmp/runtime/src}"

rank="${SLURM_PROCID:-${PMI_RANK:-${OMPI_COMM_WORLD_RANK:-0}}}"
world_size="${SLURM_NTASKS:-${PMI_SIZE:-${OMPI_COMM_WORLD_SIZE:-1}}}"
app_rank="${APP_RANK:-$((world_size - 1))}"

if [[ ! -x "${IOR_BIN}" ]]; then
  echo "Error: IOR binary not found: ${IOR_BIN}" >&2
  exit 1
fi
if [[ ! -x "${PROXY_BIN}" ]]; then
  echo "Error: proxy binary not found: ${PROXY_BIN}" >&2
  exit 1
fi
if [[ "${world_size}" -lt 2 ]]; then
  echo "Error: MPP prototype requires at least 2 MPI tasks (1 app + proxies)." >&2
  exit 1
fi
if [[ "${app_rank}" -lt 0 || "${app_rank}" -ge "${world_size}" ]]; then
  echo "Error: APP_RANK=${app_rank} is out of range for world_size=${world_size}." >&2
  exit 1
fi

mkdir -p "$(dirname "${IOR_OUTFILE}")"

export OMP_TARGET_OFFLOAD="${OMP_TARGET_OFFLOAD:-MANDATORY}"
export OMPTARGET_DISABLE_HOST_PLUGIN="${OMPTARGET_DISABLE_HOST_PLUGIN:-1}"
export LIBOMPFILE_BACKEND="${LIBOMPFILE_BACKEND:-MPI}"
export LIBOMPFILE_MPP_OPEN="${LIBOMPFILE_MPP_OPEN:-1}"
export LIBOMPFILE_MPP_IO="${LIBOMPFILE_MPP_IO:-1}"
export LIBOMPFILE_SCHEDULER="${LIBOMPFILE_SCHEDULER:-HEADNODE}"
export UCX_TLS="${UCX_TLS:-tcp,self}"
export UCX_POSIX_USE_PROC_LINK="${UCX_POSIX_USE_PROC_LINK:-n}"
export LD_LIBRARY_PATH="${OMP_RUNTIME_LIB}:${LD_LIBRARY_PATH:-}"

if [[ -f "${LIBOMPTARGET_SO}" && "${LD_PRELOAD:-}" != *"${LIBOMPTARGET_SO}"* ]]; then
  if [[ -n "${LD_PRELOAD:-}" ]]; then
    export LD_PRELOAD="${LIBOMPTARGET_SO}:${LD_PRELOAD}"
  else
    export LD_PRELOAD="${LIBOMPTARGET_SO}"
  fi
fi

if [[ "${rank}" -eq "${app_rank}" ]]; then
  export IOR_MPI_COMM_SELF=1
  host="$(hostname -s)"
  default_args=(
    -a OMPFILE
    -w -r
    -t 256k
    -b 4m
    -s 4
    -i 1
    -F
    -o "${IOR_OUTFILE}"
  )
  if [[ -n "${OMPFILE_IOR_ARGS:-}" ]]; then
    # shellcheck disable=SC2206
    default_args=(${OMPFILE_IOR_ARGS})
  fi

  echo "[ior-mpp] role=app rank=${rank}/${world_size} host=${host} running IOR with MPI_COMM_SELF"
  exec "${IOR_BIN}" "${default_args[@]}"
fi

host="$(hostname -s)"
echo "[ior-mpp] role=proxy rank=${rank}/${world_size} host=${host}"

proxy_timeout_sec="${PROXY_EXIT_TIMEOUT_SEC:-0}"
if [[ "${proxy_timeout_sec}" =~ ^[0-9]+$ ]] && (( proxy_timeout_sec > 0 )); then
  echo "[ior-mpp] proxy timeout enabled rank=${rank} timeout=${proxy_timeout_sec}s"
  set +e
  timeout --signal=TERM "${proxy_timeout_sec}" "${PROXY_BIN}"
  proxy_rc=$?
  set -e
  if [[ "${proxy_rc}" -eq 124 ]]; then
    echo "[ior-mpp] proxy rank=${rank} timeout reached; exiting cleanly"
    exit 0
  fi
  exit "${proxy_rc}"
fi

exec "${PROXY_BIN}"
