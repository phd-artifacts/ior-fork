#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-/scratch/rodrigo.freitas/io-playground}"
IOR_DIR="${IOR_DIR:-${REPO_ROOT}/application/ior-fork}"
LLVM_BUILD_ROOT="${LLVM_BUILD_ROOT:-${LLVM_ROOT:-${REPO_ROOT}/llvm-infra/llvm-builds/apptainer-Debug}}"
LLVM_INSTALL_ROOT="${LLVM_INSTALL_ROOT:-${LLVM_INSTALL_DIR:-${REPO_ROOT}/llvm-infra/llvm-installs/apptainer-Debug}}"
OMPFILE_INC="${OMPFILE_INC:-${LLVM_INSTALL_ROOT}/include}"
OMPFILE_LIB="${OMPFILE_LIB:-${LLVM_BUILD_ROOT}/runtimes/runtimes-bins/openmp/libompfile}"
OMP_RUNTIME_LIB="${OMP_RUNTIME_LIB:-${LLVM_BUILD_ROOT}/runtimes/runtimes-bins/openmp/runtime/src}"
IOR_BIN="${IOR_BIN:-${IOR_DIR}/src/ior}"

COMPARE_MODES_RAW="${IOR_COMPARE_MODES:-MPIIO,POSIX,OMPFILE_MPI}"
COMPARE_REPEATS="${IOR_COMPARE_REPEATS:-3}"
COMPARE_NP="${IOR_COMPARE_NP:-1}"
COMPARE_BLOCK_SIZE="${IOR_COMPARE_BLOCK_SIZE:-4m}"
COMPARE_TRANSFER_SIZE="${IOR_COMPARE_TRANSFER_SIZE:-256k}"
COMPARE_SEGMENTS="${IOR_COMPARE_SEGMENTS:-8}"
COMPARE_ITERATIONS="${IOR_COMPARE_ITERATIONS:-1}"
COMPARE_RW="${IOR_COMPARE_RW:-rw}"
COMPARE_OUTDIR="${IOR_COMPARE_OUTDIR:-${IOR_DIR}/tmp/backend-compare}"
COMPARE_CLEAN_DATA="${IOR_COMPARE_CLEAN_DATA:-1}"
BUILD_IOR="${BUILD_IOR:-0}"
SKIP_COMPILE="${SKIP_COMPILE:-0}"
MPI_LAUNCHER="${IOR_MPI_LAUNCHER:-mpirun}"
MPI_NP_OPTION="${IOR_MPI_NP_OPTION:--n}"
MPI_EXTRA_ARGS_RAW="${IOR_MPI_EXTRA_ARGS:-}"
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
assert_positive_int "${COMPARE_NP}" "IOR_COMPARE_NP"
assert_positive_int "${COMPARE_SEGMENTS}" "IOR_COMPARE_SEGMENTS"
assert_positive_int "${COMPARE_ITERATIONS}" "IOR_COMPARE_ITERATIONS"
if [[ ! "${OMPFILE_RUN_MPP}" =~ ^[01]$ ]]; then
  echo "Error: IOR_OMPFILE_RUN_MPP must be 0 or 1, got '${OMPFILE_RUN_MPP}'." >&2
  exit 1
fi
if [[ ! "${OMPFILE_REQUIRE_MPP}" =~ ^[01]$ ]]; then
  echo "Error: IOR_OMPFILE_REQUIRE_MPP must be 0 or 1, got '${OMPFILE_REQUIRE_MPP}'." >&2
  exit 1
fi

if [[ ! -d "${IOR_DIR}" ]]; then
  echo "Error: IOR_DIR does not exist: ${IOR_DIR}" >&2
  exit 1
fi
if [[ ! -d "${LLVM_BUILD_ROOT}" ]]; then
  echo "Error: LLVM build root does not exist: ${LLVM_BUILD_ROOT}" >&2
  exit 1
fi

