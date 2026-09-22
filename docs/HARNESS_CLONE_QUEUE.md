# Verification Harness Clone Queue — Remaining Candidates

> **Status**: Inventory + queue (drafted 2026-09-22, after successive clone passes under `~/src/`).
> **Companions**: [`VERIFICATION_LADDER.md`](VERIFICATION_LADDER.md) (seven forms, barriers, enablement order), [`CAMPAIGN_GENERALIZATION.md`](CAMPAIGN_GENERALIZATION.md), [`WORKQUEUE.md`](WORKQUEUE.md).
> **Scope**: What remains worth cloning to assess **execution requirements** (invocation, privileges, I/O channels, duration, pass signal) for each verification form — plus two cross-cutting holes not in the original seven.

**Assessment lens** (apply to every clone): ① invocation → manifest `command`/args; ② privileges/topology → capability flags; ③ I/O channel → driver contract / oracle source; ④ duration & failure modes → `timeoutSeconds`, waives, resume; ⑤ pass signal → oracle fact kind (`logSchema`, `proofHygiene`, fsck, abidiff, …).

---

## 1. Landed (as of this draft)

Successive passes have filled most of the recommended set. Notable arrivals, including name variants:

| Area | Present under `~/src/` |
| :--- | :--- |
| **Form 1 — Formal** | `mirror-isabelle` (Isabelle), `seL4/l4v` in-tree, `kani`, `Frama-C-snapshot`, `dafny`, `prusti`, `cbmc`, `sby`, `yosys`, `apalache`, `tlaplus`, plus pre-existing `verus`, `iris`/`islaris`, `lean4`, `rocq`, `bedrock2`, `certikos`, `rzk`, `sail*`, `Dat3M`, `herdtools7`, `k`, `Maude`, `sbv` |
| **Form 2 — Boot/console** | `expect`, `pexpect`, `kvm-unit-tests`, `u-boot`, `grub`, `coreboot`, `barebox`, `dnsmasq`, `flashrom`, `libvirt`, `trusted-firmware-a`, `ser2net`, `conserver`, `buildroot`, `riscv-isa-sim` (spike), `QEMU`, `simics`, `syzkaller` |
| **Form 3 — In-guest stress / binary-compat** | `stress-ng`, `fio`, `filebench`, `hackbench`, `will-it-scale`, `trinity`, `MoonGen`, `wrk2`, `sockperf`, `sysbench`, `AFLplusplus`, `llvm-test-suite`, `libabigail`, `abi-compliance-checker`, `diffoscope`, `elfutils`, `reprotest`, `ltp` |
| **Form 4 — Bootstrap fixpoint** | `csmith`, `creduce`, `yarpgen`, `diffoscope`, `reprotest` (+ `mercury*`, `Idris2`, `lean4` in-tree) |
| **Form 5 — Network interop** | `packetdrill`, `Hewlett-Packard-netperf`, `microsoft-netperf`, `nfstest`, `ngtcp2`, `quiche`, `quic-interop-runner`, `mininet`, `scapy`, `wireshark`, `testssl.sh`, `gnutls`, `openssl`, `samba` |
| **Form 6 — Cluster / fault injection** | `jepsen` (CharybdeFS, Elle, antithesis refs), `maelstrom`, `porcupine`, `toxiproxy`, `failpoint`, `pumba`, `chaos-mesh`, `foundationdb`, `etcd`, `redis`, `nats-server`, `postgresql` |
| **Form 7 — FS crash-consistency** | `xfstests`, `pjdfstest`, `crashmonkey`, `janus`, `e2fsprogs`, `xfsprogs`, `filebench`, `fio`, `ltp` |
| **Adjacent** | `pgmq`/`pgmq-hs`, `porcupine`, `socat`, `pty-mcp-server`, `freebsd`/`netbsd`/`haiku`/`serenity` test trees, `linux/tools/testing` (selftests, kselftest, lkdtm, fail_function) |

Also present but **not harness targets**: `victima`, `Virtuoso` (research simulators — reading only).

---

## 2. Still missing from prior recommendations

