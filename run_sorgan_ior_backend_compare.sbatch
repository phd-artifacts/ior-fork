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

REPO_ROOT="${REPO_ROOT:-${PROJECT_ROOT:-/scratch/rodrigo.freitas/io-stage/src}}"
if [[ -n "${SIF_IMAGE:-}" && -e "${SIF_IMAGE}" ]]; then
  SIF_IMAGE="${SIF_IMAGE}"
elif [[ -e "${REPO_ROOT}/ompc-base_latest.sif" ]]; then
  SIF_IMAGE="${REPO_ROOT}/ompc-base_latest.sif"
elif [[ -e "${REPO_ROOT}/sifs/ompc-base_latest.sif" ]]; then
  SIF_IMAGE="${REPO_ROOT}/sifs/ompc-base_latest.sif"
elif [[ -n "${SIF_IMAGE:-}" ]]; then
  echo "Error: Apptainer image not found: ${SIF_IMAGE}" >&2
  exit 1
else
  echo "Error: Apptainer image not found in ${REPO_ROOT}/ompc-base_latest.sif or ${REPO_ROOT}/sifs/ompc-base_latest.sif" >&2
  exit 1
fi
APPTAINER_BIN="${APPTAINER_BIN:-/usr/bin/apptainer}"
LLVM_ROOT="${LLVM_ROOT:-${REPO_ROOT}/llvm-infra/llvm-builds/apptainer-Debug}"
LLVM_INSTALL_ROOT="${LLVM_INSTALL_ROOT:-${REPO_ROOT}/llvm-infra/llvm-installs/apptainer-Debug}"
IOR_DIR="${IOR_DIR:-${REPO_ROOT}/application/ior-fork}"
IOR_BIN="${IOR_BIN:-${IOR_DIR}/src/ior}"
COMPARE_SCRIPT="${COMPARE_SCRIPT:-${IOR_DIR}/run_backend_compare.sh}"
MPP_RUNNER="${MPP_RUNNER:-${IOR_DIR}/run_mpp_minimal.sh}"
OMPFILE_INC="${OMPFILE_INC:-${LLVM_INSTALL_ROOT}/include}"
OMPFILE_LIB="${OMPFILE_LIB:-${LLVM_ROOT}/runtimes/runtimes-bins/openmp/libompfile}"
OMP_RUNTIME_LIB="${OMP_RUNTIME_LIB:-${LLVM_ROOT}/runtimes/runtimes-bins/openmp/runtime/src}"
PROXY_BIN="${PROXY_BIN:-${LLVM_ROOT}/bin/llvm-offload-mpi-proxy-device}"

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

if [[ ! -e "${SIF_IMAGE}" ]]; then
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
if [[ ! -x "${MPP_RUNNER}" ]]; then
  echo "Error: MPP runner not found: ${MPP_RUNNER}" >&2
  exit 1
fi
if [[ ! -x "${PROXY_BIN}" ]]; then
  echo "Error: proxy binary not found: ${PROXY_BIN}" >&2
  exit 1
fi

case "${COMPARE_RW}" in
  rw)
    IO_FLAGS="-w -r"
    WRITE_ENABLED=1
    READ_ENABLED=1
    ;;
  read)
    IO_FLAGS="-r"
    WRITE_ENABLED=0
    READ_ENABLED=1
    ;;
  write)
    IO_FLAGS="-w"
    WRITE_ENABLED=1
    READ_ENABLED=0
    ;;
  *)
    echo "Error: IOR_COMPARE_RW must be one of: rw, read, write." >&2
    exit 1
    ;;
esac

MODE_LIST_COMPACT="${COMPARE_MODES_RAW//[[:space:]]/}"
MODE_LIST_CSV=",${MODE_LIST_COMPACT^^},"

COMMON_ENV="source ${REPO_ROOT}/sh-scripts/set_env.sh ${LLVM_ROOT} && \
export REPO_ROOT=${REPO_ROOT} && \
export LLVM_ROOT=${LLVM_ROOT} && \
export LLVM_INSTALL_ROOT=${LLVM_INSTALL_ROOT} && \
export PATH=/usr/local/mpich/bin:\${PATH} && \
export LD_LIBRARY_PATH=/usr/local/mpich/lib:${OMP_RUNTIME_LIB}:${OMPFILE_LIB}:${LLVM_ROOT}/lib:\${LD_LIBRARY_PATH:-}"

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

