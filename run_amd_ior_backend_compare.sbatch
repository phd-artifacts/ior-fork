#!/bin/bash
#SBATCH --job-name=amd-ior-backend-cmp
#SBATCH --partition=mi2104x
#SBATCH --nodes=4
#SBATCH --ntasks=4
#SBATCH --ntasks-per-node=1
#SBATCH --time=00:45:00
#SBATCH --output=%x-%j.out

# AMD IOR backend compare — same lane semantics as the sorgan wrapper
# (run_sorgan_ior_backend_compare.sbatch): MPIIO/POSIX SPMD baselines vs the
# split-role OMPFILE+MPP lane (1 app rank + N-1 proxies, block size scaled by
# tasks for aggregate-byte matching). Launch mechanics follow the AMD HACC-IO
# lane: ranks run inside the container via a role script, srun --mpi=pmix,
# host spack MPICH override (container MPICH's PMIx client silently
# singletons on this cluster — jobs 350109-350170), PMIx server tmpdir bind.

set -euo pipefail

module purge 2>/dev/null || true
module load hpcfund 2>/dev/null || true

PROJECT_NAME="${PROJECT_NAME:-io-playground}"
if [[ -z "${PROJECT_ROOT:-}" ]]; then
  if [[ -z "${WORK:-}" ]]; then
    echo "Error: set PROJECT_ROOT or ensure WORK is exported by the cluster environment." >&2
    exit 1
  fi
  PROJECT_ROOT="${WORK}/projects/${PROJECT_NAME}"
fi
REPO_ROOT="${REPO_ROOT:-${PROJECT_ROOT}/src}"
IOR_DIR="${IOR_DIR:-${REPO_ROOT}/application/ior-fork}"
IOR_BIN="${IOR_BIN:-${IOR_DIR}/src/ior}"
MPP_RUNNER="${MPP_RUNNER:-${IOR_DIR}/run_mpp_minimal.sh}"
LLVM_ROOT_REMOTE="${LLVM_ROOT_REMOTE:-${PROJECT_ROOT}/llvm-infra/llvm-builds/apptainer-Debug}"
BUILD_ROOT_REMOTE="${BUILD_ROOT_REMOTE:-${PROJECT_ROOT}/builds/latest/gfx90a}"
CONTAINER_IMAGE="${CONTAINER_IMAGE:-${REPO_ROOT}/sifs/ompc-base_latest.sif}"
if [[ ! -e "${CONTAINER_IMAGE}" ]]; then
  CONTAINER_IMAGE="${REPO_ROOT}/ompc-base_latest.sif"
fi
PROXY_BIN="${PROXY_BIN:-}"
if [[ -z "${PROXY_BIN}" ]]; then
  if [[ -x "${BUILD_ROOT_REMOTE}/bin/llvm-offload-mpi-proxy-device" ]]; then
    PROXY_BIN="${BUILD_ROOT_REMOTE}/bin/llvm-offload-mpi-proxy-device"
  else
    PROXY_BIN="${LLVM_ROOT_REMOTE}/bin/llvm-offload-mpi-proxy-device"
  fi
fi
OMPFILE_INC="${OMPFILE_INC:-${LLVM_ROOT_REMOTE}/include}"
OMPFILE_LIB="${OMPFILE_LIB:-}"
if [[ -z "${OMPFILE_LIB}" ]]; then
  if [[ -e "${LLVM_ROOT_REMOTE}/runtimes/runtimes-bins/openmp/libompfile/libompfile.so" ]]; then
    OMPFILE_LIB="${LLVM_ROOT_REMOTE}/runtimes/runtimes-bins/openmp/libompfile"
  else
    OMPFILE_LIB="${LLVM_ROOT_REMOTE}/lib"
  fi
fi

