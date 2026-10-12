# HiBy R1 OS — Reverse-Engineering Notes

Working firmware: **stock v1.6** (`1.6/r1.upt`, build timestamp 2025-12-29).
Goal: optimise and improve the OS; the stock device is end-of-life upstream.
Mod repo of record (for learning, not direction): [bidhata/Hiby-R1-Mod](https://github.com/bidhata/Hiby-R1-Mod).

Everything in this file is verified against the firmware unless marked TBD.

## 1. Firmware package format (`.upt`)

- `.upt` is an **ISO 9660** image built with genisoimage (Joliet/RockRidge flags).
- Top level: `ota_config.in` (`current_version=0`) + `ota_v0/` directory.
- `ota_v0/` contains both images split into **512 KiB chunks**, chunk index as
  `.0000.-style numeric suffix`, and **the chunk filename carries the md5 of
  the next chunk in the chain** (hash-chained; tamper/order detection).
- `ota_md5_<image>.<md5-of-first-chunk>` lists the full chain, one hash/line.
- `ota_update.in`: sizes + whole-image md5 per `img_type` (`kernel`, `rootfs`).
- `ota_v0.ok` is an empty sentinel.

Tools: `tools/unpack.sh`, `tools/repack.sh` (xorriso replaces genisoimage here;
verified: 1.6 unpacks, repacks, and re-unpacks cleanly; rebuilt kernel md5 is
byte-identical; rebuilt squashfs lists file-for-file identical to stock).

## 2. Images

| Image | Size | Verified md5 (stock 1.6) | Notes |
|---|---|---|---|
| `xImage` | 3,731,520 | `022410af...` | uImage header: Linux-4.4.94+, MIPS, load/entry `0x80F00000`, **not compressed** per header — payload is gzip at offset 16992 |
| `rootfs.squashfs` | 37,507,072 | `9c8b3a94...` | squashfs **v4.0, LZO**, 128 KiB blocks, ~5076 inodes |

Kernel (from decompressed payload):
- `Linux version 4.4.94+ (zcz@androidserver3) (gcc 5.2.0, Ingenic r3.2.1-gcc520 2017.12-15) #12 PREEMPT` — an Ingenic SDK tree rebuild, Dec 2025.
- **No** `CONFIG_IKCONFIG` (can't pull config from the image itself) — TBD: which options are on must be probed live or via source.
- Compiled in (confirmed by strings): **squashfs LZO only** (no xz/zstd codecs), **UBIFS**, `deflate` (zlib) present, NO zram/zswap strings.
→ Faster rootfs compression (lz4/xz/zstd) needs a kernel rebuild; LZO is the safe default for now.

## 3. Boot chain (rootfs)

```
busybox init (inittab)
  └─ ::sysinit: mounts dev/proc, mount -a, hostname, /etc/init.d/rcS
       ├─ S10mdev, S11module_driver_default (loads module_driver/*.ko)
       ├─ S11jpeg_display_shell   ← boot splash
       ├─ S20urandom, S21mount_ubifs (usr/data)
       ├─ S30dbus, S39_recovery.recovery, S40network, S43wifi_bcm_init_config
       ├─ S50sys_server
       ├─ S80_bt_init
       └─ S92_03_start_music_player → PL01=/usr/bin/hiby_player.sh
             └─ killall hiby_player; (batd block is dead: no batd binary shipped)
                /usr/bin/hiby_player ; sleep 1 ; reboot   ← player exit ⇒ reboot
console::respawn:-/bin/sh   ← serial getty
::shutdown: rcK, swapoff, umount
```

- `bootmode.sh` selects boot kernel by writing `"ota:kernel"` or `"ota:kernel2"`
  (256B padded string via `nandwrite`) to `/dev/mtd5`. Two kernel slots exist
  in NAND; Recovery = `kernel2`. Primary kernel partition = TBD (probe via adb).
- `adbd` ships in `/usr/bin` (115K, `T90adb`/`adbon`/`adboff` toggles). ADB is
  our primary live experiment channel.

## 4. Rootfs survey (`unpacked/1.6/squashfs-root`)

- Squashfs is the whole OS (~37.5 MB incl. ~15 MB `/usr/bin`, 4.3 MB `/lib`).
- NAND part ("1Gbit" per specs = 128 MiB) holds: kernel x2 + rootfs + UBIFS
  `/usr/data` (settings, saved state) + data partition for `/data` (factory
  reset wipes it) — exact mtd layout TBD.
- `usr/bin/hiby_player`: 4.6 MB MIPS32r2 ELF, dynamically linked, stripped.
- `usr/bin`: full ALSA utils (amixer/aplay/arecord), BlueZ + bluealsa stack,
  bccmd/brcm_patchram_plus/bsa_server (2.6 MB!) for the 2.4 GHz CSR/Broadcom
  backend, mdev tools, adb tools.
- `module_driver/*.ko` + per-module `.sh` init: `axp2101.ko` (PMU),
  `codec_cs43131.ko` (DAC), `cst8xx_touch.ko`, `cw2015.ko` (fuel gauge),
  `cywdhd.ko` (WiFi), `lcd_lg35583.ko`, `pwm_backlight.ko`, `leds_pwm_add.ko`,
  `keyboard_{gpio,adc_multifunc}.ko`, `i2c_gpio_add.ko`, `rmem_manager.ko`,
  `sa_config_module.ko`, `sa_earpods_adc.ko`, `sa_hgl_dma.ko` (sound-architecture
  glue: earpods detection + HiBy "HGL" DMA path), plus more — full list TBD.
- `usr/resource/`: `config.json` (+ `set_functions.json`-style `fcn0` flags),
  `ot_devices.json` (per-device hardware volume tables incl. MDB/LDB gain
  steps), `eq.ini`, `audio_back.conf`, fonts, `litegui/` (the UI framework —
  panels/layouts; GUI is not inside hiby_player alone), layout, str/ (i18n),
  `hl_json/` (HiByLink).

## 5. Hardware facts (from X1600E datasheet, `X1600_E+Data+Sheet.pdf`)

- XBurst MIPS32r2, 9-stage pipeline, up to **1.0 GHz**; FPU (IEEE754 s/d).
- **16 KB I-cache + 16 KB D-cache**, 32-entry joint TLB (+8 data TLB),
  16 KB tight-coupled memory, **128 KB unified L2**.
- Integrated LPDDR2/DDR2 controller, **16-bit bus**; R1 ships 64MB.
- Serial flash controller (SFC): up to 80 MHz SDR, Dual/Quad SPI → the 128 MiB
  ("1Gbit") NAND/BGA memory hangs off SFC.
- Clock: 3 PLLs; **CCLK/HHCLK/H2CLK/PCLK/H0CLK/DDR_CLK are each separately
  programmable**; functional-unit clock gating (battery savings opportunity).
- PDMA: 32 channels, descriptors, up to 128-byte units.
- Power rails per datasheet VDDMEM 1.2V (LPDDR2) / 1.8V (DDR2), DDR_VDD1 1.8V.
  PMU on board is AXP2101 (DVFS/charger), fuel gauge CW2015.
- BootROM: reads `boot_sel[1:0]`; SD at MSC0 / USB / SFC boot paths; BootROM
  occupies 0x80000000-0x80009000 (36 KB of cache) before SPL handoff.

## 6. Player config surface (stock)

`usr/resource/config.json` flags of interest (stock values):
`dac_to_store:0`, `tf_image_cache_enable:0`, `tf_music_db_enable:0`,
`vol_warn_enable:1`, `dark_theme_enable:1`. Volume defaults/warn for headset.
The mod repo shows these toggles are honoured by the player binary — the
config surface is a cheap, low-risk experiment channel.

## 8. Emulation / VM status (Tier A established)

`hiby_player`'s ELF dependencies are generic: `librt libdl libasound libqrencode
libz libcrypto libssl libcurl libm libgcc_s libpthread libc` — no
Ingenic-specific library. The whole hardware contract is syscall-level:

| Node probed (strace, first boot) | Purpose |
|---|---|
| `/dev/fb0` | framebuffer (480x800 RGB) |
| `/dev/input` (readdir) | evdev keys + touch |
| `/dev/sa-config` | Ingenic "Sound Architecture" HAL control (`sa_*.ko`) |
| `/sys/class/switch/{i2s,lineout,headset,spdif,balance}/state` | audio routing state from driver side |
| `/sys/class/android_usb/f_uac_sa/dsd_native_enable` | USB-DAC gadget mode control |
| `/sys/class/leds/{red,blue}` | PWM LED |
| `/proc/jz/efuse/efuse_chip_id` | SoC identity |
| `exec nanddump -s 0x20000 -l 256 /dev/mtd5 > /data/theme_id` | theme id read from bootmode mtd5 at 0x20000 — mtd5 holds BOTH the `ota:kernel` selector at 0 AND theme id at 0x20000 |
| `/proc/asound` (via aplay) | ALSA card enumeration |

Consequence: the player is emulatable once target nodes exist — no proprietary
unicorn code. Tier plan:
- **Tier A (done, partial):** `tools/qrun.sh` runs rootfs binaries on this PC
  under `qemu-mipsel -L <rootfs>` with env isolation (LC_ALL=C; its old glibc
  asserts on host locales). Verified: busybox, amixer/aplay, init script parse
  + start player strace recorded at `/tmp` (keep trimmed copies alongside this doc).
- **Tier A full** needs a real rootfs sandbox: `proot` (rootless) or sudo
  chroot — device-tree fakes (fb/input/snd/switch stubs, `/usr/data`) come with it.
- **Tier B:** `sudo apt-get install -y qemu-system-mips` (not yet installed) →
  boot a generic MIPS32r2 kernel with our `rootfs.squashfs` as root (`-m 64M`!).
- **Tier C:** custom QEMU X1600 machine to boot the stock kernel itself.

qemu-user observations: player loads all libs through the -L prefix, probes
fb0 → input → sa-config → efuse → mtd5, then exits by SIGBUS under qemu
(expected — real device differs; find precise exit cause later with the
chroot sandbox). `aplay -l` reports "no soundcards found" gracefully.

### Sandbox tools inventory

- tools/proot-run.sh — earlier proot+qemu hybrid (proven machinery, hit glue conflicts; superseded by r1-sandbox.sh)
- tools/qrun.sh — plain qemu-user single binary runner

### QEMU XBurst CPU models (verified present, Oct 12)

Upstream QEMU (`tools/vendors/qemu`, rev 615ece3) already carries the
Ingenic core as first-class models: `XBurstR1` (line 121, CPU_MIPS32R1|ASE_MXU)
and `XBurstR2` (line 347, CPU_MIPS32R2|ASE_MXU) in
target/mips/cpu-defs.c.inc, with the full MXU SIMD decoder
(target/mips/tcg/mxu_translate.c). Tier C's CPU-compatibility risk is gone:
we write a machine, not a CPU.

### Sandbox v2 (real mounts, current)

`tools/r1-sandbox.sh` (current, REAL mounts): unprivileged user-namespace +
bind mounts + chroot; static qemu-mipsel inside; host env quarantined via
env -i LC_ALL=C inside the chroot. Fakes: /dev/fb0 (768000B file), sa-config,
mtd5 image, real host /dev/input for keys/touch, writable /usr/data//tmp//var,
/sbin overlays stubbing reboot. Viewer: tools/fb-viewer.py (tkinter, RGB565,
2x scale, ~20fps) pick up /tmp/kilo/r1sb/dev/fb0; the fb loop is PROVEN
(guest dd pattern test renders in the host window).

Player progress inside the sandbox (docs/traces/sandbox-player-engine-boot.*):
- gets past ALL device probing (fb0 fd OK, input dir OK, sa-config OK)
- litegui theme1 parsed; boot animation tolerated when we substitute a 1x1
  png in the /usr/resource/litegui overlay (the original png SIGBUS story
  gone; apparently its mmap size path hits only some alignment from the
  real file… TBD)
- HiBy AUDIO ENGINE BOOTS: "SAM/I HiBy Engine 5e4c22e Build Aug 15 2025",
  options reveal DSD2PCM DSD64/128/256/512 qualities — DSD512 is compiled
  in; MSEB, Balance, Sound Field, sony_select all init; music-db sqlite
  init runs and logs "no such table: VERSION_TABLE"
- dies later with its own crash reporter: "HiBy Player crashed by signal
  SIGUSR1 / Call Trace /usr/bin/hiby_player() [0x6fbdec]" — its own
  watchdog/fatal handler, and one thread reads /proc/SELF/maps.
- remaining blocks: FB ioctl (file gives ENOTTY → "failed to get fb0
  info"), evdev init, MGR socket bind.
  -> Cross toolchain fetched (tools/vendors/mipsel-linux-musl-cross, sha256
  82626533...) + shim built (tools/shim/shim.c: FBIOGET_* fake) BUT
  injecting the musl-built .so via LD_PRELOAD SEGVs inside the image's
  old glibc ld.so. Next: either a shim built against the ROM's glibc
  ABI, or binary-patching the player's fb init (we have mipsel objdump).


proot -R rootfs + qemu-mipsel hybrid works (rootless, no sudo): proot gives
path isolation + writable /usr/data,/tmp,/var; a generated fake /dev tree
provides fb0 (768000B RGB565 file), sa-config, mtd5 (ota:kernel + theme '1'
at 0x20000), input dir bound to host's evdev so host keyboard drives the
guest. busybox + any rootfs binary run guest-absolute; program arg must be
path-converted (qemu resolves program args on the host fs, NOT through proot).

Limits found so far:
- hiby_player survives ALL of the fake-device probing and reaches the
  litegui boot animation, then dies with deterministic SIGBUS at
  0x2cb006a4 while decoding theme1 0.png (SIGBUS even with the frame list
  emptied, so the frame-name fallback is hardcoded). Same fault before and
  after proot — suspect a HiBy latent bug (mmap sizing) that the real
  kernel tolerates, or a qemu TCG/proot artifact. Next tools: a MIPS
  LD_PRELOAD shim (needs mipsel musl cross toolchain, Phase 3) to intercept
  the png mmap, or binary-patching the animation call site.
- Because the player runs `reboot` on exit (hiby_player.sh), DO NOT run the
  full rcS chain before stubbing /sbin/reboot in the sandbox (planned next).

Device USB: R1 enumerates as `32bb:0101` (matches config.json vid/pid) but
adbd is OFF in its current mode — no `adb devices`. Need the device-side
debug toggle (Settings → look for a developer/debug option; the adbon
script exists in the ROM).


## 9. Unknowns / next probes (TBD)

- Full mtd partition map (`cat /proc/mtd`, kernel cmdline via adb/dmesg).
- CPU clock at runtime (power-saving governor? DVFS policy?), available CPUs
  knobs in `/sys/devices/system/cpu`.
- ALSA state: current mixer graph + CS43131 routing (`/var/lib/alsa/asound.state`, amixer dump; `midi_config.json`).
- What S50sys_server does (HAL glue between kernel and hiby_player?).
- hiby_player internals: strings + objdump; GUI overlay via litegui resources.
- Whether kernel source for this exact 4.4.94+ Ingenic tree is obtainable
  (GPL: HiBy/Ingenic SDK trees from other Ingenic DAP projects; e.g. old
  agptek/ruisu/xdu boys use same SoC family). Kernel work is Phase 2+.
