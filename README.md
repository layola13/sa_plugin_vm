# Standalone Dynamic VM Interpreter Plugin (`sa_plugin_vm`)

This directory contains the standalone, dynamic interpreter virtual machine plugin (`sa_plugin_vm`) for SA.

By registering the `vm` subcommand via SA's dynamic command dispatch ABI (`saasm_plugin_descriptor_v1`), this plugin intercepts any `sa vm ...` calls. It recursively preprocesses, compiles to in-memory bytecode, and interprets SA assembly (`.sa` / `.sal`) files directly on the host OS, supporting internal subroutine recursion and dynamic FFI loading of external plugins without compile-time mainline compiler modifications.

---

## 1. Architectural Subsystems

```
[ sa vm run app.sa ]
       │ (Dispatched via Core Compiler CLI)
       ▼
[ sa_plugin_vm/src/plugin.zig (handle_command) ]
       │
       ├─► 1. Two-Pass Preprocess & Parse
       │      (Pre-scan all [MACRO]/#def, then expand EXPAND/imports)
       │
       ├─► 2. In-Memory bytecode IR compilation
       │      (Basic Block offsets & register mapping)
       │
       ├─► 3. Stack Frame Execution Loop
       │      │  (Linear stack-allocated frame tracker prevents memory leaks)
       │      ▼
       └─► 4. FFI Marshalling Bridge (POSIX dlopen/dlsym & AMD64 calling conventions)
```

### 1. Preprocessor & Two-Pass Macro Expander (`src/parser.zig`)

SA assembly utilizes `.sal` macro facades (e.g. `EXPAND DENO_HOSTNAME`) and `@import` directives. The parser runs a two-pass preprocessing pipeline:

1. **Pre-Scan (Pass 1)**: Scans all `[MACRO]` declarations and `#def` constants **before** expansion begins. This allows forward references — macros defined after the `EXPAND` call site are correctly resolved.
2. **Recursive Import Resolution**: `@import` statements are resolved relative to the active file directory or looked up inside the toolchain standard library root (`/home/vscode/.sa/std/`).
3. **Lexical Macro Extraction**: Parses `[MACRO]` declarations, extracting signature parameter tokens and lexical blocks.
4. **Collision-free Expansion**: When expanding `EXPAND`, tokens matching parameters are replaced with argument names. Local variables starting with `_` are uniquely renamed by appending a monotonic counter (e.g. `_mt_tag__sa_hyg1`) to guarantee that back-to-back macro expansions do not overwrite stack slots.
5. **Decoded Constants**: Multiple constant encodings are supported:
   - `utf8:"..."` — UTF-8 string with `\n`, `\t`, `\xNN` escape sequences
   - `struct { field: SIZE = hex:\xNN\xNN... }` — Binary struct literals decoded field-by-field
   - Automatic `NAME_len` companion constant for all string constants

### 2. Stack Frame & Interpreter Execution Engine (`src/vm.zig`)

- **Register Allocation**: Operands (registers, immediates, stack variables, offsets) are parsed, resolved, and stored in a type-safe `Val` union.
- **Correct Sign Extension**: `i8`, `i16`, `i32` loads are properly sign-extended to 64-bit, ensuring signed arithmetic (`sgt`, `slt`, `srem`) works correctly with negative values.
- **Threaded Instruction Loop**: A program counter (`pc`) advances through parsed basic block instructions. Control-flow branches (`br`, `jmp`) map directly to pre-calculated block indices.
- **Internal Subroutine Calls**: Internal user-defined subroutine calls are executed recursively by instantiating sub-frame registers and mapping parameters dynamically.
- **Linear Stack Safety**: Heap segments allocated via `stack_alloc` or `alloc` are tracked in a frame allocation array and deallocated in a `defer` block when the interpreted function returns.

### 3. Typed FFI Bridge & Plugin Loader (`src/ffi.zig`)

1. **Declared plugin loading**: Reads `sap.json` dependency names from the installed `vm` manifest and lazily `dlopen`s matching `lib<plugin_name>.so` artifacts from the installed plugin cache.
2. **Typed extern calls**: `@extern` declarations are parsed into signatures and dispatched through libffi with explicit primitive typing for `void`, integers, floats, and pointers.
3. **Gated raw libc FFI**: `dlopen`, `dlsym`, `dlclose`, and `dlerror` are only exposed when `sa vm run --allow-ffi` is used.
4. **Builtin shims**: `fd_*`, `mmap`, `signal`, `pthread_*`, `sqlite3_*`, and `sa_time_*` are provided as compatibility shims for the current demos and standard library surface.

---

## 2. Instruction Set Reference

### ✅ Supported Instructions

