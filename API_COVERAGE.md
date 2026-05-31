# VM Plugin API Coverage

`sa_plugin_vm` is a CLI-only plugin. It exposes the `sa vm run <file.sa>` command through
`saasm_plugin_descriptor_v1`; it does not publish SA-facing `.sai` or `.sal` externs of its own.

## Runtime Surface

- Parses `.sa` and `.sal` files, resolves recursive imports, expands `[MACRO]` and `[REP]`, and decodes `@const utf8:"..."` byte constants.
- Interprets the core SA-ASM instructions used by the integration tests: allocation, pointer arithmetic, load/store, arithmetic, comparisons, branch/jump, direct calls, indirect calls, consume hints, panic, and return.
- Provides builtin handlers for `sa_print_bytes` and the `sa_time_*` functions used by the standard library tests.
- Loads FFI providers only from dependencies declared in `sap.json`; this avoids accidentally exposing every installed plugin through global `dlsym`.

## Permissions

The VM is a trusted local runtime plugin. Its manifest declares the filesystem, network, environment, and process permissions needed by the VM smoke tests and by declared FFI dependencies. These declarations make capability use auditable, but they are not syscall-level sandboxing.

If stricter production isolation is required, the host must enforce plugin execution through a broker or worker sandbox.

## FFI Dependencies

The manifest currently declares optional dependencies for:

- `http-client`: outbound HTTP smoke symbols.
- `deno`: Deno compatibility smoke symbols.
- `node`: Node compatibility smoke symbols, including timers.

Missing optional dependencies do not prevent VM core execution, but calls to their symbols fail with `SymbolNotFound`.
