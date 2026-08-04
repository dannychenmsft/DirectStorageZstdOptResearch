# FSE-Table Multi-Wave Symbol-Handoff Race (NVIDIA Pascal)

Diagnostic write-up for the flaky GPU sequence-decode validation failure first
reproduced on a **GTX 1060 (Pascal)** lab machine. This branch
(`zstdgpu-fse-multiwave-wip`) carries the validator diagnostics, shader toggles,
and the repro harness used to isolate it, so it is a good starting point for
further analysis on a second Pascal part (e.g. **GTX 1080**).

> Status: root cause identified with high confidence; fix implemented and locally
> verified. Pascal hardware confirmation of the fix is the main open item.

---

## TL;DR

* **What breaks:** the `[Init FSE Table]` compute shader hands FSE-table symbols
  from its *spread* phase to its *rank/nstate transpose* phase through the
  `inoutFseElems` **UAV**.
* **Why it breaks:** in a multi-wave threadgroup the two phases run on different
  waves, separated only by `GroupMemoryBarrierWithGroupSync`. That barrier orders
  **group-shared (LDS)** memory but **not** cross-wave **UAV / device-memory**
  writes. On Pascal's weak memory model the transpose can read a **stale symbol**.
* **Result:** one ballot bit is wrong → the per-symbol rank (`prefix`) is off by
  exactly 1 → wrong `nstate` → downstream `BlockSizePrefix mismatch` in
  `Validate_DecompressedSequences`. Intermittent, Pascal-only, multi-wave-only.
* **Fix:** hand the symbols off through a new **LDS** region (`GS_SpreadSymbols`),
  which the existing group barrier orders reliably on every GPU. Multi-wave +
  DEFAULT method only; single-wave targets keep the occupancy-optimal direct-to-UAV
  path. See commits `51a8e56` / `e5ba8d3` on branch
  `zstdgpu-fix-fse-lds-handoff-no-dup-write`.

---

## Affected component

* Shader: `zstd/zstdgpu/Shaders/ZstdGpuInitFseTable.hlsl` → body in
  `zstd/zstdgpu/zstdgpu_shaders.h` (`zstdgpu_ShaderEntry_InitFseTable`).
* Method: `ZSTD_BITCNT_NSTATE_METHOD == DEFAULT` (the compiled/production path).
* The FSE table drives literal/offset/match-length sequence decode, so a single
  wrong rank corrupts sequence decoding and trips the validator.

## Symptom / failure signature

Observed via the instrumented reference validator on this branch
(`zstd/zstdgpu/zstdgpu_reference_store.cpp`):

| Observation | Value | Meaning |
|---|---|---|
| Validation | `Validate_DecompressedSequences: BlockSizePrefix mismatch` (`main.cpp:414`) | sequence decode diverged |
| `symMiss` | `0` | final symbols are byte-identical to the reference (spread & final symbols correct) |
| FseInfo / FseProb / FseElem diff | `info=0 prob=0 elem=1` | only the packed `FseElem` differs |
| `nstate` error | off by **exactly `1<<bitcnt`** | per-symbol rank (`prefix`) off by **exactly 1** |
| Direction | either way (tst higher or lower) | consistent with a single flipped ballot bit |
| `cmpBlock` (first bad block) | varies run-to-run (27, 598, 789, 1705, 1842, …) | **non-deterministic → a race** |
| Channels | ch0=LL, ch1=OF, ch2=ML all seen | not table-specific |
| Reproduces on | **GTX 1060 (Pascal)** only; not CPU-sim, not on dev GPUs | weak-memory + multi-wave specific |

The `nstate` formula is `nstate = ((prefix + prob) << bitcnt) - tblAllDataCount`,
so a rank error of ±1 shifts `nstate` by exactly `1<<bitcnt` — matching the signature.

## Root cause

The DEFAULT FSE-table method has two phases inside one dispatch:

1. **Spread** — scatters each symbol to its slot in the `inoutFseElems` UAV.
2. **Transpose (rank/nstate)** — LOOP A reads each slot's symbol and does a
   per-bit `WaveActiveBallot`, storing the ballots to LDS; LOOP B popcounts those
   ballots to derive each symbol's rank (`prefix`) and final `nstate`.

Between the two phases there is only:

```hlsl
GroupMemoryBarrierWithGroupSync();
```

`GroupMemoryBarrierWithGroupSync` synchronizes the threadgroup and orders **LDS**
memory, but it does **not** guarantee that UAV / device-memory writes made by one
wave are visible to a *different* wave. When the threadgroup spans multiple waves,
the wave running the transpose may observe a **stale symbol** for a slot written by
another wave during spread. That single stale read flips one ballot bit, which
moves the popcounted rank by 1, which corrupts `nstate`.

