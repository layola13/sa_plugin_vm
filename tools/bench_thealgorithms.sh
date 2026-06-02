#!/usr/bin/env bash
set -euo pipefail

SA_ROOT="${1:-${THEALGORITHMS_SA:-$HOME/projects/TheAlgorithms/Sa}}"
RUNS="${RUNS:-3}"
VM_LIB="${SA_VM_LIB:-}"
VM_STATS="${VM_STATS:-0}"
BENCHMARKS="${BENCHMARKS:-bench_bst.sa bench_search.sa bench_linear.sa bench_bubble.sa bench_merge.sa bench_sorting.sa}"

if [[ ! -d "$SA_ROOT" ]]; then
  printf 'error: TheAlgorithms/Sa directory not found: %s\n' "$SA_ROOT" >&2
  exit 1
fi

if [[ "$RUNS" -le 0 ]]; then
  printf 'error: RUNS must be positive\n' >&2
  exit 1
fi

if [[ -n "$VM_LIB" ]]; then
  export SA_PLUGIN_DEV=1
  export SA_PLUGINS_PATH="$VM_LIB"
  PLUGIN_PATH="$VM_LIB"
else
  export SA_PLUGIN_DEV="${SA_PLUGIN_DEV:-1}"
  PLUGIN_PATH="${SA_PLUGINS_HOME:-$HOME/.local/share/sa_plugins}/installed/vm/current/libvm.so"
fi

PLUGIN_HASH="missing"
if [[ -f "$PLUGIN_PATH" ]]; then
  PLUGIN_HASH="$(sha256sum "$PLUGIN_PATH" | awk '{print $1}')"
fi

tmpdir="$(mktemp -d /tmp/sa-vm-bench.XXXXXX)"
trap 'rm -rf "$tmpdir"' EXIT

median_ms() {
  printf '%s\n' "$@" | sort -n | awk '
    { values[NR] = $1 }
    END {
      if (NR == 0) { print 0; exit }
      mid = int((NR + 1) / 2)
      if (NR % 2 == 1) print values[mid]
      else print int((values[mid] + values[mid + 1]) / 2)
    }'
}

printf 'sa_root=%s\n' "$SA_ROOT"
printf 'runs=%s\n' "$RUNS"
printf 'plugin_path=%s\n' "$PLUGIN_PATH"
printf 'plugin_hash=%s\n' "$PLUGIN_HASH"
printf 'vm_stats=%s\n' "$VM_STATS"
if [[ "$VM_STATS" == 1 ]]; then
  printf 'benchmark\tnative_mean_ms\tnative_median_ms\tvm_mean_ms\tvm_median_ms\tvm_execute_mean_ms\tvm_execute_median_ms\tratio_mean\tratio_median\tratio_execute_median\tnative_status\tvm_status\n'
else
  printf 'benchmark\tnative_mean_ms\tnative_median_ms\tvm_mean_ms\tvm_median_ms\tratio_mean\tratio_median\tnative_status\tvm_status\n'
fi

for bench in $BENCHMARKS; do
  src="$SA_ROOT/$bench"
  exe="$tmpdir/${bench%.sa}"
  if [[ ! -f "$src" ]]; then
    if [[ "$VM_STATS" == 1 ]]; then
      printf '%s\tmissing\tmissing\tmissing\tmissing\tmissing\tmissing\tmissing\tmissing\tmissing\tmissing\tmissing\n' "$bench"
    else
      printf '%s\tmissing\tmissing\tmissing\tmissing\tmissing\tmissing\tmissing\tmissing\n' "$bench"
    fi
    continue
  fi

  if ! sa build-exe "$src" -o "$exe" >"$tmpdir/native-build.out" 2>"$tmpdir/native-build.err"; then
    if [[ "$VM_STATS" == 1 ]]; then
      printf '%s\tcompile_failed\tcompile_failed\tcompile_failed\tcompile_failed\tcompile_failed\tcompile_failed\tcompile_failed\tcompile_failed\tcompile_failed\tcompile_failed\tcompile_failed\n' "$bench"
    else
      printf '%s\tcompile_failed\tcompile_failed\tcompile_failed\tcompile_failed\tcompile_failed\tcompile_failed\tcompile_failed\tcompile_failed\n' "$bench"
    fi
    sed -n '1,80p' "$tmpdir/native-build.err" >&2
    continue
  fi

  native_sum=0
  vm_sum=0
  native_times=()
  vm_times=()
  vm_execute_sum=0
  vm_execute_times=()
  native_status=0
  vm_status=0

  for ((run = 1; run <= RUNS; run += 1)); do
    start="$(date +%s%N)"
    set +e
    "$exe" >"$tmpdir/native-run.out" 2>"$tmpdir/native-run.err"
    native_status=$?
    set -e
    end="$(date +%s%N)"
    native_ms=$(((end - start) / 1000000))
    native_sum=$((native_sum + native_ms))
    native_times+=("$native_ms")

    start="$(date +%s%N)"
    set +e
    if [[ "$VM_STATS" == 1 ]]; then
      sa vm run --stats "$src" >"$tmpdir/vm-run.out" 2>"$tmpdir/vm-run.err"
    else
      sa vm run "$src" >"$tmpdir/vm-run.out" 2>"$tmpdir/vm-run.err"
    fi
    vm_status=$?
    set -e
    end="$(date +%s%N)"
    vm_ms=$(((end - start) / 1000000))
    vm_sum=$((vm_sum + vm_ms))
    vm_times+=("$vm_ms")
    if [[ "$VM_STATS" == 1 ]]; then
      execute_ms="$(awk -F= '/execute_ns=/ { gsub(/ /, "", $2); printf "%d", $2 / 1000000; exit }' "$tmpdir/vm-run.err")"
      execute_ms="${execute_ms:-0}"
      vm_execute_sum=$((vm_execute_sum + execute_ms))
      vm_execute_times+=("$execute_ms")
    fi
  done

  native_mean=$((native_sum / RUNS))
  vm_mean=$((vm_sum / RUNS))
  native_median="$(median_ms "${native_times[@]}")"
  vm_median="$(median_ms "${vm_times[@]}")"
  ratio_mean="$(awk -v v="$vm_mean" -v n="$native_mean" 'BEGIN { if (n == 0) printf "inf"; else printf "%.1f", v / n }')"
  ratio_median="$(awk -v v="$vm_median" -v n="$native_median" 'BEGIN { if (n == 0) printf "inf"; else printf "%.1f", v / n }')"
  if [[ "$VM_STATS" == 1 ]]; then
    vm_execute_mean=$((vm_execute_sum / RUNS))
    vm_execute_median="$(median_ms "${vm_execute_times[@]}")"
    ratio_execute_median="$(awk -v v="$vm_execute_median" -v n="$native_median" 'BEGIN { if (n == 0) printf "inf"; else printf "%.1f", v / n }')"
    printf '%s\t%d\t%s\t%d\t%s\t%d\t%s\t%s\t%s\t%s\t%d\t%d\n' "$bench" "$native_mean" "$native_median" "$vm_mean" "$vm_median" "$vm_execute_mean" "$vm_execute_median" "$ratio_mean" "$ratio_median" "$ratio_execute_median" "$native_status" "$vm_status"
  else
    printf '%s\t%d\t%s\t%d\t%s\t%s\t%s\t%d\t%d\n' "$bench" "$native_mean" "$native_median" "$vm_mean" "$vm_median" "$ratio_mean" "$ratio_median" "$native_status" "$vm_status"
  fi
done