COMPARE_MODES_RAW="${IOR_COMPARE_MODES:-MPIIO,POSIX,OMPFILE_MPI}"
COMPARE_REPEATS="${IOR_COMPARE_REPEATS:-1}"
COMPARE_BLOCK_SIZE="${IOR_COMPARE_BLOCK_SIZE:-128m}"
COMPARE_TRANSFER_SIZE="${IOR_COMPARE_TRANSFER_SIZE:-4m}"
COMPARE_SEGMENTS="${IOR_COMPARE_SEGMENTS:-8}"
COMPARE_ITERATIONS="${IOR_COMPARE_ITERATIONS:-1}"
COMPARE_RW="${IOR_COMPARE_RW:-rw}"
COMPARE_TASKS="${IOR_COMPARE_TASKS:-${SLURM_NTASKS}}"
COMPARE_OUTDIR="${IOR_COMPARE_OUTDIR:-${IOR_DIR}/tmp/backend-compare-amd-${SLURM_JOB_ID}}"
COMPARE_CLEAN_DATA="${IOR_COMPARE_CLEAN_DATA:-1}"
BUILD_IOR="${BUILD_IOR:-1}"
OMPFILE_SCHEDULER="${IOR_OMPFILE_SCHEDULER:-${LIBOMPFILE_SCHEDULER:-HEADNODE}}"
OMPFILE_WRITETHROUGH_FSYNC_POLICY="${IOR_OMPFILE_WRITETHROUGH_FSYNC_POLICY:-${LIBOMPFILE_WRITETHROUGH_FSYNC_POLICY:-each}}"
OMPFILE_RUN_MPP="${IOR_OMPFILE_RUN_MPP:-1}"
OMPFILE_REQUIRE_MPP="${IOR_OMPFILE_REQUIRE_MPP:-1}"
RUN_MPI_TYPE="${RUN_MPI_TYPE:-pmix}"

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
if [[ ! -e "${CONTAINER_IMAGE}" ]]; then
  echo "Error: Apptainer image not found under ${REPO_ROOT}" >&2
  exit 1
fi
if [[ ! -x "${PROXY_BIN}" ]]; then
  echo "Error: proxy binary not found: ${PROXY_BIN}" >&2
  exit 1
fi
if [[ ! -x "${MPP_RUNNER}" ]]; then
  echo "Error: MPP runner not found: ${MPP_RUNNER}" >&2
  exit 1
fi

case "${COMPARE_RW}" in
  rw)
    IO_FLAGS="-w -r"
    WRITE_ENABLED=1
    READ_ENABLED=1
    ;;
  read)
    # The sorgan lane preps read-only input with a separate MPIIO writer;
    # this lane measures write+read (or write) in one pass instead.
    echo "Error: IOR_COMPARE_RW=read is not supported by the AMD lane; use rw." >&2
    exit 1
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

# IOR_DATA_CHECK=1 enables IOR's data verification passes (-W re-reads and
# checks after the write phase, -R checks read data against the written
# pattern). IOR reports the check phases separately, so write/read bandwidth
# numbers stay comparable with non-checked runs.
IOR_DATA_CHECK="${IOR_DATA_CHECK:-0}"
IOR_FSYNC="${IOR_FSYNC:-0}"
if [[ ! "${IOR_FSYNC}" =~ ^[01]$ ]]; then
  echo "Error: IOR_FSYNC must be 0 or 1, got '${IOR_FSYNC}'." >&2
  exit 1
fi
if [[ "${IOR_DATA_CHECK}" == "1" ]]; then
  (( WRITE_ENABLED )) && IO_FLAGS="${IO_FLAGS} -W"
  (( READ_ENABLED )) && IO_FLAGS="${IO_FLAGS} -R"
fi
if [[ "${IOR_FSYNC}" == "1" ]]; then
  IO_FLAGS="${IO_FLAGS} -e"
fi

# Layout posture: IOR_SHARED=1 drops -F (one shared file, ranks interleaved by
# segment layout); IOR_REORDER=1 adds -C (reorderTasks: each rank reads the
# block another rank wrote — the standard client-cache-defeating posture).
IOR_SHARED="${IOR_SHARED:-0}"
IOR_REORDER="${IOR_REORDER:-0}"
LAYOUT_FLAGS="-F"
if [[ "${IOR_SHARED}" == "1" ]]; then
  LAYOUT_FLAGS=""
fi
if [[ "${IOR_REORDER}" == "1" ]]; then
  LAYOUT_FLAGS="${LAYOUT_FLAGS} -C"
fi