if [[ "${BUILD_IOR}" == "1" || ! -x "${IOR_BIN}" ]]; then
  echo "[ior-backend-cmp] building IOR"
  "${APPTAINER_BIN}" exec --userns --no-privs --bind "${REPO_ROOT}" "${SIF_IMAGE}" \
    bash -lc "${COMMON_ENV} && cd ${IOR_DIR} && CPPFLAGS='-I${OMPFILE_INC}' LDFLAGS='-L${OMPFILE_LIB}' ./bootstrap && ./configure CC='mpicc -std=gnu11 -D_GNU_SOURCE -D_POSIX_C_SOURCE=200809L' && make -j"
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
srun --kill-on-bad-exit=1 --mpi=pmi2 --nodes="${SLURM_JOB_NUM_NODES}" --ntasks="${COMPARE_TASKS}" /bin/hostname -s | sort -u | sed 's/^/[ior-backend-cmp] reached /'

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
  local prep_tasks="${COMPARE_TASKS}"
  local prep_nodes="${SLURM_JOB_NUM_NODES}"
  local prep_block_size="${COMPARE_BLOCK_SIZE}"

  if [[ "${mode}" == "OMPFILE_MPI" && "${OMPFILE_RUN_MPP}" == "1" ]]; then
    prep_tasks=1
    prep_nodes=1
    prep_block_size="$(scale_size_by_factor "${COMPARE_BLOCK_SIZE}" "${COMPARE_TASKS}")"
  fi

  echo "[ior-backend-cmp] preparing read input with MPIIO writer -> ${data_path} mode=${mode} prep_tasks=${prep_tasks} prep_nodes=${prep_nodes} prep_block=${prep_block_size}"
  srun --kill-on-bad-exit=1 --mpi=pmi2 --nodes="${prep_nodes}" --ntasks="${prep_tasks}" \
    "${APPTAINER_BIN}" exec --userns --no-privs --bind "${REPO_ROOT}" "${SIF_IMAGE}" \
    bash -lc "${COMMON_ENV} && cd ${IOR_DIR} && unset LIBOMPFILE_BACKEND LIBOMPFILE_SCHEDULER LIBOMPFILE_MPP_OPEN LIBOMPFILE_MPP_IO LIBOMPFILE_MPP_PING LIBOMPFILE_OPT_TWO_PHASE LIBOMPFILE_OPT_OPEN_CACHE LIBOMPFILE_OPT_OPEN_CACHE_KEEP_OPEN LIBOMPFILE_OPT_STATS UCX_TLS UCX_POSIX_USE_PROC_LINK; ${IOR_BIN} -a MPIIO -w -k -t ${COMPARE_TRANSFER_SIZE} -b ${prep_block_size} -s ${COMPARE_SEGMENTS} -i 1 -F -o ${data_path}" \
    > "${prep_log}" 2>&1
}

run_standard_case() {
  local mode_env_stmt="$1"
  local api="$2"
  local data_path="$3"
  local log_file="$4"

  srun --kill-on-bad-exit=1 --mpi=pmi2 --nodes="${SLURM_JOB_NUM_NODES}" --ntasks="${COMPARE_TASKS}" \
    "${APPTAINER_BIN}" exec --userns --no-privs --bind "${REPO_ROOT}" "${SIF_IMAGE}" \
    bash -lc "${COMMON_ENV} && cd ${IOR_DIR} && ${mode_env_stmt} ${IOR_BIN} -a ${api} ${IO_FLAGS} -t ${COMPARE_TRANSFER_SIZE} -b ${COMPARE_BLOCK_SIZE} -s ${COMPARE_SEGMENTS} -i ${COMPARE_ITERATIONS} -F -o ${data_path}" \
    > "${log_file}" 2>&1
}