| Repo | Form | Why it remains on the queue |
| :--- | :--- | :--- |
| **`ipxe`** | 2 | Last hole in the tftp/PXE client path (`dnsmasq` is server-side only; no boot-ROM/script flow to assess) |
| **`stage0-posix`** + **`mes`** (GNU Mes) | 4 | Bootstrappable multi-stage fixpoint methodology — top remaining form-4 gap; defines what a real fixpoint *certificate* looks like |
| **`lkl`** (`lkl/linux`) | 7 | Linux Kernel Library: in-process FS mkfs/mount/fsck screening before full crash-reboot cells |
| **`edk2`** | 2 | UEFI boot chain — you have coreboot/barebox/u-boot/TF-A but no EDK2/OVMF assessment path |
| **`btrfs-progs`** | 7 | Only if btrfs enters the matrix (cf. `linux-btrfs-bigpage`); **`btrfs check` exit-code semantics are a known oracle-honesty trap** — worth reading even just for that |
| **`spin`** | 6 | Promela model checker — cheap spec-first pre-work before wiring nemesis schedules |

---

## 3. New — high value (not in earlier rounds)

| Repo | Form | Requirement-assessment value |
| :--- | :--- | :--- |
| **`avocado`** + **`avocado-vt`** | 2, 3 | Purpose-built VM/QEMU test framework (libvirt/QEMU ecosystem): job files, wait/result taxonomy → ready-made **driver-contract reference** for `vm-console-boot` / `stress-soak` kinds |
| **`rr`** (mozilla) | 3, 7 | **Record/replay**: turns a once-only guest/host crash into deterministic re-runs; enriches kioku L0 beyond a static log |
| **`kcov`** | 3 | Coverage on **stripped binaries** (no rebuild) — viable in-guest coverage oracle where `--coverage` post-strip fails |
| **`patroni`** (± `pgpool-II`) | 6 | **Postgres HA/failover** SUT — you run PG everywhere; disorderly primary kill + stream-failover is the natural first bonded-node cell before a generic cluster stack |
| **`corosync`** + **`pacemaker`** | 6 | Literal **cluster bonding + STONITH/fence/quorum** stack matching form-6 wording; fence/recovery semantics map onto nemesis facts |
| **`lvm2`** | 7 | **`dmsetup` lives here** — practical hard dependency of crashmonkey’s device-mapper model; also thin/snapshot crash cases |
| **`tlaplus/examples`** | 5, 6 | Toolbox landed; **worked protocol/nemesis specs** did not — fastest path to spec-first barrier analysis |
| **`QuickCheck`** + **`hedgehog`** | meta | Property tests for **oracles, `CodeGraphStore`, façade schemas** — gates need tests-of-the-gates (absent from the original seven, required to trust them) |
| **`loom`** (tokio-rs) | 6 | **Rust concurrency model checker** — telix IPC/atomics without Jepsen-scale cost per commit |
| **`nsjail`** or **`bubblewrap`** (+ **`runc`** / **`gvisor`** if container workers) | cross | **Sandbox for agent-proposed test code** (tier7 / Shikumi outputs) — prerequisite before untrusted binaries enter any ladder rung |
| **`firecracker`** or **`cloud-hypervisor`** | 2 | Lightweight **worker VMs** for Phase 5 federation — lighter than full system QEMU for host-verify-class cells |
| **`valgrind`** | 3 | memcheck/helgrind as **host-verify oracles** (exit × tool output) for C targets (kuroko, organ-bank) |
| **`LiquidHaskell`** | 1 | Refinement types **for arena-owned oracle/store code** — strongest form-1 add now that external provers are saturated |
| **`nfs-utils`** or **`nfs-ganesha`** | 5, 7 | `nfstest` needs an NFS **server** topology not yet present |
| **`nghttp2`** | 5 | HTTP/2 (`h2load`, nghttp) — last common wire protocol without a harness |

---

## 4. New — conditional / second tier