# Host spack MPICH (pmi=pmix, cluster-matched) — required for every rank so
# the PMIx client inside the container can bootstrap (see OOC lane notes).
SPACK_ROOT="${SPACK_ROOT:-${HOME}/spack}"
MPICH_ROOT=""
if [[ -f "${SPACK_ROOT}/share/spack/setup-env.sh" ]]; then
  # shellcheck disable=SC1091
  . "${SPACK_ROOT}/share/spack/setup-env.sh" 2>/dev/null || true
  MPICH_ROOT="$(spack location -i mpich@4.2.3 2>/dev/null || true)"
fi
if [[ ! -d "${MPICH_ROOT}" ]]; then
  echo "Error: spack mpich@4.2.3 not found; host-MPI override unavailable." >&2
  exit 1
fi
MPI_LIB_OVERRIDE="${MPICH_ROOT}/lib"

scale_size_by_factor() {
  local size_token_raw="$1"
  local factor="$2"
  local size_token="${size_token_raw,,}"
  local suffix="${size_token: -1}"
  local number_part="${size_token}"
  local multiplier=1

  case "${suffix}" in
    k) multiplier=1024; number_part="${size_token%?}" ;;
    m) multiplier=$((1024 * 1024)); number_part="${size_token%?}" ;;
    g) multiplier=$((1024 * 1024 * 1024)); number_part="${size_token%?}" ;;
    [0-9]) multiplier=1 ;;
    *)
      echo "Error: unsupported size token '${size_token_raw}'." >&2
      exit 1
      ;;
  esac
  if [[ ! "${number_part}" =~ ^[0-9]+$ ]]; then
    echo "Error: unsupported size token '${size_token_raw}'." >&2
    exit 1
  fi
  echo $((number_part * multiplier * factor))
}

size_token_to_bytes() {
  scale_size_by_factor "$1" 1
}

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

mkdir -p "${COMPARE_OUTDIR}"

in_container_build() {
  local binds="${PROJECT_ROOT},${REPO_ROOT},${HOME}"
  [[ -d /work1 ]] && binds="${binds},/work1"
  # unset CPATH: set_env.sh adds the repo clang's builtin resource headers
  # (lib/clang/<N>/include) to CPATH for the repo toolchain, but mpicc wraps
  # the container's system clang — resolving another clang's stdint.h via
  # CPATH breaks its include_next chain (unknown uint16_t/int64_t). The only
  # header IOR needs from the repo tree is file_interface.h, passed via -I.
  APPTAINER_DISABLE_CACHE=1 apptainer exec --userns --no-privs --bind "${binds}" "${CONTAINER_IMAGE}" \
    /bin/bash -lc "source '${REPO_ROOT}/sh-scripts/set_env.sh' '${LLVM_ROOT_REMOTE}' >/dev/null && unset CPATH && export PATH=/usr/local/mpich/bin:\${PATH} && cd '${IOR_DIR}' && ./bootstrap && ./configure CC='mpicc -std=gnu11 -D_GNU_SOURCE -D_POSIX_C_SOURCE=200809L' CPPFLAGS='-I${OMPFILE_INC}' LDFLAGS='-L${OMPFILE_LIB}' && make -j"
}

if [[ "${BUILD_IOR}" == "1" || ! -x "${IOR_BIN}" ]]; then
  echo "[amd-ior-cmp] building IOR (container configure/make)"
  in_container_build
fi
if [[ ! -x "${IOR_BIN}" ]]; then
  echo "Error: IOR binary not found after build: ${IOR_BIN}" >&2
  exit 1
fi

SUMMARY_CSV="${COMPARE_OUTDIR}/summary.csv"
cat > "${SUMMARY_CSV}" <<'EOF'
mode,repeat,api,libompfile_backend,write_bw_mib_s,read_bw_mib_s,write_mean_s,read_mean_s,log_file,flightplan_state,sched_fallback_count,mpp_shim_missing_count
EOF

