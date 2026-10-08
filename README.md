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

- Public key: `py-tools/keys/ecdsa_public.pem` (committed). It is the public half
  of the Google Cloud KMS key `projects/openwater-cloud/locations/us-central1/keyRings/openmotion-firmware/cryptoKeys/console-fw-signing` (version 1).
  Fingerprint (SHA-256 of the DER SubjectPublicKeyInfo): `23da8ce52970482069af27085d4f01d25cde9545ac68d2c4c6c3890bee9e417f`.
  Confirm with `python py-tools/export_public_key.py --kms-key projects/openwater-cloud/locations/us-central1/keyRings/openmotion-firmware/cryptoKeys/console-fw-signing/cryptoKeyVersions/1 --check`.
- The ECDSA **private** key exists only inside the KMS HSM (non-exportable). It is
  never downloaded, never stored in CI, and not needed to build this bootloader.
  Firmware CI signs through Workload Identity Federation; see the Open-Motion
  workspace `RUNBOOK-kms-signing-setup.md`.
- The AES-128 key is kept out of git (CI secret `SECOREBIN_AES_KEY`). The crypto
  scheme embeds it in SECoreBin, but slot images are stored in clear and
  authenticated by signature, so it protects nothing. `se_key.s`, which embeds
  the AES key and the public key, is generated at build time and is `.gitignore`d.

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
committed public key, builds, and on a tag:

- uploads `openmotion-bl.{bin,hex,elf}` and `SHA256SUMS` to the private bucket
  `gs://openwater-firmware-artifacts/<repo>/<tag>/` through Workload Identity
  Federation (no stored Google credential; accepted for tag refs only);
- creates a GitHub Release carrying the notes (build SHA, trusted-key fingerprint,
  binary SHA-256, bucket path) and the SBOM. **Binaries are not release assets.**

Release-config builds exist only in the bucket. Debug builds (branches, `*-dev.*`
tags) are also kept as workflow artifacts for developers. The AES secret:

```sh
base64 -w0 <console aes128.bin>   # -> set as the SECOREBIN_AES_KEY secret
```

## Signing an application

Production images are signed in CI with the console key in Google Cloud KMS; no
private key is available locally. For bench work against a Debug bootloader
built from a local **test** key pair (`py-tools/generate_keys.py`):

```sh
python py-tools/sign_firmware.py \
    --firmware    motion-console-fw.bin \
    --private-key py-tools/keys/ecdsa_private.pem \
    --version     <MAJOR.MINOR.PATCH> \
    --output      motion-console-fw_signed.bin
python py-tools/verify_firmware.py motion-console-fw_signed.bin
```

With KMS signing rights (`roles/cloudkms.signerVerifier`; normally CI only):

```sh
python py-tools/sign_firmware.py --firmware motion-console-fw.bin \
    --kms-key projects/openwater-cloud/locations/us-central1/keyRings/openmotion-firmware/cryptoKeys/console-fw-signing/cryptoKeyVersions/1 \
    --version <MAJOR.MINOR.PATCH> --output motion-console-fw_signed.bin
```

The application must be linked to run at **`0x08020400`** (FLASH origin at the
slot + 0x400 header offset, with VTOR relocated there).

`--version` is a dotted semver encoded as `major*10000 + minor*100 + patch` into
the signed header's 16-bit `FwVersion` (minor and patch 0–99, maximum 6.55.35,
`0.0.0` invalid). The monotonic anti-rollback floor compares this value: a unit
that has booted version *N* refuses any image `< N` until re-flashed, so keep
release versions increasing. See `py-tools/README.md` §"Firmware versioning &
anti-rollback" for the full encoding table.

## Flashing

- **Bootloader** (ST-Link / OpenOCD): program `build/Release/openmotion-bl.hex`
  at `0x08000000` (with verify).
- **Signed app** (USB DFU): `python py-tools/flash_firmware.py motion-console-fw_signed.bin`
  (verifies the image on the host, then writes it to `0x08020000`; `dfu-util`
  and the STM32CubeProgrammer CLI are not used).
- **Production image:** bootloader + signed app merged into a single image and
  flashed at `0x08000000` (see the `openmotion-console-fw` CI, which bundles a
  pinned release of this bootloader with the signed app).

## Security configuration status

The protections are selected by the CMake preset (`SBSFU_ENABLE_PROTECTIONS`,
see `CMakeLists.txt` and the security block in `SBSFU/App/Inc/app_sfu.h`):

| Preset | Protections | Debug probe |
|---|---|---|
| `Debug` | Development mode (`SECBOOT_DISABLE_SECURITY_IPS`): option bytes untouched | Usable |
| `Release` | Applied by the bootloader at its first boot: **WRP** on the bootloader sector, **RDP level 1**, **PCROP** on the Secure Engine key region, **DAP** lock (SWD pins become inputs), **DMA** protection | Not usable; RDP level 1 is reversed only by a mass erase |

Firmware signature verification, the SE key-RAM wipe, the DFU read bounds and
the pre-erase header check are active in both presets. **RDP level 2**
(`SFU_FINAL_SECURE_LOCK_ENABLE`) is the production end state but is not yet
enabled anywhere: it is permanent on the part, so it is a deliberate step
recorded under tracker T2, not a build option.

> **Caution:** a `Release` build programs the option bytes on the first boot of
> whatever board it is flashed to. Keep a full flash backup (including the
> user-config sector) of a bench unit before flashing it, and power-cycle with
> the probe disconnected afterwards — at RDP level 1 the core cannot execute
> from flash while a debugger is attached.