The original author already flagged this in a comment near the spread write
(`zstdgpu_shaders.h`, ~line 1710): symbols are written straight to the buffer
"instead of storing them to LDS temporally **which would be the right thing to
do**" — done to save up to 512 dwords of LDS and improve occupancy on Scarlett.
On a strong-memory / single-wave target that shortcut is safe; on multi-wave
Pascal it is not.

## Why Pascal-only and multi-wave-only

`IS_MULTI_WAVE` is a **compile-time** constant (`ZstdGpuInitFseTable.hlsl:33-40`):

```
kzstdgpu_WaveCountMax_InitFseTable = kzstdgpu_TgSizeX_InitFseTable / kzstdgpu_WaveSize_Min
IS_MULTI_WAVE = (kzstdgpu_WaveCountMax_InitFseTable > 1) || (PREFER_LDS == 1)
```

* **PC:** `128 / 4 = 32 > 1` → `IS_MULTI_WAVE = 1` (keys off the *minimum* supported
  wave size, so every PC build compiles the multi-wave path regardless of the GPU).
* **Scarlett / Xbox One:** `64 / 64 = 1` → `IS_MULTI_WAVE = 0` (single-wave path).

On Pascal the hardware wave is **32 lanes** and the threadgroup is **128 threads**,
so each group is **4 waves** and genuinely exercises the cross-wave handoff. Pascal
also has a comparatively **weak memory model**, so the missing cross-wave UAV
ordering actually surfaces. Stronger-ordering or differently-scheduled GPUs may run
the same DXIL without ever exposing the stale read.

CPU simulation (`--sim-gpu` / `--chk-cpu`) never reproduces it: `FOR_WORK_ITEMS` is a
single-threaded sequential loop in the sim, so the multi-wave ballot/transpose path
is never taken.

## The fix

Keep the symbol handoff **in LDS**, ordered by the existing
`GroupMemoryBarrierWithGroupSync` (which *is* reliable for LDS across waves on every
GPU):

```hlsl
#if IS_MULTI_WAVE && (ZSTD_BITCNT_NSTATE_METHOD == ZSTD_BITCNT_NSTATE_METHOD_DEFAULT)
        zstdgpu_LdsStoreU32(GS_SpreadSymbols + i, symbol);          // hand off through LDS
#else
        srt.inoutFseElems[...] = zstdgpu_PackFseElem(symbol, 0, 0); // write the UAV
#endif
```

* Adds a `GS_SpreadSymbols` LDS region (up to `kzstdgpu_MaxCount_FseElems` = 512
  dwords ≈ 2 KB), allocated only when `IS_MULTI_WAVE`.
* The transpose reads the symbol from `GS_SpreadSymbols` on the multi-wave DEFAULT
  path, and from the UAV otherwise — so **exactly one** spread write happens per
  `{wave-width × method}` configuration and it is always the medium the reader
  consumes (no dead store).
* Single-wave targets (Scarlett/Xbox, `IS_MULTI_WAVE = 0`) and the
  REFERENCE/EXPERIMENTAL methods are byte-for-byte unchanged and keep the
  occupancy-optimal direct-to-UAV path.

Fix commits: **`51a8e56`** (original LDS handoff) and **`e5ba8d3`** (fused, with the
"single spread write per configuration" cleanup), on branch
**`zstdgpu-fix-fse-lds-handoff-no-dup-write`**.

## Failed fix attempts (do not repeat)

All three tried to make the **UAV round-trip** coherent; all failed on Pascal with
the identical signature:

1. **Barrier upgrade** `GroupMemoryBarrierWithGroupSync` → `AllMemoryBarrierWithGroupSync`
   at the spread→transpose boundary — *reduced but did not eliminate* the failure.
2. **Atomic read** on the transpose (`InterlockedAdd(uav, 0, out)`) — no effect.
3. **Atomic write** on spread (`InterlockedExchange`) — no effect, and combining
   read+write atomics made the failure rate **worse**.

Why they failed: on Pascal, UAV atomics are serviced by the L2 atomic units, a
different path than ordinary (L1) loads. Mixing atomic writes with normal reads
*increased* incoherence rather than fixing it. The robust answer is to **avoid the
cross-wave UAV handoff entirely** (use LDS), not to strengthen it.

---

## Reproducing on the GTX 1080 (further analysis)