echo "[amd-ior-cmp] allocated nodes: ${SLURM_JOB_NODELIST}"
# srun rejects --nodes greater than --ntasks: clamp so a lane can run fewer
# ranks than the allocation has nodes (e.g. 9 writers on a 10-node job).
SRUN_NODES=$(( COMPARE_TASKS < SLURM_JOB_NUM_NODES ? COMPARE_TASKS : SLURM_JOB_NUM_NODES ))
SRUN_PLACEMENT=(--nodes="${SRUN_NODES}" --ntasks="${COMPARE_TASKS}")
if (( SRUN_NODES == COMPARE_TASKS )); then
  SRUN_PLACEMENT+=(--ntasks-per-node=1)
else
  SRUN_PLACEMENT+=(--distribution=block:block)
fi
echo "[amd-ior-cmp] workload: tasks=${COMPARE_TASKS} block=${COMPARE_BLOCK_SIZE} xfer=${COMPARE_TRANSFER_SIZE} segments=${COMPARE_SEGMENTS} iter=${COMPARE_ITERATIONS} rw=${COMPARE_RW}"
echo "[amd-ior-cmp] runtime policy: scheduler=${OMPFILE_SCHEDULER} run_mpp=${OMPFILE_RUN_MPP} require_mpp=${OMPFILE_REQUIRE_MPP} ompfile_fsync_policy=${OMPFILE_WRITETHROUGH_FSYNC_POLICY} ior_fsync=${IOR_FSYNC}"

# Role script: every rank re-enters the container with the PMIx server bind
# and the host-MPI lib override, then execs its target helper. Modeled on
# application/hacc-io-fork/run_amd_hacc_io_compare.sbatch.
write_role_script() { # path env_stmt role_case
  local role_path="$1" env_stmt="$2" role_case="$3"
  cat > "${role_path}" <<EOF
#!/usr/bin/env bash
set -euo pipefail
${env_stmt}

run_in_container() {
  local target_bin="\$1"
  local binds="${PROJECT_ROOT}:${PROJECT_ROOT},${REPO_ROOT}:${REPO_ROOT},${COMPARE_OUTDIR}:${COMPARE_OUTDIR},/tmp:/tmp,/dev/shm:/dev/shm"
  if [[ -d /work1 ]]; then binds="\${binds},/work1:/work1"; fi
  if [[ -n "\${PMIX_SERVER_TMPDIR:-}" ]]; then
    pmix_dir="\$(dirname "\${PMIX_SERVER_TMPDIR}")"
    if [[ -d "\${pmix_dir}" ]]; then binds="\${binds},\${pmix_dir}:\${pmix_dir}"; fi
  elif [[ -d /var/spool/slurmd ]]; then
    binds="\${binds},/var/spool/slurmd:/var/spool/slurmd"
  fi
  if [[ -d "\${HOME}" ]]; then binds="\${binds},\${HOME}:\${HOME}"; fi
  if [[ -d /opt ]]; then binds="\${binds},/opt:/opt"; fi
  APPTAINER_DISABLE_CACHE=1 exec apptainer exec \\
    --userns --no-privs \\
    --bind "\${binds}" \\
    "${CONTAINER_IMAGE}" \\
    /bin/bash -lc "source \"${REPO_ROOT}/sh-scripts/set_env.sh\" \"${LLVM_ROOT_REMOTE}\" >/dev/null && export LLVM_BUILD_DIR=\"${LLVM_ROOT_REMOTE}\" LLVM_INSTALL_DIR=\"${LLVM_ROOT_REMOTE}\" LLVM_ROOT=\"${LLVM_ROOT_REMOTE}\" && export LD_LIBRARY_PATH=\"${MPI_LIB_OVERRIDE}:\\\${LD_LIBRARY_PATH}\"; exec \"\${target_bin}\""
}

${role_case}
EOF
  chmod +x "${role_path}"
}

extract_summary_field() {
  local log_file="$1"
  local op="$2"
  local col="$3"
  awk -v op="${op}" -v col="${col}" '
    /^Summary of all tests:/ {in_summary=1; next}
    in_summary && $1 == op {print $col; exit}
  ' "${log_file}"
}

