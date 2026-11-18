/*
 * bPuppy 版本信息模块
 *
 * 每次功能变更手动更新 BP_VERSION，编译时间自动更新。
 * 在 REPL 中:
 *   import bpuppy
 *   bpuppy.version()       → "v0.1  Jul  9 2026 14:30:00"
 *   bpuppy.board()         → "esp32s3" | "esp32"   (本次构建的 SoC 目标)
 *
 * board() 的用途: frozen 的 .py 看不到 Kconfig, 但**引脚是按目标不同的**
 * (例如语音 UART2 在 S3 是 19/20, 在经典 ESP32 是 16/17)。frozen/voice.py
 * 靠它选引脚, 从而不必在 S3 上改变任何行为。
 */

#include "board_config.h"   // BPUPPY_TARGET_NAME

#include "py/runtime.h"
#include "py/obj.h"
#include <string.h>

#define BP_VERSION "202607090001"

STATIC mp_obj_t bpuppy_version(void) {
    return mp_obj_new_str(BP_VERSION " " __DATE__ " " __TIME__,
                          strlen(BP_VERSION " " __DATE__ " " __TIME__));
}
STATIC MP_DEFINE_CONST_FUN_OBJ_0(bpuppy_version_obj, bpuppy_version);

STATIC mp_obj_t bpuppy_board(void) {
    return mp_obj_new_str(BPUPPY_TARGET_NAME, strlen(BPUPPY_TARGET_NAME));
}
STATIC MP_DEFINE_CONST_FUN_OBJ_0(bpuppy_board_obj, bpuppy_board);

STATIC const mp_rom_map_elem_t bpuppy_globals_table[] = {
    { MP_ROM_QSTR(MP_QSTR___name__),  MP_ROM_QSTR(MP_QSTR_bpuppy) },
    { MP_ROM_QSTR(MP_QSTR_version),   MP_ROM_PTR(&bpuppy_version_obj) },
    { MP_ROM_QSTR(MP_QSTR_board),     MP_ROM_PTR(&bpuppy_board_obj) },
};
STATIC MP_DEFINE_CONST_DICT(bpuppy_globals, bpuppy_globals_table);

const mp_obj_module_t bpuppy_module = {
    .base = { &mp_type_module },
    .globals = (mp_obj_dict_t *)&bpuppy_globals,
};

MP_REGISTER_MODULE(MP_QSTR_bpuppy, bpuppy_module);
