# ZStandard (zstd)
ZStandard is a fast lossless compression algorithm,
targeting real-time compression scenarios at zlib-level and better compression ratios. Zstandard's format is stable and documented in [RFC8878](https://datatracker.ietf.org/doc/html/rfc8878).

Source code for the zstd cpu compressor and decompressor can be found on the [zstd github Repository Page](https://github.com/facebook/zstd)

# ZSTD decompression shaders
This sample includes reference implementations of shaders that are designed to perform zstd decompression using a GPU.  These shaders are all authored in HLSL and support a wide variety of GPUs.

<span style="color:red;font-size:20px; font-weight:bold;">
This code is currently in development and should NOT be used in production environments or for released products.</span>

Once development has been completed and the shader meets production quality standards, the sample code will be moved into the MAIN branch.

Versions of these same shaders are also included/compiled inside the DirectStorage runtime to be used as a fallback for GPUs that do not have optimized zstd GPU decompression driver support.  Most game ready GPU drivers will come with their own optimized decompression support which is faster and more efficient than this implementation.

![ZSTDGPU Preview](zstd.png)


# Build
Install latest [Visual Studio](http://www.visualstudio.com/downloads).

Open the following Visual Studio solution and build
```
zstd\zstd.sln
```

# Usage
Example usage
```
zstd\x64\Debug\zstdgpu_demo.exe --zst <file to decompress>>
```

## CPU API timing diagnostics

This diagnostic branch emits one `[CPU-TIMING]` summary and a fixed set of phase
rows at the end of each demo process, without additional arguments or environment
variables. CI captures these on stdout alongside the existing demo output.
Use the same built executable, inputs and arguments for the CI/manual comparison.

`D3D12CreateDevice`, the reference `ZSTD_decompress`, `CreateRootSignature` and
`CreateComputePipelineState` are measured separately. Shader bytecode is compiled
at build time; the PSO call measures runtime driver/PSO creation, not DXC.
`max_detail` identifies the shader with the longest root-signature or PSO call.
`command_close_and_submit` includes command-list Close, ExecuteCommandLists and
Signal, capturing deferred driver/GBV work separately from `gpu_wait`.

The remaining rows cover startup/arguments, file loading, frame/batch preparation,
platform/debug-layer setup, queue setup, reference allocation/zeroing, CPU shader
replay, persistent/request resource setup, command recording, readback/validation,
statistics/output and cleanup. Phases are **exclusive**: their `wall_ms` values sum
to the summary's `wall_ms`; do not add that summary a second time. `segments` counts
visits to a phase (API calls for the API rows); `first_ms` and `max_ms` distinguish
first-use costs from repeated work. Unused phases have zero segments.

Wall times use QueryPerformanceCounter and include blocking/descheduling.
`cpu_user_ms` and `cpu_kernel_ms` use GetProcessTimes, covering all process threads;
they can exceed wall time when multiple threads work concurrently and have coarse
resolution for short intervals. Counter failures are reported explicitly.
Sampling overhead is included in the phases; no timing output occurs until the
summary, whose formatting/output time is excluded. Other library consumers do
not enable the recorder.

Coverage starts at the demo entry point and ends after cleanup, excluding the
loader/CRT work before entry and process teardown after the summary. Normal and
caught-assert returns report `completion=main_return` and the exit code. The CPU
decoder's direct `exit(1)` also emits a summary through `atexit`, marked
`completion=early_exit exit_code=unknown`; its active phase includes the error
handling/exit path and did not finish normally. Crashes or forced termination
(including a CI timeout) cannot guarantee a summary.

## Related links
* https://aka.ms/directstorage
* [DirectX Landing Page](https://devblogs.microsoft.com/directx/landing-page/)
* [Discord server](http://discord.gg/directx)
* [PIX on Windows](https://devblogs.microsoft.com/pix/documentation/)
