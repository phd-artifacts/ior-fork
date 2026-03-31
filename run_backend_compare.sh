#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-${PROJECT_ROOT:-/scratch/rodrigo.freitas/io-stage/src}}"
IOR_DIR="${IOR_DIR:-${REPO_ROOT}/application/ior-fork}"
LLVM_BUILD_ROOT="${LLVM_BUILD_ROOT:-${LLVM_ROOT:-${REPO_ROOT}/llvm-infra/llvm-builds/apptainer-Debug}}"
LLVM_INSTALL_ROOT="${LLVM_INSTALL_ROOT:-${LLVM_INSTALL_DIR:-${REPO_ROOT}/llvm-infra/llvm-installs/apptainer-Debug}}"
OMPFILE_INC="${OMPFILE_INC:-${LLVM_INSTALL_ROOT}/include}"
OMPFILE_LIB="${OMPFILE_LIB:-${LLVM_BUILD_ROOT}/runtimes/runtimes-bins/openmp/libompfile}"
OMP_RUNTIME_LIB="${OMP_RUNTIME_LIB:-${LLVM_BUILD_ROOT}/runtimes/runtimes-bins/openmp/runtime/src}"
IOR_BIN="${IOR_BIN:-${IOR_DIR}/src/ior}"
MPP_RUNNER="${MPP_RUNNER:-${IOR_DIR}/run_mpp_minimal.sh}"
PROXY_BIN="${PROXY_BIN:-${LLVM_BUILD_ROOT}/bin/llvm-offload-mpi-proxy-device}"

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

scale_size_by_factor() {
  local size_token_raw="$1"
  local factor="$2"
  local size_token="${size_token_raw,,}"
  local suffix="${size_token: -1}"
  local number_part="${size_token}"
  local multiplier=1

  case "${suffix}" in
    k)
      multiplier=1024
      number_part="${size_token%k}"
      ;;
    m)
      multiplier=$((1024 * 1024))
      number_part="${size_token%m}"
      ;;
    g)
      multiplier=$((1024 * 1024 * 1024))
      number_part="${size_token%g}"
      ;;
  esac

  if [[ ! "${number_part}" =~ ^[0-9]+$ ]]; then
    echo "Error: unsupported size token '${size_token_raw}'" >&2
    exit 1
  fi

  echo $((number_part * multiplier * factor))
}

size_token_to_bytes() {
  local size_token_raw="$1"
  scale_size_by_factor "${size_token_raw}" 1
}

validate_transfer_block_shape() {
  local transfer_bytes
  local block_bytes
  transfer_bytes="$(size_token_to_bytes "${COMPARE_TRANSFER_SIZE}")"
  block_bytes="$(size_token_to_bytes "${COMPARE_BLOCK_SIZE}")"

  if (( block_bytes < transfer_bytes )); then
    echo "Error: IOR_COMPARE_BLOCK_SIZE (${COMPARE_BLOCK_SIZE}) must be >= IOR_COMPARE_TRANSFER_SIZE (${COMPARE_TRANSFER_SIZE})." >&2
    exit 1
  fi
  if (( transfer_bytes == 0 || (block_bytes % transfer_bytes) != 0 )); then
    echo "Error: IOR_COMPARE_BLOCK_SIZE (${COMPARE_BLOCK_SIZE}) must be a multiple of IOR_COMPARE_TRANSFER_SIZE (${COMPARE_TRANSFER_SIZE})." >&2
    exit 1
  fi
}

validate_transfer_block_shape

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
if [[ ! -x "${MPP_RUNNER}" ]]; then
  echo "Error: expected MPP runner not found at ${MPP_RUNNER}" >&2
  exit 1
fi
if [[ ! -x "${PROXY_BIN}" ]]; then
  echo "Error: expected proxy binary not found at ${PROXY_BIN}" >&2
  exit 1
fi

mkdir -p "${COMPARE_OUTDIR}"