| Category | OpCode(s) | Syntax | Description |
|---|---|---|---|
| **Memory** | `stack_alloc`, `alloc` | `dest = alloc SIZE` | Allocate stack/heap buffer |
| **Memory** | `ptr_add` | `dest = ptr_add base, offset` | Pointer arithmetic |
| **Memory** | `load` | `dest = load addr+off as TYPE` | Typed load with sign extension |
| **Memory** | `store` | `store addr+off, val as TYPE` | Typed store |
| **Memory** | `atomic_load`, `atomic_store` | `dest = atomic_load addr as TYPE` | Atomic memory access |
| **Memory** | `cmpxchg` | `old, ok = cmpxchg addr, exp, new as TYPE` | Compare-and-swap |
| **Memory** | `atomic_rmw_add` | `old = atomic_rmw_add addr, val as TYPE` | Atomic fetch-and-add |
| **Memory** | `take` | `dest = take ptr` | Pointer-typed load (mirrors current native lowering) |
| **Arithmetic** | `add`, `sub`, `mul` | `dest = op a, b` | Integer arithmetic (wrapping) |
| **Arithmetic** | `div`, `rem` | `dest = op a, b` | Unsigned division/remainder |
| **Arithmetic** | `sdiv`, `udiv` | `dest = op a, b` | Signed/unsigned division |
| **Arithmetic** | `srem`, `urem` | `dest = op a, b` | Signed/unsigned remainder |
| **Bitwise** | `and`, `or`, `xor` | `dest = op a, b` | Bitwise operations |
| **Shifts** | `shl`, `shr` | `dest = op val, amount` | Shift left/right (masked to 63) |
| **Compare** | `eq`, `ne` | `dest = op a, b` | Equality |
| **Compare** | `gt`, `lt` | `dest = op a, b` | Unsigned greater/less than |
| **Compare** | `sgt`, `slt`, `sge`, `sle` | `dest = op a, b` | Signed comparisons |
| **Compare** | `ugt`, `ult`, `uge`, `ule` | `dest = op a, b` | Unsigned comparisons |
| **Cast** | `raw_cast` | `dest = raw_cast val as TYPE` | Reinterpret bits |
| **Control** | `br` | `br cond -> L_TRUE, L_FALSE` | Conditional branch |
| **Control** | `jmp` | `jmp L_DEST` | Unconditional jump |
| **Control** | `return` | `return [val]` | Function return |
| **Call** | `call` | `[dest =] call @fn(args...)` | Internal/FFI/builtin call |
| **Call** | `call_indirect` | `[dest =] call_indirect fn_ptr(args...)` | Function pointer call |
| **Ownership** | `!reg`, `^reg` | `!reg` | Consume/drop register (no-op) |
| **Error** | `?reg` | (try semantics) | Check Result tag, propagate error |
| **Macro** | `EXPAND NAME args...` | `EXPAND MACRO_NAME arg1, arg2` | Inline macro expansion |
| **Const** | `@const NAME = utf8:"..."` | — | UTF-8 string constant |
| **Const** | `@const NAME = struct { f: N = hex:\xNN }` | — | Binary struct constant |
| **Def** | `#def NAME = VALUE` | — | Compile-time text substitution |
| **Macro** | `[MACRO] NAME %p1, %p2 ... [END_MACRO]` | — | Macro definition (forward refs OK) |
| **Repeat** | `[REP N] ... [END_REP]` | — | Loop unrolling |

### Still Out of Scope

The VM is a **pure SA bytecode interpreter** running in a sandboxed environment. The following features require **native compilation** and are intentionally outside scope:

| Category | Examples | Reason |
|---|---|---|
| **Inline Assembly** | `inline_assembly` | Platform-specific assembly (`asm volatile`) is not interpretable. |
| **SIMD Intrinsics** | (architecture-specific) | CPU vector intrinsics require native code generation. |
| **Multi-binary packages** | `pkg_bin_multiple` | Multiple entry point package builds require the full SA compiler toolchain. |

> **Note**: Older whitepaper/script references are stale. The current source tree is the authority for supported behavior.

---

## 3. Test Coverage

Run the local regression suite and a VM smoke test:

```bash
# Build plugin tests
zig build test

# Build release plugin
zig build -Doptimize=ReleaseFast

# Run a simple VM smoke test
SA_PLUGIN_DEV=1 SA_PLUGINS_PATH="$PWD/zig-out/lib" sa vm run tests/hello_world.sa
```

Representative external compatibility check used during current work:

| Status | Count | Notes |
|---|---|---|
| ✅ PASS | 35/35 | `/home/vscode/projects/TheAlgorithms/Sa/tests/*.sa` under `sa vm test` |
| ✅ PASS | 4/4 | `bench_search.sa`, `bench_bst_1000.sa`, `bench_merge.sa`, `bench_sorting.sa` ran without VM crashes |

This repository also includes regression fixtures for `@test` fallback mode and dead pure instruction elimination under [`tests/`](</home/vscode/projects/sa_plugins/sa_plugin_vm/tests>).

---

## 4. Build, Install, and Verify

### Build
```bash
cd sa_plugin_vm
zig build -Doptimize=ReleaseFast
```

### Install
```bash
zig build -Doptimize=ReleaseFast
```

### Verify
```bash
sa plugin list
sa vm run /path/to/demo/main.sa
sa vm test /path/to/tests.sa
```

---

## 5. Known Remaining Limitations

- `panic` / `panic_msg` instructions print `PANIC` / `PANIC[code]` and terminate with the SA-compatible exit code `128 + (code & 0x7f)`, but they still do not print a backtrace.
- `f32`/`f64` floating-point arithmetic is still represented as raw bits internally; floating-point comparisons are not a supported execution path yet.
- The thread model is synchronous inside the VM. It is sufficient for the current demos and benchmarks, but it is not a host-level pthread scheduler.
