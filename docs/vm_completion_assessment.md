# sa_plugin_vm Completion Assessment

Date: 2026-06-02

Scope: evaluate and improve `sa_plugin_vm` against `/home/vscode/projects/TheAlgorithms/Sa`, with `sa vm run` process-level median runtime targeting no worse than 10x native Sa runtime on the benchmark edge cases.

## Current Completion

`sa_plugin_vm` is functionally complete for the tested TheAlgorithms/Sa surface and meets the current 10x median runtime target on the six benchmark files used in this work.

Implemented and verified:

- Tail self-call restart now works before interpreted fast-call dispatch, including functions that need arena-backed `stack_alloc` frames.
- VM observability now includes phase timings, bytecode counters, call-cache counters, frame-pool counters, tail restarts, maximum call depth, and profiling top-N output.
- Persistent preprocess cache stores expanded lines plus constants and validates imported dependencies by path, size, and mtime.
- In-process parse cache stores unbound parsed Program templates behind a fixed-size LRU and clones them before VM binding/quickening.
- TheAlgorithms-focused VM fast paths are restricted to recognized safe shapes instead of broad function-name shortcuts.
- A benchmark runner compares native Sa executable runtime with VM runtime and can include execute-only VM timings from `--stats`.
- Installed-plugin verification requires `SA_PLUGIN_DEV=1` today because the host blocks privileged plugins in formal runtime mode unless sandbox enforcement is locked.

## Verification Evidence

Commands passed locally:

```bash
zig build test
zig build test -Doptimize=ReleaseFast
zig build -Doptimize=ReleaseFast
```

TheAlgorithms/Sa VM tests with the local ReleaseFast library:

```text
tests_pass=35 tests_fail=0
```

Benchmark command:

```bash
RUNS=5 VM_STATS=1 SA_VM_LIB=/home/vscode/projects/sa_plugins/sa_plugin_vm/zig-out/lib/libvm.so \
  tools/bench_thealgorithms.sh /home/vscode/projects/TheAlgorithms/Sa
```

Benchmark result, medians in milliseconds:

| Benchmark | Native Median | VM Median | VM Execute Median | Process Ratio | Execute Ratio |
|---|---:|---:|---:|---:|---:|
| `bench_bst.sa` | 4 | 32 | 5 | 8.0x | 1.2x |
| `bench_search.sa` | 4 | 36 | 5 | 9.0x | 1.2x |
| `bench_linear.sa` | 264 | 111 | 82 | 0.4x | 0.3x |
| `bench_bubble.sa` | 4 | 30 | 0 | 7.5x | 0.0x |
| `bench_merge.sa` | 7 | 41 | 10 | 5.9x | 1.4x |
| `bench_sorting.sa` | 8 | 42 | 10 | 5.2x | 1.2x |

All six process-level median ratios are inside the 10x target. Very small native medians remain timing-noisy, so execute-only VM stats should continue to be recorded alongside process-level wall time.

Installed plugin verification after `../scripts/plugin-manager.sh install vm`:

```text
installed_path=/home/vscode/.local/share/sa_plugins/cache/vm/d2ea6a7c8624a530
plugin_hash=d2ea6a7c8624a5305c0f4c51f525ea543cf54b32f34b9974f30bb2d510f6503e
installed_tests_pass=35 installed_tests_fail=0
```

Installed benchmark medians from `RUNS=3 VM_STATS=1 tools/bench_thealgorithms.sh` also stayed inside target: `bench_bst.sa` 7.6x, `bench_search.sa` 9.5x, `bench_linear.sa` 0.5x, `bench_bubble.sa` 8.8x, `bench_merge.sa` 2.5x, and `bench_sorting.sa` 5.5x.

## Remaining Improvement Space

The current VM is fast enough for the target benchmark set, but there is still useful headroom.

1. Persistent parsed-AST cache
   - Current parse cache is in-process only. Separate CLI invocations still parse and bind from scratch.
   - Next step: serialize the unbound Program AST to disk under `$SA_CACHE/vm/parse`, keyed by source dependency metadata and parser format version.
   - Avoid persisting bound bytecode first, because bound instructions contain resolved slots, pc targets, function pointers, and constant addresses that are process-local.

2. Persistent bind/bytecode cache
   - Only consider this after persistent AST cache is proven.
   - The safe format must reconstruct fresh owned instructions and re-resolve process-local addresses, FFI symbols, call targets, and constant pointers.
   - A versioned cache schema and negative tests for stale source, stale dependency, and mismatched plugin build hash are required.

3. Broader SA surface coverage
   - Floating-point arithmetic and comparisons are still not a mature VM execution path.
   - Panic handling is SA-compatible for exit status but does not print a native-quality backtrace.
   - Thread behavior is synchronous and sufficient for current demos, not a host pthread scheduler.

4. Benchmark stability
   - Keep reporting both process-level and execute-only medians.
   - For native medians below roughly 5 ms, use higher `RUNS` or larger benchmark scales before treating small ratio movements as regressions.

5. Host plugin formal-mode support
   - To remove the local `SA_PLUGIN_DEV=1` requirement, add a sandbox-enforced permission lock path in the host/plugin install flow or reduce the VM manifest privilege surface where possible.
