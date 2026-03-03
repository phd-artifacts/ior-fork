#!/bin/bash
#SBATCH --job-name=ior-backend-cmp
#SBATCH --partition=all
#SBATCH --nodes=2
#SBATCH --ntasks=4
#SBATCH --ntasks-per-node=2
#SBATCH --nodelist=sorgan-cpu[1-4],sorgan-gpu[1-4]
#SBATCH --exclude=sorgan-cpu5,sorgan-cpu6
#SBATCH --time=00:30:00
#SBATCH --output=%x-%j.out

set -euo pipefail

REPO_ROOT="${REPO_ROOT:-/scratch/rodrigo.freitas/io-playground}"
SIF_IMAGE="${SIF_IMAGE:-${REPO_ROOT}/sifs/ompc-base_latest.sif}"
APPTAINER_BIN="${APPTAINER_BIN:-/usr/bin/apptainer}"
LLVM_ROOT="${LLVM_ROOT:-${REPO_ROOT}/llvm-infra/llvm-builds/apptainer-Debug}"
LLVM_INSTALL_ROOT="${LLVM_INSTALL_ROOT:-${REPO_ROOT}/llvm-infra/llvm-installs/apptainer-Debug}"
IOR_DIR="${IOR_DIR:-${REPO_ROOT}/application/ior-fork}"
IOR_BIN="${IOR_BIN:-${IOR_DIR}/src/ior}"
COMPARE_SCRIPT="${COMPARE_SCRIPT:-${IOR_DIR}/run_backend_compare.sh}"
OMPFILE_INC="${OMPFILE_INC:-${LLVM_INSTALL_ROOT}/include}"
OMPFILE_LIB="${OMPFILE_LIB:-${LLVM_ROOT}/runtimes/runtimes-bins/openmp/libompfile}"
OMP_RUNTIME_LIB="${OMP_RUNTIME_LIB:-${LLVM_ROOT}/runtimes/runtimes-bins/openmp/runtime/src}"

COMPARE_MODES_RAW="${IOR_COMPARE_MODES:-MPIIO,POSIX,OMPFILE_MPI}"
COMPARE_REPEATS="${IOR_COMPARE_REPEATS:-3}"
COMPARE_BLOCK_SIZE="${IOR_COMPARE_BLOCK_SIZE:-4m}"
COMPARE_TRANSFER_SIZE="${IOR_COMPARE_TRANSFER_SIZE:-256k}"
COMPARE_SEGMENTS="${IOR_COMPARE_SEGMENTS:-8}"
COMPARE_ITERATIONS="${IOR_COMPARE_ITERATIONS:-1}"
COMPARE_RW="${IOR_COMPARE_RW:-rw}"
COMPARE_TASKS="${IOR_COMPARE_TASKS:-${SLURM_NTASKS}}"
COMPARE_OUTDIR="${IOR_COMPARE_OUTDIR:-${IOR_DIR}/tmp/backend-compare-slurm-${SLURM_JOB_ID}}"
COMPARE_CLEAN_DATA="${IOR_COMPARE_CLEAN_DATA:-1}"
BUILD_IOR="${BUILD_IOR:-1}"
OMPFILE_SCHEDULER="${IOR_OMPFILE_SCHEDULER:-${LIBOMPFILE_SCHEDULER:-HEADNODE}}"
OMPFILE_RUN_MPP="${IOR_OMPFILE_RUN_MPP:-0}"
OMPFILE_REQUIRE_MPP="${IOR_OMPFILE_REQUIRE_MPP:-1}"

assert_positive_int() {
  local value="$1"
  local name="$2"
  if [[ ! "${value}" =~ ^[0-9]+$ ]] || (( value < 1 )); then
    echo "Error: ${name} must be a positive integer, got '${value}'." >&2
    exit 1
  fi
}

assert_positive_int "${COMPARE_REPEATS}" "IOR_COMPARE_REPEATS"
assert_positive_int "${COMPARE_SEGMENTS}" "IOR_COMPARE_SEGMENTS"
assert_positive_int "${COMPARE_ITERATIONS}" "IOR_COMPARE_ITERATIONS"
assert_positive_int "${COMPARE_TASKS}" "IOR_COMPARE_TASKS"
if [[ ! "${OMPFILE_RUN_MPP}" =~ ^[01]$ ]]; then
  echo "Error: IOR_OMPFILE_RUN_MPP must be 0 or 1, got '${OMPFILE_RUN_MPP}'." >&2
  exit 1
