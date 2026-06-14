#ifndef WAMR_H
#define WAMR_H

#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef void* wasm_module_inst_t;
typedef void* wasm_module_t;
typedef void* wasm_exec_env_t;
typedef void* wasm_function_inst_t;

typedef enum {
    WASM_I32 = 0,
    WASM_I64 = 1,
    WASM_F32 = 2,
    WASM_F64 = 3,
} wasm_valkind_t;

typedef struct {
    wasm_valkind_t kind;
    union {
        int32_t i32;
        int64_t i64;
        float f32;
        double f64;
    } of;
} wasm_val_t;

#define WASM_F64 ((wasm_valkind_t)3)

bool wasm_runtime_init(void);
void wasm_runtime_destroy(void);
bool wasm_runtime_init_thread_env(void);
void wasm_runtime_destroy_thread_env(void);

wasm_module_t wasm_runtime_load(const uint8_t* buffer, uint32_t size, char* error_buf, uint32_t error_buf_size);
void wasm_runtime_unload(wasm_module_t module);

wasm_module_inst_t wasm_runtime_instantiate(wasm_module_t module, uint32_t stack_size, uint32_t heap_size, char* error_buf, uint32_t error_buf_size);
void wasm_runtime_deinstantiate(wasm_module_inst_t inst);

void wasm_runtime_set_wasi_args(wasm_module_t module, void* dir_list, uint32_t dir_count, void* env_list, uint32_t env_count, void* argv_list, uint32_t argc, const char* stdio_path, const char* preopened_dir);

wasm_exec_env_t wasm_runtime_create_exec_env(wasm_module_inst_t inst, uint32_t stack_size);
void wasm_runtime_destroy_exec_env(wasm_exec_env_t exec_env);

wasm_function_inst_t wasm_runtime_lookup_function(wasm_module_inst_t inst, const char* name);
bool wasm_runtime_call_wasm(wasm_exec_env_t exec_env, wasm_function_inst_t func, uint32_t argc, wasm_val_t* argv);
bool wasm_runtime_call_wasm_a(wasm_exec_env_t exec_env, wasm_function_inst_t func, uint32_t argc, wasm_val_t* argv, uint32_t result_count, wasm_val_t* results);

const char* wasm_runtime_get_exception(wasm_module_inst_t inst);

// Dumps the trapped wasm call stack to stdout. Requires WAMR built with
// WAMR_BUILD_DUMP_CALL_STACK=1 (+ CUSTOM_NAME_SECTION for Swift symbol names).
void wasm_runtime_dump_call_stack(wasm_exec_env_t exec_env);

#ifdef __cplusplus
}
#endif

#endif // WAMR_H