run_standard_case() { # tag mode_env_stmt api data_path log_file
  local tag="$1" mode_env_stmt="$2" api="$3" data_path="$4" log_file="$5"
  local role_path="${COMPARE_OUTDIR}/role-${tag}.sh"
  cat > "${COMPARE_OUTDIR}/exec-${tag}.sh" <<EOF
#!/usr/bin/env bash
cd "${IOR_DIR}"
exec "${IOR_BIN}" -a ${api} ${IO_FLAGS} -t ${COMPARE_TRANSFER_SIZE} -b ${COMPARE_BLOCK_SIZE} -s ${COMPARE_SEGMENTS} -i ${COMPARE_ITERATIONS} ${LAYOUT_FLAGS} -o "${data_path}"
EOF
  chmod +x "${COMPARE_OUTDIR}/exec-${tag}.sh"
  write_role_script "${role_path}" \
    "${mode_env_stmt}" \
    "run_in_container \"${COMPARE_OUTDIR}/exec-${tag}.sh\""
  srun --kill-on-bad-exit=1 --mpi="${RUN_MPI_TYPE}" "${SRUN_PLACEMENT[@]}" \
    "${role_path}" > "${log_file}" 2>&1
}

run_ompfile_mpp_case() { # tag data_path log_file
  local tag="$1" data_path="$2" log_file="$3"
  local role_path="${COMPARE_OUTDIR}/role-${tag}.sh"
  local distributed_visible_ranks=$((COMPARE_TASKS - 1))
  local ompfile_block_size_bytes
  local libomptarget_so=""

  if (( distributed_visible_ranks < 1 )); then
    echo "Error: distributed OMPFILE+MPP compare requires at least 2 total MPI tasks." >&2
    exit 1
  fi
  ompfile_block_size_bytes="$(scale_size_by_factor "${COMPARE_BLOCK_SIZE}" "${COMPARE_TASKS}")"
  libomptarget_so="$(compgen -G "${LLVM_ROOT_REMOTE}/lib/libomptarget.so.*git" | head -1 || true)"

  cat > "${COMPARE_OUTDIR}/exec-${tag}.sh" <<EOF
#!/usr/bin/env bash
cd "${IOR_DIR}"
exec bash "${MPP_RUNNER}"
EOF
  chmod +x "${COMPARE_OUTDIR}/exec-${tag}.sh"
  write_role_script "${role_path}" \
    "export REPO_ROOT=${REPO_ROOT}
export LLVM_ROOT=${LLVM_ROOT_REMOTE}
export IOR_BIN=${IOR_BIN}
export PROXY_BIN=${PROXY_BIN}
export LIBOMPTARGET_SO=${libomptarget_so:-/nonexistent}
export OMP_RUNTIME_LIB=${LLVM_ROOT_REMOTE}/lib
export APP_RANK=$((COMPARE_TASKS - 1))
export IOR_MPP_EXPECT_VISIBLE_DEVICES=${distributed_visible_ranks}
export PROXY_EXIT_TIMEOUT_SEC=${IOR_PROXY_EXIT_TIMEOUT_SEC:-60}
export OMP_TARGET_OFFLOAD=MANDATORY
export OMPTARGET_DISABLE_HOST_PLUGIN=1
export LIBOMPFILE_BACKEND=MPI
export LIBOMPFILE_SCHEDULER=${OMPFILE_SCHEDULER}
export LIBOMPFILE_MPP_OPEN=1
export LIBOMPFILE_MPP_IO=1
export LIBOMPFILE_WRITETHROUGH_FSYNC_POLICY=${OMPFILE_WRITETHROUGH_FSYNC_POLICY}
export UCX_TLS=\${UCX_TLS:-all}
export UCX_POSIX_USE_PROC_LINK=\${UCX_POSIX_USE_PROC_LINK:-n}
export OMPFILE_EFFECTIVE_BLOCK_SIZE_BYTES=${ompfile_block_size_bytes}
export OMPFILE_IOR_ARGS='-a OMPFILE ${IO_FLAGS} -t ${COMPARE_TRANSFER_SIZE} -b ${ompfile_block_size_bytes} -s ${COMPARE_SEGMENTS} -i ${COMPARE_ITERATIONS} -F -o ${data_path}'" \
    "if [[ \"\${SLURM_PROCID}\" -eq \$((SLURM_NTASKS - 1)) ]]; then
  echo \"[amd-ior-cmp][rank-map] rank=\${SLURM_PROCID} role=app host=\$(hostname -s)\"
else
  echo \"[amd-ior-cmp][rank-map] rank=\${SLURM_PROCID} role=proxy host=\$(hostname -s)\"
fi
run_in_container \"${COMPARE_OUTDIR}/exec-${tag}.sh\""
  srun --kill-on-bad-exit=1 --mpi="${RUN_MPI_TYPE}" "${SRUN_PLACEMENT[@]}" \
    "${role_path}" > "${log_file}" 2>&1
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
      mode_env_stmt="unset LIBOMPFILE_BACKEND LIBOMPFILE_SCHEDULER LIBOMPFILE_MPP_OPEN LIBOMPFILE_MPP_IO LIBOMPFILE_MPP_PING LIBOMPFILE_OPT_STATS UCX_TLS UCX_POSIX_USE_PROC_LINK 2>/dev/null || true"
      ;;
    POSIX)
      api="POSIX"
      backend="na"
      mode_env_stmt="unset LIBOMPFILE_BACKEND LIBOMPFILE_SCHEDULER LIBOMPFILE_MPP_OPEN LIBOMPFILE_MPP_IO LIBOMPFILE_MPP_PING LIBOMPFILE_OPT_STATS UCX_TLS UCX_POSIX_USE_PROC_LINK 2>/dev/null || true"
      ;;
    OMPFILE_MPI)
      api="OMPFILE"
      backend="MPI"
      if [[ "${OMPFILE_RUN_MPP}" != "1" ]]; then
        echo "Error: the AMD lane only supports OMPFILE_MPI with IOR_OMPFILE_RUN_MPP=1." >&2
        exit 1
      fi
      mpp_enabled_for_case=1
      ;;
    *)
      echo "Error: unsupported mode '${mode}' in IOR_COMPARE_MODES (AMD lane supports MPIIO,POSIX,OMPFILE_MPI)." >&2
      exit 1
      ;;
  esac

  local lower_mode="${mode,,}"
  local tag="${lower_mode}-r${repeat_id}"
  local data_path="${COMPARE_OUTDIR}/${tag}.dat"
  local log_file="${COMPARE_OUTDIR}/${tag}.log"
  if [[ "${COMPARE_CLEAN_DATA}" == "1" ]]; then
    rm -f "${data_path}" "${data_path}".*
  fi

  echo "[amd-ior-cmp] mode=${mode} repeat=${repeat_id} mpp=${mpp_enabled_for_case}"
  if (( mpp_enabled_for_case )); then
    run_ompfile_mpp_case "${tag}" "${data_path}" "${log_file}" || {
      echo "Error: mode ${mode} repeat=${repeat_id} failed" >&2
      tail -n 60 "${log_file}" >&2
      exit 1
    }
  else
    run_standard_case "${tag}" "${mode_env_stmt}" "${api}" "${data_path}" "${log_file}" || {
      echo "Error: mode ${mode} repeat=${repeat_id} failed" >&2
      tail -n 60 "${log_file}" >&2
      exit 1
    }
  fi

  if [[ "${IOR_DATA_CHECK}" == "1" ]] && grep -qiE "incorrect data|data check error" "${log_file}"; then
    echo "Error: IOR data check reported errors for mode ${mode} repeat=${repeat_id}" >&2
    grep -iE "incorrect data|data check error" "${log_file}" | head >&2
    exit 1
  fi

  local write_bw=""
  local read_bw=""
  local write_s=""
  local read_s=""
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
      local aggregate_short_count
      mpp_init_fail_count="$(grep -c "MPP scheduler request aborted because MPP init failed" "${log_file}" || true)"
      mpp_open_failed_count="$(grep -c "MPP open failed" "${log_file}" || true)"
      mpp_shim_open_failed_count="$(grep -c "MPP shim open failed" "${log_file}" || true)"
      mpp_disabled_sched_count="$(grep -c "HEADNODE scheduler requested but MPP remote-only mode is disabled" "${log_file}" || true)"
      mpp_bootstrap_ok_count="$(grep -Ec "\\[ior-mpp\\] libomptarget bootstrap completed" "${log_file}" || true)"
      visible_rank_match_count="$(grep -Ec "\\[ior-mpp\\] visible_distributed_ranks=$((COMPARE_TASKS - 1)) expected_visible=$((COMPARE_TASKS - 1))" "${log_file}" || true)"
      short_read_count="$(grep -Ec "short_reads=[1-9][0-9]*" "${log_file}" || true)"
      aggregate_warning_count="$(grep -c "Expected aggregate file size" "${log_file}" || true)"
      # On NFS the app-side stat can lag split-role writes issued from other
      # nodes (stale attribute cache reports size 0) while IOR confirms every
      # byte moved. Only treat the warning as fatal when the actual bytes
      # moved differ from the expected aggregate.
      aggregate_short_count="$(awk '
        /Expected aggregate file size/ {expv=$NF; have=1}
        /Using actual aggregate bytes moved/ {if (have && $NF+0 != expv+0) bad++; have=0}
        END {print bad+0}' "${log_file}")"
      local remote_only_open_count
      remote_only_open_count="$(grep -c "Remote-only open completed" "${log_file}" || true)"
      # Planned MPP open can transiently fail on a write-first flow (the
      # planned open carries no O_CREAT, so it ENOENTs before the file
      # exists) and fall back to the default open path — the run is still
      # remote-only MPP as long as a remote-only open completed. Only treat
      # open failures as fatal when no remote-only open ever completed.
      if (( (mpp_open_failed_count > 0 || mpp_shim_open_failed_count > 0) && remote_only_open_count > 0 )); then
        echo "[ior-cmp] warning: planned MPP open fell back (open_fail=${mpp_open_failed_count} shim_open_fail=${mpp_shim_open_failed_count}) but remote-only open completed (${remote_only_open_count}); continuing."
      fi
      if (( mpp_init_fail_count > 0 || ((mpp_open_failed_count > 0 || mpp_shim_open_failed_count > 0) && remote_only_open_count == 0) || mpp_shim_missing_count > 0 || mpp_disabled_sched_count > 0 || mpp_bootstrap_ok_count == 0 || visible_rank_match_count == 0 || short_read_count > 0 || aggregate_short_count > 0 )); then
        echo "Error: OMPFILE+MPP strict mode failed for ${mode} repeat=${repeat_id}." >&2
        echo "  bootstrap_ok=${mpp_bootstrap_ok_count} visible_match=${visible_rank_match_count} init_fail=${mpp_init_fail_count} open_fail=${mpp_open_failed_count} shim_open_fail=${mpp_shim_open_failed_count} shim_missing=${mpp_shim_missing_count} sched_disabled=${mpp_disabled_sched_count} short_reads=${short_read_count} aggregate_warnings=${aggregate_warning_count} aggregate_short=${aggregate_short_count}" >&2
        tail -n 60 "${log_file}" >&2
        exit 1
      fi
    fi
  fi
  if (( WRITE_ENABLED )) && [[ -z "${write_bw}" || -z "${write_s}" ]]; then
    echo "Error: failed to parse write summary metrics from ${log_file}" >&2
    tail -n 40 "${log_file}" >&2
    exit 1
  fi
  if (( READ_ENABLED )) && [[ -z "${read_bw}" || -z "${read_s}" ]]; then
    echo "Error: failed to parse read summary metrics from ${log_file}" >&2
    tail -n 40 "${log_file}" >&2
    exit 1
  fi

  printf "%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n" \
    "${mode}" "${repeat_id}" "${api}" "${backend}" \
    "${write_bw}" "${read_bw}" "${write_s}" "${read_s}" "${log_file}" \
    "${flightplan_state}" "${sched_fallback_count}" "${mpp_shim_missing_count}" >> "${SUMMARY_CSV}"

  if [[ "${COMPARE_CLEAN_DATA}" == "1" ]]; then
    rm -f "${data_path}" "${data_path}".*
  fi
}

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

echo "[amd-ior-cmp] raw results: ${SUMMARY_CSV}"
cat "${SUMMARY_CSV}"
echo "[amd-ior-cmp] status=PASS summary_csv=${SUMMARY_CSV}"