fi
if [[ ! "${OMPFILE_REQUIRE_MPP}" =~ ^[01]$ ]]; then
  echo "Error: IOR_OMPFILE_REQUIRE_MPP must be 0 or 1, got '${OMPFILE_REQUIRE_MPP}'." >&2
  exit 1
fi

if [[ ! -f "${SIF_IMAGE}" ]]; then
  echo "Error: Apptainer image not found: ${SIF_IMAGE}" >&2
  exit 1
fi
if [[ ! -x "${APPTAINER_BIN}" ]]; then
  echo "Error: apptainer binary not found: ${APPTAINER_BIN}" >&2
  exit 1
fi
if [[ ! -x "${COMPARE_SCRIPT}" ]]; then
  echo "Error: compare script not found: ${COMPARE_SCRIPT}" >&2
  exit 1
fi

case "${COMPARE_RW}" in
  rw) IO_FLAGS="-w -r" ;;
  read) IO_FLAGS="-r" ;;
  write) IO_FLAGS="-w" ;;
  *)
    echo "Error: IOR_COMPARE_RW must be one of: rw, read, write." >&2
    exit 1
    ;;
esac

COMMON_ENV="source ${REPO_ROOT}/sh-scripts/set_env.sh ${LLVM_ROOT} && \
export REPO_ROOT=${REPO_ROOT} && \
export LLVM_ROOT=${LLVM_ROOT} && \
export LLVM_INSTALL_ROOT=${LLVM_INSTALL_ROOT} && \
export PATH=/usr/local/mpich/bin:\${PATH} && \
export LD_LIBRARY_PATH=/usr/local/mpich/lib:${OMP_RUNTIME_LIB}:${OMPFILE_LIB}:${LLVM_ROOT}/lib:\${LD_LIBRARY_PATH:-}"

if [[ "${BUILD_IOR}" == "1" || ! -x "${IOR_BIN}" ]]; then
  echo "[ior-backend-cmp] building IOR"
  "${APPTAINER_BIN}" exec --userns --no-privs --bind /scratch/rodrigo.freitas/io-playground "${SIF_IMAGE}" \
    bash -lc "${COMMON_ENV} && cd ${IOR_DIR} && source ${REPO_ROOT}/sh-scripts/register_mpi_clang.sh && CPPFLAGS='-I${OMPFILE_INC}' LDFLAGS='-L${OMPFILE_LIB}' ./configure CC=mpi_clang && make -j"
fi

if [[ ! -x "${IOR_BIN}" ]]; then
  echo "Error: IOR binary not found after build: ${IOR_BIN}" >&2
  exit 1
fi

mkdir -p "${COMPARE_OUTDIR}"
SUMMARY_CSV="${COMPARE_OUTDIR}/summary.csv"
cat > "${SUMMARY_CSV}" <<'EOF'
mode,repeat,api,libompfile_backend,write_bw_mib_s,read_bw_mib_s,write_mean_s,read_mean_s,log_file,flightplan_state,sched_fallback_count,mpp_shim_missing_count
EOF

echo "[ior-backend-cmp] allocated nodes: ${SLURM_JOB_NODELIST}"
scontrol show hostnames "${SLURM_JOB_NODELIST}" | sed 's/^/[ior-backend-cmp] node /'
echo "[ior-backend-cmp] distributed reachability check:"
srun --mpi=pmi2 --nodes="${SLURM_JOB_NUM_NODES}" --ntasks="${COMPARE_TASKS}" /bin/hostname -s | sort -u | sed 's/^/[ior-backend-cmp] reached /'

extract_summary_field() {
  local log_file="$1"
  local op="$2"
  local col="$3"
  awk -v op="${op}" -v col="${col}" '
    /^Summary of all tests:/ {in_summary=1; next}
    in_summary && $1 == op {print $col; exit}
  ' "${log_file}"
}