| Repo | Form | Clone when |
| :--- | :--- | :--- |
| **`CompCert`**, **`KLEE`**, **`Why3`**, **`CertiCoq`** | 1, 4 | Verified-compiler reference cell, symbolic C exec, or multi-prover aggregation is actually targeted |
| **`rt-tests`** | 3 | telix/latency cells need `cyclictest`-class RT oracles |
| **`openocd`** | 2 | HIL/JTAG moves from roadmap to live cells |
| **`NUT`** (Network UPS Tools) | 6 | PDU/power-cycle nemesis (CAMPAIGN_GENERALIZATION already names networked PDUs) |
| **`openzfs`** | 7 | ZFS Test Suite — alternate crash-consistency model (ZIL) vs ext/xfs |
| **`cargo-mutants`** / **`mutatest`** | meta | **Mutation testing** as a gate-strength metric (are oracles actually sensitive?) |
| **`mrustc`** or **`tcc`** | 4 | Tiny/self-hosting fixpoint sandboxes if `stage0-posix` feels heavy |
| **`libfaketime`** | 3 | Time-dependent tests without wall-clock waits |
| **`protobuf`** (conformance suite) | 5 | Deepening the existing `proto-lens` dependency |
| **`swtpm`** | 2 | Measured-boot/TPM lanes with TF-A/EDK2 |
| **`kyua`** / **`atf-c`** | 2 | BSD test-runner pattern (`freebsd`/`netbsd` trees already in place) |
| **`btrfs-progs`**, **`f2fs-tools`** | 7 | Those filesystems enter the guest matrix |
| **`keepalived`**, **`drbd`**, **`rqlite`** | 6 | After patroni/corosync prototype — additional SUT/storage flavors |

---

## 5. Still skip

- **`iperf3`**, **`honggfuzz`**, **`schbench`** — covered by sockperf/wrk2/netperf, AFLplusplus, stress-ng.
- **Full `gcc` / `llvm` / `rustc` monorepos** — until a fixpoint unit targets them specifically (`csmith`/`creduce`/`yarpgen`/`llvm-test-suite` already give the test-program side).
- **`litmus`** (K8s chaos) — `chaos-mesh` already landed; add litmus only if a K8s worker tier appears.
- **`saw-script` / `crucible`**, **F\***, **Agda** — prover set is saturated; add only for a concrete target.
- **`victima`**, **`Virtuoso`** — research simulators, not campaign harnesses.
- Commercial/infra (Gremlin, LKFT-only tooling, licensed SPEC) — out of scope for clone-based assessment.

---

## 6. Queue priority (recommended clone order)

1. **`ipxe`** — closes the stated tftpboot gap (form 2).
2. **`stage0-posix`** + **`mes`** — form-4 fixpoint methodology.
3. **`lkl`** — form-7 cheap screening loop.
4. **`avocado`** + **`avocado-vt`** — driver-contract reference for kinds still to open.
5. **`patroni`** then **`corosync`**+**`pacemaker`** — form-6 progression (PG first, generic cluster second).
6. **`lvm2`** — unblocks crashmonkey-style dm oracles (form 7).
7. **`rr`** — failure diagnosis for any long-running cell.
8. **`QuickCheck`** + **`hedgehog`** — meta: test the gates.
9. **`nsjail`** or **`bubblewrap`** — sandbox before agent-run binaries.
10. **`edk2`** / **`tlaplus/examples`** / **`nfs-utils`** / **`nghttp2`** — form-specific follow-ups as those cells are scoped.

Everything in §4 waits on a concrete target or the ladder seams (open kinds, interpreted oracle facts) described in [`VERIFICATION_LADDER.md`](VERIFICATION_LADDER.md) §2.

---

## 7. Touchpoints

- **Ladder seams first**: open the kind allow-list and interpret `proofHygiene` / `logSchema` / `timeoutSeconds` before harvesting §2–3 repos into manifests — clones inform the *driver contract*, they don’t replace it.
- **WORKQUEUE**: candidate milestones — `ipxe` driver sketch, `patroni` two-node failover unit, crashmonkey+`lvm2` `vm-crash-consistency` prototype, property-test suite for oracles.
- **CAMPAIGN_GENERALIZATION**: Phase 5 workers ← firecracker/cloud-hypervisor/avocado; Phase 4 bisection ← rr-assisted logs; HIL paragraph ← ser2net/conserver (landed) + openocd/NUT (queued).
- **COMBINED_ECOSYSTEM_PLAN**: sandbox (nsjail/bubblewrap) gates tier7 code-exec alongside the CodeGraphStore façade.
