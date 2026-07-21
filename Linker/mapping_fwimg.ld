/*
*****************************************************************************
**  File        : mapping_fwimg.ld
**  Abstract    : Firmware image slot mapping for single-image SBSFU.
**                Active slot starts at sector 1 (0x08020000).
*****************************************************************************
*/

/* Slots must be aligned on sector size (128KB on STM32H7).
 * See Core/Inc/memory_map.h for the full flash partition map. Layout:
 *   sector 0      0x08000000  128K  bootloader
 *   sectors 1-8   0x08020000  1024K APP SLOT 1 (active)   <-- this file
 *   sectors 9-14  0x08120000  768K  reserved (future use)
 *   sector 15     0x081E0000  128K  user config (read-only) */

/* Active slot #1: sectors 1-8 = 8 x 128KB = 1024KB */
__ICFEDIT_SLOT_Active_1_header__ = 0x08020000;
__ICFEDIT_SLOT_Active_1_start__  = 0x08020000;
__ICFEDIT_SLOT_Active_1_end__    = 0x0811FFFF;

/* Slots 2 and 3 are unused in this single-image configuration; keep the
 * SBSFU symbols defined as 0 so the SlotStartAdd[] array treats them as
 * disabled. */
__ICFEDIT_SLOT_Active_2_header__ = 0x00000000;
__ICFEDIT_SLOT_Active_2_start__  = 0x00000000;
__ICFEDIT_SLOT_Active_2_end__    = 0x00000000;
__ICFEDIT_SLOT_Active_3_header__ = 0x00000000;
__ICFEDIT_SLOT_Active_3_start__  = 0x00000000;
__ICFEDIT_SLOT_Active_3_end__    = 0x00000000;