run_case() {
  local mode="$1"
  local repeat_id="$2"
  local api=""
  local backend="na"
  local mode_env_stmt=""
  local mpp_enabled_for_case=0

  case "${mode}" in
    MPIIO)
      api="MPIIO"
      backend="na"
      mode_env_stmt="unset LIBOMPFILE_BACKEND LIBOMPFILE_SCHEDULER LIBOMPFILE_MPP_OPEN LIBOMPFILE_MPP_IO LIBOMPFILE_MPP_PING LIBOMPFILE_OPT_TWO_PHASE LIBOMPFILE_OPT_OPEN_CACHE LIBOMPFILE_OPT_OPEN_CACHE_KEEP_OPEN LIBOMPFILE_OPT_STATS UCX_TLS UCX_POSIX_USE_PROC_LINK;"
      ;;
    POSIX)
      api="POSIX"
      backend="na"
      mode_env_stmt="unset LIBOMPFILE_BACKEND LIBOMPFILE_SCHEDULER LIBOMPFILE_MPP_OPEN LIBOMPFILE_MPP_IO LIBOMPFILE_MPP_PING LIBOMPFILE_OPT_TWO_PHASE LIBOMPFILE_OPT_OPEN_CACHE LIBOMPFILE_OPT_OPEN_CACHE_KEEP_OPEN LIBOMPFILE_OPT_STATS UCX_TLS UCX_POSIX_USE_PROC_LINK;"
      ;;
    OMPFILE_MPI)
      api="OMPFILE"
      backend="MPI"
      mode_env_stmt="export LIBOMPFILE_BACKEND='MPI'; export LIBOMPFILE_SCHEDULER='${OMPFILE_SCHEDULER}'; export UCX_TLS='${UCX_TLS:-tcp,self}'; export UCX_POSIX_USE_PROC_LINK='${UCX_POSIX_USE_PROC_LINK:-n}';"
      if [[ "${OMPFILE_RUN_MPP}" == "1" ]]; then
        mode_env_stmt="${mode_env_stmt} export LIBOMPFILE_MPP_OPEN=1; export LIBOMPFILE_MPP_IO=1;"
        mpp_enabled_for_case=1
      else
        mode_env_stmt="${mode_env_stmt} export LIBOMPFILE_MPP_OPEN=0; export LIBOMPFILE_MPP_IO=0;"
      fi
      ;;
    OMPFILE_POSIX)
      api="OMPFILE"
      backend="POSIX"
      mode_env_stmt="export LIBOMPFILE_BACKEND='POSIX'; unset LIBOMPFILE_SCHEDULER LIBOMPFILE_MPP_OPEN LIBOMPFILE_MPP_IO LIBOMPFILE_MPP_PING UCX_TLS UCX_POSIX_USE_PROC_LINK;"
      ;;
    OMPFILE_IO_URING)
      api="OMPFILE"
      backend="IO_URING"
      mode_env_stmt="export LIBOMPFILE_BACKEND='IO_URING'; unset LIBOMPFILE_SCHEDULER LIBOMPFILE_MPP_OPEN LIBOMPFILE_MPP_IO LIBOMPFILE_MPP_PING UCX_TLS UCX_POSIX_USE_PROC_LINK;"
      ;;
    *)
      echo "Error: unsupported mode '${mode}' in IOR_COMPARE_MODES." >&2
      exit 1
      ;;
  esac

  local lower_mode="${mode,,}"
  local data_path="${COMPARE_OUTDIR}/${lower_mode}-r${repeat_id}.dat"
  local log_file="${COMPARE_OUTDIR}/${lower_mode}-r${repeat_id}.log"
  if [[ "${COMPARE_CLEAN_DATA}" == "1" ]]; then
    rm -f "${data_path}" "${data_path}".*
  fi

  echo "[ior-backend-cmp] mode=${mode} repeat=${repeat_id} mpp=${mpp_enabled_for_case}"
  srun --mpi=pmi2 --nodes="${SLURM_JOB_NUM_NODES}" --ntasks="${COMPARE_TASKS}" \
    "${APPTAINER_BIN}" exec --userns --no-privs --bind /scratch/rodrigo.freitas/io-playground "${SIF_IMAGE}" \
    bash -lc "${COMMON_ENV} && cd ${IOR_DIR} && ${mode_env_stmt} ${IOR_BIN} -a ${api} ${IO_FLAGS} -t ${COMPARE_TRANSFER_SIZE} -b ${COMPARE_BLOCK_SIZE} -s ${COMPARE_SEGMENTS} -i ${COMPARE_ITERATIONS} -F -o ${data_path}" \
    > "${log_file}" 2>&1

  local write_bw
  local read_bw
  local write_s
  local read_s
  local flightplan_state="na"
  local sched_fallback_count=0
  local mpp_shim_missing_count=0
  write_bw="$(extract_summary_field "${log_file}" "write" 2)"
  read_bw="$(extract_summary_field "${log_file}" "read" 2)"
  write_s="$(extract_summary_field "${log_file}" "write" 10)"
  read_s="$(extract_summary_field "${log_file}" "read" 10)"

  if [[ "${api}" == "OMPFILE" ]]; then
    sched_fallback_count="$(grep -c "HEADNODE scheduler request failed" "${log_file}" || true)"
    mpp_shim_missing_count="$(grep -c "MPP shim not available" "${log_file}" || true)"
    if (( sched_fallback_count > 0 )); then
      flightplan_state="headnode_fallback_local"
    elif (( mpp_shim_missing_count > 0 )); then
      flightplan_state="headnode_no_shim"
    else
      flightplan_state="headnode_path_no_fallback_seen"
    fi

    if [[ "${mpp_enabled_for_case}" == "1" && "${OMPFILE_REQUIRE_MPP}" == "1" ]]; then
      local mpp_init_fail_count
      local mpp_open_failed_count
      local mpp_shim_open_failed_count
      local mpp_disabled_sched_count
      local mpp_bootstrap_ok_count
      mpp_init_fail_count="$(grep -c "MPP scheduler request aborted because MPP init failed" "${log_file}" || true)"
      mpp_open_failed_count="$(grep -c "MPP open failed" "${log_file}" || true)"
      mpp_shim_open_failed_count="$(grep -c "MPP shim open failed" "${log_file}" || true)"
      mpp_disabled_sched_count="$(grep -c "HEADNODE scheduler requested but MPP remote-only mode is disabled" "${log_file}" || true)"
      mpp_bootstrap_ok_count="$(grep -Ec "\\[ior-mpp\\] libomptarget bootstrap completed devices=[1-9][0-9]*" "${log_file}" || true)"
      if (( mpp_init_fail_count > 0 || mpp_open_failed_count > 0 || mpp_shim_open_failed_count > 0 || mpp_shim_missing_count > 0 || mpp_disabled_sched_count > 0 || mpp_bootstrap_ok_count == 0 )); then
        echo "Error: OMPFILE+MPP strict mode failed for ${mode} repeat=${repeat_id}." >&2
        echo "  bootstrap_ok=${mpp_bootstrap_ok_count} init_fail=${mpp_init_fail_count} open_fail=${mpp_open_failed_count} shim_open_fail=${mpp_shim_open_failed_count} shim_missing=${mpp_shim_missing_count} sched_disabled=${mpp_disabled_sched_count}" >&2
        exit 1
      fi
    fi
  fi
  if [[ -z "${write_bw}" || -z "${read_bw}" || -z "${write_s}" || -z "${read_s}" ]]; then
    echo "Error: failed to parse summary metrics from ${log_file}" >&2
    exit 1
  fi

  printf "%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n" \
    "${mode}" "${repeat_id}" "${api}" "${backend}" \
    "${write_bw}" "${read_bw}" "${write_s}" "${read_s}" "${log_file}" \
    "${flightplan_state}" "${sched_fallback_count}" "${mpp_shim_missing_count}" >> "${SUMMARY_CSV}"
}