case "${COMPARE_RW}" in
  rw)
    IO_FLAGS=(-w -r)
    WRITE_ENABLED=1
    READ_ENABLED=1
    ;;
  read)
    IO_FLAGS=(-r)
    WRITE_ENABLED=0
    READ_ENABLED=1
    ;;
  write)
    IO_FLAGS=(-w)
    WRITE_ENABLED=1
    READ_ENABLED=0
    ;;
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

prepare_read_input() {
  local data_path="$1"
  local prep_log="$2"
  local mode="$3"
  local -a prep_env=(
    env
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

  local -a prep_cmd=("${MPI_LAUNCHER}" "${MPI_NP_OPTION}" "${COMPARE_NP}")
  local prep_block_size="${COMPARE_BLOCK_SIZE}"
  if [[ "${mode}" == "OMPFILE_MPI" && "${OMPFILE_RUN_MPP}" == "1" ]]; then
    prep_cmd=("${MPI_LAUNCHER}" "${MPI_NP_OPTION}" "1")
    prep_block_size="$(scale_size_by_factor "${COMPARE_BLOCK_SIZE}" "${COMPARE_NP}")"
  fi

  echo "[ior-compare] preparing read input with MPIIO writer -> ${data_path} mode=${mode} prep_np=${prep_cmd[2]} prep_block=${prep_block_size}"
  "${prep_env[@]}" "${prep_cmd[@]}" "${IOR_BIN}" \
    -a MPIIO \
    -w \
    -k \
    -t "${COMPARE_TRANSFER_SIZE}" \
    -b "${prep_block_size}" \
    -s "${COMPARE_SEGMENTS}" \
    -i 1 \
    -F \
    -o "${data_path}" > "${prep_log}" 2>&1
}

run_ompfile_mpp_case() {
  local data_path="$1"
  local log_file="$2"
  local distributed_visible_ranks=$((COMPARE_NP - 1))
  local ompfile_block_size_bytes

  if (( distributed_visible_ranks < 1 )); then
    echo "Error: distributed OMPFILE+MPP compare requires at least 2 total MPI tasks." >&2
    exit 1
  fi

  ompfile_block_size_bytes="$(scale_size_by_factor "${COMPARE_BLOCK_SIZE}" "${COMPARE_NP}")"

  env \
    IOR_BIN="${IOR_BIN}" \
    PROXY_BIN="${PROXY_BIN}" \
    APP_RANK="$((COMPARE_NP - 1))" \
    IOR_MPP_EXPECT_VISIBLE_DEVICES="${distributed_visible_ranks}" \
    PROXY_EXIT_TIMEOUT_SEC=20 \
    LIBOMPFILE_BACKEND="MPI" \
    LIBOMPFILE_SCHEDULER="${OMPFILE_SCHEDULER}" \
    LIBOMPFILE_MPP_OPEN=1 \
    LIBOMPFILE_MPP_IO=1 \
    UCX_TLS="${UCX_TLS:-tcp,self}" \
    UCX_POSIX_USE_PROC_LINK="${UCX_POSIX_USE_PROC_LINK:-n}" \
    OMPFILE_EFFECTIVE_BLOCK_SIZE_BYTES="${ompfile_block_size_bytes}" \
    OMPFILE_IOR_ARGS="-a OMPFILE ${IO_FLAGS[*]} -t ${COMPARE_TRANSFER_SIZE} -b ${ompfile_block_size_bytes} -s ${COMPARE_SEGMENTS} -i ${COMPARE_ITERATIONS} -F -o ${data_path}" \
    "${MPI_CMD[@]}" bash "${MPP_RUNNER}" > "${log_file}" 2>&1
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
  local prep_log="${COMPARE_OUTDIR}/${lower_mode}-r${repeat_id}-prep.log"
  if [[ "${COMPARE_CLEAN_DATA}" == "1" ]]; then
    rm -f "${data_path}" "${data_path}".* "${prep_log}"
  fi

  if (( READ_ENABLED && ! WRITE_ENABLED )); then
    prepare_read_input "${data_path}" "${prep_log}" "${mode}"
  fi

  echo "[ior-compare] mode=${mode} repeat=${repeat_id} launcher='${MPI_CMD[*]}' mpp=${mpp_enabled_for_case}"
  if [[ "${mode}" == "OMPFILE_MPI" && "${OMPFILE_RUN_MPP}" == "1" ]]; then
    run_ompfile_mpp_case "${data_path}" "${log_file}"
  else
    "${run_env[@]}" "${MPI_CMD[@]}" "${IOR_BIN}" \
      -a "${api}" \
      "${IO_FLAGS[@]}" \
      -t "${COMPARE_TRANSFER_SIZE}" \
      -b "${COMPARE_BLOCK_SIZE}" \
      -s "${COMPARE_SEGMENTS}" \
      -i "${COMPARE_ITERATIONS}" \
      -F \
      -o "${data_path}" > "${log_file}" 2>&1
  fi

  local write_bw
  local read_bw
  local write_s
  local read_s
  local flightplan_state="na"
  local sched_fallback_count=0
  local mpp_shim_missing_count=0
  if (( WRITE_ENABLED )); then
    write_bw="$(extract_summary_field "${log_file}" "write" 2)"
    write_s="$(extract_summary_field "${log_file}" "write" 10)"
  fi
  if (( READ_ENABLED )); then
    read_bw="$(extract_summary_field "${log_file}" "read" 2)"
    read_s="$(extract_summary_field "${log_file}" "read" 10)"
  fi

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
      local visible_rank_match_count
      local short_read_count
      local aggregate_warning_count
      mpp_init_fail_count="$(grep -c "MPP scheduler request aborted because MPP init failed" "${log_file}" || true)"
      mpp_open_failed_count="$(grep -c "MPP open failed" "${log_file}" || true)"
      mpp_shim_open_failed_count="$(grep -c "MPP shim open failed" "${log_file}" || true)"
      mpp_disabled_sched_count="$(grep -c "HEADNODE scheduler requested but MPP remote-only mode is disabled" "${log_file}" || true)"
      mpp_bootstrap_ok_count="$(grep -Ec "\\[ior-mpp\\] libomptarget bootstrap completed" "${log_file}" || true)"
      visible_rank_match_count="$(grep -Ec "\[ior-mpp\] visible_distributed_ranks=$((COMPARE_NP - 1)) expected_visible=$((COMPARE_NP - 1))" "${log_file}" || true)"
      short_read_count="$(grep -Ec "short_reads=[1-9][0-9]*" "${log_file}" || true)"
      aggregate_warning_count="$(grep -c "Expected aggregate file size" "${log_file}" || true)"
      if (( mpp_init_fail_count > 0 || mpp_open_failed_count > 0 || mpp_shim_open_failed_count > 0 || mpp_shim_missing_count > 0 || mpp_disabled_sched_count > 0 || mpp_bootstrap_ok_count == 0 || visible_rank_match_count == 0 || short_read_count > 0 || aggregate_warning_count > 0 )); then
        echo "Error: OMPFILE+MPP strict mode failed for ${mode} repeat=${repeat_id}." >&2
        echo "  bootstrap_ok=${mpp_bootstrap_ok_count} visible_match=${visible_rank_match_count} init_fail=${mpp_init_fail_count} open_fail=${mpp_open_failed_count} shim_open_fail=${mpp_shim_open_failed_count} shim_missing=${mpp_shim_missing_count} sched_disabled=${mpp_disabled_sched_count} short_reads=${short_read_count} aggregate_warnings=${aggregate_warning_count}" >&2
        exit 1
      fi
    fi
  fi

  if (( WRITE_ENABLED )) && [[ -z "${write_bw}" || -z "${write_s}" ]]; then
    echo "Error: failed to parse write summary metrics from ${log_file}" >&2
    exit 1
  fi
  if (( READ_ENABLED )) && [[ -z "${read_bw}" || -z "${read_s}" ]]; then
    echo "Error: failed to parse read summary metrics from ${log_file}" >&2
    exit 1
  fi

  if (( ! WRITE_ENABLED )); then
    write_bw=""
    write_s=""
  fi
  if (( ! READ_ENABLED )); then
    read_bw=""
    read_s=""
  fi

  if (( WRITE_ENABLED == 0 && READ_ENABLED == 0 )); then
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
if [[ "${MODE_LIST_CSV}" == *",OMPFILE_MPI,"* && "${OMPFILE_RUN_MPP}" == "1" ]]; then
  echo "[ior-compare] topology: MPIIO/POSIX run IOR on all ${COMPARE_NP} MPI ranks; OMPFILE+MPP runs 1 app rank + $((COMPARE_NP - 1)) proxy ranks in the same MPI_COMM_WORLD."
fi
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
if (( WRITE_ENABLED && READ_ENABLED )); then
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
elif (( READ_ENABLED )); then
  echo "[ior-compare] per-mode average (read-only):"
  awk -F',' '
    NR == 1 {next}
    {
      mode=$1
      read_bw[mode]+=$6
      read_s[mode]+=$8
      count[mode]+=1
    }
    END {
      printf "%-16s %12s %12s %8s\n", "mode", "read_bw", "read_s", "runs"
      for (mode in count) {
        printf "%-16s %12.2f %12.6f %8d\n",
               mode, read_bw[mode]/count[mode], read_s[mode]/count[mode], count[mode]
      }
    }
  ' "${SUMMARY_CSV}" | { read -r header; echo "${header}"; sort; }
else
  echo "[ior-compare] per-mode average (write-only):"
  awk -F',' '
    NR == 1 {next}
    {
      mode=$1
      write_bw[mode]+=$5
      write_s[mode]+=$7
      count[mode]+=1
    }
    END {
      printf "%-16s %12s %12s %8s\n", "mode", "write_bw", "write_s", "runs"
      for (mode in count) {
        printf "%-16s %12.2f %12.6f %8d\n",
               mode, write_bw[mode]/count[mode], write_s[mode]/count[mode], count[mode]
      }
    }
  ' "${SUMMARY_CSV}" | { read -r header; echo "${header}"; sort; }
fi

echo
if (( WRITE_ENABLED && READ_ENABLED )); then
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
elif (( READ_ENABLED )); then
  echo "[ior-compare] read speedup vs MPIIO (bandwidth ratio):"
  awk -F',' '
    NR == 1 {next}
    {
      mode=$1
      read_bw[mode]+=$6
      count[mode]+=1
    }
    END {
      if (!count["MPIIO"]) {
        print "MPIIO baseline missing."
        exit 0
      }
      mpiio_read=read_bw["MPIIO"]/count["MPIIO"]
      printf "%-16s %14s %12s\n", "mode", "read_speedup", "read_delta"
      for (mode in count) {
        r=(read_bw[mode]/count[mode])/mpiio_read
        printf "%-16s %14.3fx %11.2f%%\n", mode, r, (r-1.0)*100.0
      }
    }
  ' "${SUMMARY_CSV}" | { read -r header; echo "${header}"; sort; }
else
  echo "[ior-compare] write speedup vs MPIIO (bandwidth ratio):"
  awk -F',' '
    NR == 1 {next}
    {
      mode=$1
      write_bw[mode]+=$5
      count[mode]+=1
    }
    END {
      if (!count["MPIIO"]) {
        print "MPIIO baseline missing."
        exit 0
      }
      mpiio_write=write_bw["MPIIO"]/count["MPIIO"]
      printf "%-16s %14s %12s\n", "mode", "write_speedup", "write_delta"
      for (mode in count) {
        w=(write_bw[mode]/count[mode])/mpiio_write
        printf "%-16s %14.3fx %11.2f%%\n", mode, w, (w-1.0)*100.0
      }
    }
  ' "${SUMMARY_CSV}" | { read -r header; echo "${header}"; sort; }
fi

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