The GTX 1080 is also Pascal (GP104, 32-lane waves, same weak memory model as the
1060's GP106), so the baseline (unfixed) build is expected to reproduce the race and
the LDS-handoff build is expected to fix it.

### Build & deploy

```
:: from zstd\  (after vcvars64.bat)
msbuild zstd.sln /t:zstdgpu_demo /p:Configuration=Release /p:Platform=x64 /m
```

Copy `zstdgpu_demo.exe` plus its runtime DLLs
(`dstorage.dll`, `dstoragecore.dll`, `dxcompiler.dll`, `dxil.dll`,
`WinPixEventRuntime.dll`) to the Pascal box.

### Single-file loop (fastest manual repro)

```
zstdgpu_demo.exe --zst <file> --run-cnt 10 --idx-max 200 --chk-gpu
```

A single run often passes — loop it. Known-sensitive content:

* `BC7mip0_part02`, `BC7mip0_part03`, `BC7mip0_part17`
* `BC1mip0_part02`
* `LargeRocks_albedo`
* `redLadybug_outShell_normal`

### Repro harness

`zstd/zstdgpu_ci_tests/Repro-FlakySeq.ps1` replays the failing invocations and loops
the whole group to surface the non-deterministic failure:

```
.\Repro-FlakySeq.ps1 -Iterations 20
.\Repro-FlakySeq.ps1 -DemoPath C:\path\zstdgpu_demo.exe -ContentRoot C:\path\zstd_content
.\Repro-FlakySeq.ps1 -Scenario '--chk-gpu --seq-cnt'
```

> Note: the harness header still describes an *early* hypothesis (a prefix-scan race
> in `ZstdGpuPrefixSequenceOffsets.hlsl`). That predates the final analysis — the
> confirmed root cause is the FSE-table symbol handoff documented here. The harness
> is still a valid, content-driven way to surface the flaky failure.

### Diagnostic build (this branch)

This branch's instrumented validator (`zstd/zstdgpu/zstdgpu_reference_store.cpp`)
prints per-failure `symMiss` / `stMiss` / `elemCells` decode so you can confirm the
signature (`symMiss=0`, `nstate` off by `1<<bitcnt`) rather than just an exit code.

### Useful shader toggles (`ZstdGpuInitFseTable.hlsl`)

* `PREFER_LDS` (line 35): set to `1` to force `IS_MULTI_WAVE` even where the wave math
  would otherwise be single-wave — useful to widen exposure.
* `ZSTD_BITCNT_NSTATE_METHOD` (line 23): switch between `REFERENCE` (0),
  `DEFAULT` (1), `EXPERIMENTAL` (2). REFERENCE avoids the ballot/LDS transpose and is
  a good A/B to confirm the race lives in the DEFAULT transpose path.

Remember to force a shader recompile (touch the `.hlsl`, or delete
`x64\Release\Shaders\*.h`) after changing a toggle.

---

## Related observations / open questions

* **AMD RX 9070 (CI):** CI run `143` produced the *same*
  `Validate_DecompressedSequences` signature on 72 large `mip0` textures (576
  failures across GPU scenarios); a rerun `218` on the same GPU passed all of them.
  It is not yet established whether `218` used the *same* build (→ the failure is
  flaky and the race may not be fully closed on that part) or a *different/corrected*
  build. If a Pascal part with the fixed build ever still fails, that would point to
  residual race behavior beyond the symbol handoff.
* **Confirm the fix on Pascal:** run the baseline vs. LDS-handoff builds side by side
  on the 1080 across the sensitive content with high `--run-cnt` to establish the
  before/after failure rate.

## References

* Fix commits: `51a8e56` (original), `e5ba8d3` (fused). Branch:
  `zstdgpu-fix-fse-lds-handoff-no-dup-write`.
* Diagnostics / toggles / repro (this branch): `zstdgpu-fse-multiwave-wip`.
* Key files:
  * `zstd/zstdgpu/zstdgpu_shaders.h` — `zstdgpu_ShaderEntry_InitFseTable`: spread
    writes (~1719 / ~1824), transpose LOOP A/B, `GS_SpreadSymbols` LDS region.
  * `zstd/zstdgpu/Shaders/ZstdGpuInitFseTable.hlsl` — `IS_MULTI_WAVE`,
    `PREFER_LDS`, `ZSTD_BITCNT_NSTATE_METHOD`.
  * `zstd/zstdgpu/zstdgpu_reference_store.cpp` — instrumented validator.
  * `zstd/zstdgpu_ci_tests/Repro-FlakySeq.ps1` — repro harness.
  * `zstd/zstdgpu_demo/main.cpp:414` — `Validate_DecompressedSequences`.