echo "[ior-backend-cmp] output dir: ${COMPARE_OUTDIR}"
echo "[ior-backend-cmp] modes: ${COMPARE_MODES_RAW}"
echo "[ior-backend-cmp] workload: tasks=${COMPARE_TASKS} block=${COMPARE_BLOCK_SIZE} xfer=${COMPARE_TRANSFER_SIZE} segments=${COMPARE_SEGMENTS} iter=${COMPARE_ITERATIONS} rw=${COMPARE_RW}"
echo "[ior-backend-cmp] runtime policy: ompfile_scheduler=${OMPFILE_SCHEDULER} ompfile_run_mpp=${OMPFILE_RUN_MPP} ompfile_require_mpp=${OMPFILE_REQUIRE_MPP}"
echo "[ior-backend-cmp] topology: this script launches IOR on all MPI ranks (no dedicated proxy ranks)."
if [[ "${OMPFILE_RUN_MPP}" == "0" ]]; then
  echo "[ior-backend-cmp] note: OMPFILE mode runs without remote-only MPP in this compare lane."
fi
if [[ "${OMPFILE_RUN_MPP}" == "1" ]]; then
  echo "[ior-backend-cmp] note: strict MPP mode is enabled for OMPFILE runs; failures in bootstrap/open/init will abort."