source "${REPO_ROOT}/sh-scripts/set_env.sh" "${LLVM_BUILD_ROOT}"
export PATH="/usr/local/mpich/bin:${PATH}"
export LD_LIBRARY_PATH="/usr/local/mpich/lib:${OMP_RUNTIME_LIB}:${OMPFILE_LIB}:${LLVM_BUILD_ROOT}/lib:${LD_LIBRARY_PATH:-}"
MODE_LIST_COMPACT="${COMPARE_MODES_RAW//[[:space:]]/}"
MODE_LIST_CSV=",${MODE_LIST_COMPACT^^},"

if [[ "${BUILD_IOR}" == "1" || "${SKIP_COMPILE}" != "1" || ! -x "${IOR_BIN}" ]]; then
  pushd "${IOR_DIR}" >/dev/null
  if [[ ! -x "${IOR_BIN}" || "${BUILD_IOR}" == "1" ]]; then
    echo "[ior-compare] building IOR (configure + make)"
    source "${REPO_ROOT}/sh-scripts/register_mpi_clang.sh"
    CPPFLAGS="-I${OMPFILE_INC}" LDFLAGS="-L${OMPFILE_LIB}" ./configure CC=mpi_clang >/dev/null
    make -j >/dev/null
  fi
  popd >/dev/null
fi

if [[ ! -x "${IOR_BIN}" ]]; then
  echo "Error: expected IOR binary not found at ${IOR_BIN}" >&2
  exit 1
fi

mkdir -p "${COMPARE_OUTDIR}"

case "${COMPARE_RW}" in
  rw) IO_FLAGS=(-w -r) ;;
  read) IO_FLAGS=(-r) ;;
  write) IO_FLAGS=(-w) ;;
  *)
    echo "Error: IOR_COMPARE_RW must be one of: rw, read, write." >&2
    exit 1
    ;;
esac

IFS=',' read -r -a MODES <<< "${COMPARE_MODES_RAW}"
read -r -a MPI_EXTRA_ARR <<< "${MPI_EXTRA_ARGS_RAW}"
MPI_CMD=("${MPI_LAUNCHER}" "${MPI_NP_OPTION}" "${COMPARE_NP}" "${MPI_EXTRA_ARR[@]}")
SUMMARY_CSV="${COMPARE_OUTDIR}/summary.csv"

