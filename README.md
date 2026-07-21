# open-motion-console-bl

Secure boot + secure firmware update (SBSFU) bootloader for the **OpenMotion
console module** (STM32H743). On reset it verifies the application image in the
active slot against an on-chip public key and launches it only if the signature
and integrity checks pass; if no valid image is present it drops to USB DFU so a
signed image can be installed.

This is the console-board sibling of `open-motion-sensor-bl`: the same
secure-boot core, but a different board bring-up and a **distinct signing key**.

## Overview

- **MCU:** STM32H743, single active application slot.
- **Authentication:** ECDSA P‑256 signature over the SHA‑256 of the image
  metadata, plus full-image SHA‑256 integrity
  (scheme `SECBOOT_ECCDSA_WITH_AES128_CBC_SHA256`).
- **Recovery:** USB DFU (OTG_FS). Also supports application-requested DFU (via an
  RTC backup-register magic + reset) and a boot-failure failsafe.
- **Extra protections:** the Secure Engine key RAM is zeroized before control
  leaves the bootloader; a persistent monotonic anti-rollback version floor; and
  DFU UPLOAD/read is bounded to the application slot.

## Flash layout

| Region | Address | Notes |
|---|---|---|
| Bootloader | `0x08000000` (sector 0) | this image |
| Application slot | `0x08020000`–`0x0811FFFF` (1024 KB) | DFU-writable; app vectors at `0x08020400` |
| Reserved / config | `>= 0x08120000` | read-only over DFU |

## Console-board bring-up (differs from the sensor board)

The bootloader enumerates over **USB full-speed (OTG_FS)** through the console
board's on-board USB hub, which is gated behind an I/O expander. Both are
released over GPIO before `MX_USB_DEVICE_Init()`:

- `IO_EXP_RSTN` (PA2) → released to enable the I/O expander.
- `HUB_RESET` (PC13) → released to bring the USB hub out of reset.
- **Clock:** internal HSI → 240 MHz (VOS SCALE2); HSI48 supplies the OTG_FS
  48 MHz kernel clock.
- **Debug trace:** UART4 on PD0/PD1, 115200 8N1.
- **Status LED:** `IND1` (PA3); `IND2`/`IND3` also available.

## Keys

The bootloader embeds the **console** signing public key. Applications must be
signed with the matching console private key or they are rejected at boot.

- Public key: `py-tools/keys/ecdsa_public.pem` (committed).
  Fingerprint (SHA‑256, first 16 hex): `4f28ff7fbe3ab9b8`.
- The ECDSA **private** key and the AES key are kept **out of git** (stored as
  CI secrets / offline). `se_key.s` — which embeds the AES key and public key —
  is generated at build time and is `.gitignore`d.

The console key set is independent of the sensor key set; do not cross them.

## Building

Requires the Arm GNU toolchain, CMake, and Ninja. `se_key.s` must be generated
from the key material before the first build:

```sh
python py-tools/gen_se_key_s.py \
    --aes-key   <console aes128.bin>   \
    --pub-key-x <console pub_key_x.bin> \
    --pub-key-y <console pub_key_y.bin> \
    --output    SECoreBin/Startup/se_key.s

cmake --preset Release
cmake --build build/Release
```

Outputs: `build/Release/openmotion-bl.{elf,hex,bin}`.

### CI

`.github/workflows/build-firmware.yml` regenerates `se_key.s` from the
`SECOREBIN_AES_KEY` repository secret (base64 of the 16 raw AES bytes) plus the
committed public key, then builds and publishes a release. **`SECOREBIN_AES_KEY`
must hold the console AES key** — a mismatched secret silently produces a
bootloader that rejects console-signed firmware:

```sh
base64 -w0 <console aes128.bin>   # -> set as the SECOREBIN_AES_KEY secret
```

## Signing an application

Sign the raw application `.bin` with the console keys before installing:

```sh
python py-tools/sign_firmware.py \
    --firmware    motion-console-fw.bin \
    --private-key <console ecdsa_private.pem> \
    --aes-key     <console aes128.bin> \
    --version     <MAJOR.MINOR.PATCH> \
    --output      motion-console-fw_signed.bin
```

The application must be linked to run at **`0x08020400`** (FLASH origin at the
slot + 0x400 header offset, with VTOR relocated there).

`--version` accepts a dotted semver (`major` 0–31, `minor` 0–63, `patch` 0–31;
`0.0.0` invalid). It is packed as `major[15:11] . minor[10:5] . patch[4:0]`
into the signed header's 16-bit `FwVersion` field, which the monotonic
anti-rollback floor uses: a unit that has booted version *N* refuses any image
`< N` until re-flashed, so keep release versions increasing. See
`py-tools/README.md` §"Firmware versioning & anti-rollback" for the full
encoding table.

## Flashing

- **Bootloader** (ST-Link / OpenOCD): program `build/Release/openmotion-bl.hex`
  at `0x08000000` (with verify).
- **Signed app** (USB DFU): `dfu-util -a 0 -s 0x08020000 -D motion-console-fw_signed.bin`.
- **Production image:** bootloader + signed app merged into a single image and
  flashed at `0x08000000` (see the `openmotion-console-fw` CI, which bundles a
  pinned release of this bootloader with the signed app).

## Security configuration status

This build runs in **development mode** (`SECBOOT_DISABLE_SECURITY_IPS`): the
option-byte protections — **WRP, RDP level 2, PCROP, and the DAP debug lock — are
NOT enabled.** Firmware signature verification, the SE key-RAM wipe, and the DFU
read bounds are active. Enabling WRP (write-protect the bootloader + Secure
Engine), RDP level 2, PCROP on the SE key region, and the DAP lock is required
before field/production deployment.

> **Caution:** enabling the DAP lock or RDP level 2 disconnects the debugger.
> Apply that pass only after everything else has been validated.
