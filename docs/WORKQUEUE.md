# Workqueue — typed-language-model-arena

Living queue for the campaign stack (shikumi decides, keiro journals, kioku remembers).
Scheduler ground truth: `REAL_LIMIT=0 ACTS=23 campaign-demo` — currently 17 evidenced
cells, alpha tier (retest) at the head of the plan. Last updated: 2026-09-19 (alpha baseline & initramfs sync).

## In flight

### Catalog audit (`pgcl/matrix-driver-all.sh`) — CLOSED
Per-row verification of the 20-arch catalog against what this host actually has,
*before* burning a 45-minute build on a stale row. Re-run any time with
`~/src/pgcl/matrix-catalog-audit.sh` (exit 1 = some reachable row is unusable).

- [x] Toolchains incl. sh4 `~/x-tools` fallback: 19/19 present (csky absent by design)
- [x] QEMU binaries: 16/16 present (csky absent); all `-M` machines and pinned `-cpu` models supported
- [x] Initramfs inventory: all per-arch files present (embedded for microblaze/sh4/loongarch64)
- [x] Defconfig census vs `~/src/linux` (7.1.0): all resolve, incl. `KBUILD_DEFCONFIG` remaps (microblaze, loongarch) and the kernel's `parisc64 → parisc` Makefile alias
- [x] June col6 census: 16 arches build-proven 3/3; sh4/or1k/xtensa/csky were pre-bring-up in June (sh4 since brought up in `c36ae25`)
- [x] **Found + fixed**: riscv32 row shipped nonexistent `rv32_defconfig` → now `DC="defconfig 32-bit.config"` (the driver's own documented recipe; verified `CONFIG_32BIT=y` live)
- [x] `matrix-catalog-audit.sh` written, debugged, exit 0; parser lessons baked in as comments (`read` strips leading IFS whitespace → no `^` anchors; LA follows `)` not `;`; hppa/hppa64/sh4 rows use tight `;QEMU=`; x86_64 leads with `-enable-kvm` so flag parsing is a single-token scan)
- [ ] Candidate follow-up: fold the audit into the campaign (run it before each live batch; SKIP-vocabulary rows report n/a, not failure)

## Queue — campaign / matrix track

1. **Alpha tier baseline & re-test** — first live run proved all 5 cells compile and boot into QEMU Clipper cleanly (rc=0, 73 LTP passed). Root-caused missing LTP failure names to an outdated April `init` script in `initramfs-alpha.cpio.gz` (lacked immediate fail dump and `LTP FAIL LIST`); rebuilt `initramfs-alpha.cpio.gz` and `initramfs-arm.cpio.gz` with current `init`. Verified single failing LTP test is `mmap3: FAIL (exit=2)` (identical across configs and May baseline). Added `knownFailuresFor "alpha" = ["mmap3"]` to `Campaign.Real.hs`. Re-test live batch will promote tier from `failed` to `passed-waived`.
2. **Live batches across the remaining tiers** — arm-lpae is #6–#10; behind it arm, hppa, hppa64, microblaze, mips64, or1k, xtensa, sh4, riscv32, sparc64, s390x, ppc64. The road to 19-arch × 5-config coverage (96 units, minus csky).
3. **hppa/hppa64 baseline evidence** — June logs show single LTP failures; two repeat runs each before they earn `knownFailuresFor` entries (the loongarch rule: no baseline on one log).
4. **csky** — install its cross-gcc + `qemu-system-csky`, or accept permanent absence from the plan.
5. **Stale workflow wart** — CLOSED (`CLEANUP=stale` retired orphaned Sail units with typed cancellations; resume sweep now 0 discovered / 0 unregistered).
6. **alpha batch pre-flight** — CLOSED (catalog audit green, QEMU Clipper stable).

## Queue — verification-beyond-boot track

6. **Rocq + Iris formal-proof cells** — proof checking as campaign units; the biggest unbuilt rung. (The Sail corpus work is banked, but it is parsing/lexing tests, not proof verification.)
7. **frankenstein / organ-bank** — the wider compiler playground; untouched.

## Mercury track — CLOSED

Replayable refactor demo landed (arena `2216b59`): `REPLAY=mercury` with
`MERCURY_ENGINE=live|replay` and `MERCURY_CLEAN=1`; scripted drama, live engine,
and the parent-commit verify geometry all proven end to end.

## Parked (by operator choice)

- Terminal concentrator / networked power-control hardware-in-the-loop.
- Real-hardware cells (QEMU-only for now).

## Ledger (recent)

- arena — added `knownFailuresFor "alpha" = ["mmap3"]`; updated `real-validate` to support arch-scoped baseline classification
- pgcl — rebuilt `initramfs-alpha.cpio.gz` and `initramfs-arm.cpio.gz` with current `init` (restores immediate fail dump, `LTP FAIL LIST`, autotest console flush)
- arena — `CLEANUP=stale` operator mode added; retired stale Sail workflow instances (`project-cell-campaign`) with typed cancellations; resume sweep now 0 unregistered
- pgcl `542bf6e` — riscv32 row fix (`defconfig 32-bit.config`) + `matrix-catalog-audit.sh`
- arena `2216b59` — Mercury replay demo: the promotion campaign as a one-command demo
- arena `29c444d` — discovery/dispatch pointed at the full-catalog `matrix-driver-all.sh`; sh4 `~/x-tools` fallback mirrored in discovery
- pgcl `13b4f67` — `-all` driver: loongarch EFI_ZBOOT/KIMG + `timeout --foreground` ports
- arena `2c02d39` — verdict gate learns `passed-waived`; probe now covers the full pipeline
- pgcl `70d5ec0` — driver `--foreground` + stdin detach (SIGTTOU root cause)
- pgcl `e11a8b5` — driver loongarch block + initramfs refresh
- arena `5fc1a61` — real-cell initramfs + classifier baseline work
- kioku — 5 wrong loongarch lesson rows corrected in place (journals keep raw history)