fi

IFS=',' read -r -a MODES <<< "${COMPARE_MODES_RAW}"
for raw_mode in "${MODES[@]}"; do
  mode="${raw_mode//[[:space:]]/}"
  mode="${mode^^}"
  if [[ -z "${mode}" ]]; then
    continue
  fi
  for ((repeat_id = 1; repeat_id <= COMPARE_REPEATS; ++repeat_id)); do
    run_case "${mode}" "${repeat_id}"
  done
done

echo
echo "[ior-backend-cmp] raw results: ${SUMMARY_CSV}"
echo "[ior-backend-cmp] per-mode average:"
awk -F',' '
  NR == 1 {next}
  {
    mode=$1
    write_bw[mode]+=$5
    read_bw[mode]+=$6
    write_s[mode]+=$7
    read_s[mode]+=$8
    count[mode]+=1
  }
  END {
    printf "%-16s %12s %12s %12s %12s %8s\n", "mode", "write_bw", "read_bw", "write_s", "read_s", "runs"
    for (mode in count) {
      printf "%-16s %12.2f %12.2f %12.6f %12.6f %8d\n",
             mode, write_bw[mode]/count[mode], read_bw[mode]/count[mode],
             write_s[mode]/count[mode], read_s[mode]/count[mode], count[mode]
    }
  }
' "${SUMMARY_CSV}" | { read -r header; echo "${header}"; sort; }

echo
echo "[ior-backend-cmp] speedup vs MPIIO (bandwidth ratio):"
awk -F',' '
  NR == 1 {next}
  {
    mode=$1
    write_bw[mode]+=$5
    read_bw[mode]+=$6
    count[mode]+=1
  }
  END {
    if (!count["MPIIO"]) {
      print "MPIIO baseline missing."
      exit 0
    }
    mpiio_write=write_bw["MPIIO"]/count["MPIIO"]
    mpiio_read=read_bw["MPIIO"]/count["MPIIO"]
    printf "%-16s %14s %14s %12s %12s\n", "mode", "write_speedup", "read_speedup", "write_delta", "read_delta"
    for (mode in count) {
      w=(write_bw[mode]/count[mode])/mpiio_write
      r=(read_bw[mode]/count[mode])/mpiio_read
      printf "%-16s %14.3fx %14.3fx %11.2f%% %11.2f%%\n",
             mode, w, r, (w-1.0)*100.0, (r-1.0)*100.0
    }
  }
' "${SUMMARY_CSV}" | { read -r header; echo "${header}"; sort; }

echo
echo "[ior-backend-cmp] flightplan diagnostics (HEADNODE stress path):"
awk -F',' '
  NR == 1 {next}
  {
    mode=$1
    state=$10
    fb=$11 + 0
    shim=$12 + 0
    fallback_total[mode]+=fb
    shim_missing_total[mode]+=shim
    count[mode]+=1
    state_count[mode SUBSEP state]+=1
  }
  END {
    printf "%-16s %14s %18s %10s\n", "mode", "avg_fallbacks", "avg_shim_missing", "runs"
    for (mode in count) {
      printf "%-16s %14.2f %18.2f %10d\n",
             mode,
             fallback_total[mode]/count[mode],
             shim_missing_total[mode]/count[mode],
             count[mode]
      for (k in state_count) {
        split(k, parts, SUBSEP)
        if (parts[1] == mode) {
          printf "  state=%s count=%d\n", parts[2], state_count[k]
        }
      }
    }
  }
' "${SUMMARY_CSV}"