run_ompfile_mpp_case() {
  local data_path="$1"
  local log_file="$2"
  local distributed_visible_ranks=$((COMPARE_TASKS - 1))
  local ompfile_block_size_bytes

  if (( distributed_visible_ranks < 1 )); then
    echo "Error: distributed OMPFILE+MPP compare requires at least 2 total MPI tasks." >&2
    exit 1
  fi

  ompfile_block_size_bytes="$(scale_size_by_factor "${COMPARE_BLOCK_SIZE}" "${COMPARE_TASKS}")"

  srun --kill-on-bad-exit=1 --mpi=pmi2 --nodes="${SLURM_JOB_NUM_NODES}" --ntasks="${COMPARE_TASKS}" \
    "${APPTAINER_BIN}" exec --userns --no-privs --bind "${REPO_ROOT}" "${SIF_IMAGE}" \
    bash -lc "${COMMON_ENV} && cd ${IOR_DIR} && \
      export IOR_BIN=${IOR_BIN} && \
      export PROXY_BIN=${PROXY_BIN} && \
      export APP_RANK=$((SLURM_NTASKS - 1)) && \
      export IOR_MPP_EXPECT_VISIBLE_DEVICES=${distributed_visible_ranks} && \
      export PROXY_EXIT_TIMEOUT_SEC=20 && \
      export LIBOMPFILE_BACKEND=MPI && \
      export LIBOMPFILE_SCHEDULER=${OMPFILE_SCHEDULER} && \
      export LIBOMPFILE_MPP_OPEN=1 && \
      export LIBOMPFILE_MPP_IO=1 && \
      export UCX_TLS=${UCX_TLS:-tcp,self} && \
      export UCX_POSIX_USE_PROC_LINK=${UCX_POSIX_USE_PROC_LINK:-n} && \
      export OMPFILE_EFFECTIVE_BLOCK_SIZE_BYTES=${ompfile_block_size_bytes} && \
      export OMPFILE_IOR_ARGS='-a OMPFILE ${IO_FLAGS} -t ${COMPARE_TRANSFER_SIZE} -b ${ompfile_block_size_bytes} -s ${COMPARE_SEGMENTS} -i ${COMPARE_ITERATIONS} -F -o ${data_path}' && \
      host_name=\$(hostname -s); \
      if [ \"\${SLURM_PROCID}\" -eq \$((SLURM_NTASKS - 1)) ]; then \
        echo \"[ior-backend-cmp][rank-map] rank=\${SLURM_PROCID} role=app host=\${host_name}\"; \
      else \
        echo \"[ior-backend-cmp][rank-map] rank=\${SLURM_PROCID} role=proxy host=\${host_name}\"; \
      fi; \
      bash ${MPP_RUNNER}" > "${log_file}" 2>&1
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
  local prep_log="${COMPARE_OUTDIR}/${lower_mode}-r${repeat_id}-prep.log"
  if [[ "${COMPARE_CLEAN_DATA}" == "1" ]]; then
    rm -f "${data_path}" "${data_path}".* "${prep_log}"
  fi

  if (( READ_ENABLED && ! WRITE_ENABLED )); then
    prepare_read_input "${data_path}" "${prep_log}" "${mode}"
  fi

  echo "[ior-backend-cmp] mode=${mode} repeat=${repeat_id} mpp=${mpp_enabled_for_case}"
  if [[ "${mode}" == "OMPFILE_MPI" && "${OMPFILE_RUN_MPP}" == "1" ]]; then
    run_ompfile_mpp_case "${data_path}" "${log_file}"
  else
    run_standard_case "${mode_env_stmt}" "${api}" "${data_path}" "${log_file}"
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
      visible_rank_match_count="$(grep -Ec "\\[ior-mpp\\] visible_distributed_ranks=$((COMPARE_TASKS - 1)) expected_visible=$((COMPARE_TASKS - 1))" "${log_file}" || true)"
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

echo "[ior-backend-cmp] output dir: ${COMPARE_OUTDIR}"
echo "[ior-backend-cmp] modes: ${COMPARE_MODES_RAW}"
echo "[ior-backend-cmp] workload: tasks=${COMPARE_TASKS} block=${COMPARE_BLOCK_SIZE} xfer=${COMPARE_TRANSFER_SIZE} segments=${COMPARE_SEGMENTS} iter=${COMPARE_ITERATIONS} rw=${COMPARE_RW}"
echo "[ior-backend-cmp] runtime policy: ompfile_scheduler=${OMPFILE_SCHEDULER} ompfile_run_mpp=${OMPFILE_RUN_MPP} ompfile_require_mpp=${OMPFILE_REQUIRE_MPP}"
if [[ "${MODE_LIST_CSV}" == *",OMPFILE_MPI,"* && "${OMPFILE_RUN_MPP}" == "1" ]]; then
  echo "[ior-backend-cmp] topology: MPIIO/POSIX run IOR on all ${COMPARE_TASKS} MPI ranks; OMPFILE+MPP runs 1 app rank + $((COMPARE_TASKS - 1)) proxy ranks in the same MPI_COMM_WORLD."
else
  echo "[ior-backend-cmp] topology: this script launches IOR on all MPI ranks (no dedicated proxy ranks)."
fi
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
if (( WRITE_ENABLED && READ_ENABLED )); then
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
elif (( READ_ENABLED )); then
  echo "[ior-backend-cmp] per-mode average (read-only):"
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
  echo "[ior-backend-cmp] per-mode average (write-only):"
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
elif (( READ_ENABLED )); then
  echo "[ior-backend-cmp] read speedup vs MPIIO (bandwidth ratio):"
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
  echo "[ior-backend-cmp] write speedup vs MPIIO (bandwidth ratio):"
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