cat > "${SUMMARY_CSV}" <<'EOF'
mode,repeat,api,libompfile_backend,write_bw_mib_s,read_bw_mib_s,write_mean_s,read_mean_s,log_file,flightplan_state,sched_fallback_count,mpp_shim_missing_count
EOF

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
  local mpp_enabled_for_case=0
  local -a run_env=(env)

  case "${mode}" in
    MPIIO)
      api="MPIIO"
      run_env+=(
        -u LIBOMPFILE_BACKEND
        -u LIBOMPFILE_SCHEDULER
        -u LIBOMPFILE_MPP_OPEN
        -u LIBOMPFILE_MPP_IO
        -u LIBOMPFILE_MPP_PING
        -u LIBOMPFILE_OPT_TWO_PHASE
        -u LIBOMPFILE_OPT_OPEN_CACHE
        -u LIBOMPFILE_OPT_OPEN_CACHE_KEEP_OPEN
        -u LIBOMPFILE_OPT_STATS
        -u UCX_TLS
        -u UCX_POSIX_USE_PROC_LINK
      )
      ;;
    POSIX)
      api="POSIX"
      run_env+=(
        -u LIBOMPFILE_BACKEND
        -u LIBOMPFILE_SCHEDULER
        -u LIBOMPFILE_MPP_OPEN
        -u LIBOMPFILE_MPP_IO
        -u LIBOMPFILE_MPP_PING
        -u LIBOMPFILE_OPT_TWO_PHASE
        -u LIBOMPFILE_OPT_OPEN_CACHE
        -u LIBOMPFILE_OPT_OPEN_CACHE_KEEP_OPEN
        -u LIBOMPFILE_OPT_STATS
        -u UCX_TLS
        -u UCX_POSIX_USE_PROC_LINK
      )
      ;;
    OMPFILE_MPI)
      api="OMPFILE"
      backend="MPI"
      run_env+=(
        LIBOMPFILE_BACKEND="MPI"
        LIBOMPFILE_SCHEDULER="${OMPFILE_SCHEDULER}"
        UCX_TLS="${UCX_TLS:-tcp,self}"
        UCX_POSIX_USE_PROC_LINK="${UCX_POSIX_USE_PROC_LINK:-n}"
      )
      if [[ "${OMPFILE_RUN_MPP}" == "1" ]]; then
        run_env+=(LIBOMPFILE_MPP_OPEN=1 LIBOMPFILE_MPP_IO=1)
        mpp_enabled_for_case=1
      else
        run_env+=(LIBOMPFILE_MPP_OPEN=0 LIBOMPFILE_MPP_IO=0)
      fi
      ;;
    OMPFILE_POSIX)
      api="OMPFILE"
      backend="POSIX"
      run_env+=(
        LIBOMPFILE_BACKEND="POSIX"
        -u LIBOMPFILE_SCHEDULER
        -u LIBOMPFILE_MPP_OPEN
        -u LIBOMPFILE_MPP_IO
        -u LIBOMPFILE_MPP_PING
        -u UCX_TLS
        -u UCX_POSIX_USE_PROC_LINK
      )
      ;;
    OMPFILE_IO_URING)
      api="OMPFILE"
      backend="IO_URING"
      run_env+=(
        LIBOMPFILE_BACKEND="IO_URING"
        -u LIBOMPFILE_SCHEDULER
        -u LIBOMPFILE_MPP_OPEN
        -u LIBOMPFILE_MPP_IO
        -u LIBOMPFILE_MPP_PING
        -u UCX_TLS
        -u UCX_POSIX_USE_PROC_LINK
      )
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

  echo "[ior-compare] mode=${mode} repeat=${repeat_id} launcher='${MPI_CMD[*]}' mpp=${mpp_enabled_for_case}"
  "${run_env[@]}" "${MPI_CMD[@]}" "${IOR_BIN}" \
    -a "${api}" \
    "${IO_FLAGS[@]}" \
    -t "${COMPARE_TRANSFER_SIZE}" \
    -b "${COMPARE_BLOCK_SIZE}" \
    -s "${COMPARE_SEGMENTS}" \
    -i "${COMPARE_ITERATIONS}" \
    -F \
    -o "${data_path}" > "${log_file}" 2>&1

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

echo "[ior-compare] output dir: ${COMPARE_OUTDIR}"
echo "[ior-compare] modes: ${COMPARE_MODES_RAW}"
echo "[ior-compare] workload: np=${COMPARE_NP} block=${COMPARE_BLOCK_SIZE} xfer=${COMPARE_TRANSFER_SIZE} segments=${COMPARE_SEGMENTS} iter=${COMPARE_ITERATIONS} rw=${COMPARE_RW}"
echo "[ior-compare] runtime policy: ompfile_scheduler=${OMPFILE_SCHEDULER} ompfile_run_mpp=${OMPFILE_RUN_MPP} ompfile_require_mpp=${OMPFILE_REQUIRE_MPP}"
if [[ "${MODE_LIST_CSV}" == *",OMPFILE_MPI,"* && "${OMPFILE_RUN_MPP}" == "0" ]]; then
  echo "[ior-compare] note: OMPFILE mode runs without remote-only MPP in this compare lane."
fi
if [[ "${MODE_LIST_CSV}" == *",OMPFILE_MPI,"* && "${OMPFILE_RUN_MPP}" == "1" ]]; then
  echo "[ior-compare] note: strict MPP mode is enabled for OMPFILE runs; failures in bootstrap/open/init will abort."
fi

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
echo "[ior-compare] raw results: ${SUMMARY_CSV}"
echo "[ior-compare] per-mode average:"
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
echo "[ior-compare] speedup vs MPIIO (bandwidth ratio):"
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
echo "[ior-compare] flightplan diagnostics (HEADNODE stress path):"
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
