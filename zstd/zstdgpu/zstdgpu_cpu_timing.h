// Copyright (c) Microsoft. All rights reserved.
// Licensed under the MIT License.
#pragma once

#include <Windows.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

namespace zstdgpu_CpuTiming
{
enum class Phase
{
    Startup,
    InputLoad,
    InputSetup,
    PlatformSetup,
    CreateDevice,
    DeviceQueueSetup,
    ReferenceSetup,
    ReferenceDecompress,
    CpuReplay,
    PersistentSetup,
    RootSignature,
    PipelineState,
    RequestSetup,
    BatchSetup,
    CommandRecording,
    CloseAndSubmit,
    GpuWait,
    ReadbackValidation,
    StatisticsOutput,
    Cleanup,
    Count
};

struct Token
{
    Phase phase;
    const wchar_t *detail;
};

struct Sample
{
    LONGLONG wall;
    uint64_t user;
    uint64_t kernel;
};

struct Stat
{
    uint64_t segments;
    Sample total;
    LONGLONG first;
    LONGLONG maximum;
    const wchar_t *maxDetail;
};

struct State
{
    bool active;
    DWORD thread;
    DWORD clockError;
    DWORD cpuError;
    LONGLONG frequency;
    Token current;
    Sample begin;
    Sample last;
    Stat stats[static_cast<unsigned>(Phase::Count)];
};

inline State &GetState()
{
    static State state = {};
    return state;
}

inline uint64_t FileTimeValue(FILETIME value)
{
    return (static_cast<uint64_t>(value.dwHighDateTime) << 32) | value.dwLowDateTime;
}

inline Sample Capture()
{
    State &state = GetState();
    const DWORD savedError = GetLastError();
    LARGE_INTEGER now = {};
    if (!QueryPerformanceCounter(&now))
        state.clockError = GetLastError() ? GetLastError() : ERROR_GEN_FAILURE;
    FILETIME creation = {}, exit = {}, kernel = {}, user = {};
    if (!GetProcessTimes(GetCurrentProcess(), &creation, &exit, &kernel, &user))
        state.cpuError = GetLastError() ? GetLastError() : ERROR_GEN_FAILURE;
    SetLastError(savedError);
    return {now.QuadPart, FileTimeValue(user), FileTimeValue(kernel)};
}

inline void Accumulate(Sample now)
{
    State &state = GetState();
    Stat &stat = state.stats[static_cast<unsigned>(state.current.phase)];
    const LONGLONG elapsed = now.wall - state.last.wall;
    if (stat.segments == 0)
        stat.first = elapsed;
    ++stat.segments;
    stat.total.wall += elapsed;
    if (state.cpuError == ERROR_SUCCESS)
    {
        stat.total.user += now.user - state.last.user;
        stat.total.kernel += now.kernel - state.last.kernel;
    }
    if (elapsed > stat.maximum)
    {
        stat.maximum = elapsed;
        stat.maxDetail = state.current.detail;
    }
    state.last = now;
}

// Explicit, trivially destructible tokens also work across the demo's longjmp
// assertion path. A caught assertion is closed by the next Cleanup marker.
inline Token Mark(Phase phase, const wchar_t *detail = NULL)
{
    State &state = GetState();
    const Token previous = state.current;
    if (state.active && state.thread == GetCurrentThreadId())
    {
        Accumulate(Capture());
        state.current = {phase, detail};
    }
    return previous;
}

inline void Restore(Token token)
{
    Mark(token.phase, token.detail);
}

inline const wchar_t *PhaseName(Phase phase)
{
    static const wchar_t *const names[] = {
        L"startup_arguments", L"input_load", L"input_scan_and_batch_setup",
        L"platform_setup", L"D3D12CreateDevice", L"device_queue_setup",
        L"reference_setup", L"ZSTD_decompress", L"cpu_shader_replay",
        L"persistent_context_setup", L"CreateRootSignature", L"CreateComputePipelineState",
        L"request_resources_setup", L"batch_setup", L"command_recording",
        L"command_close_and_submit", L"gpu_wait", L"readback_validation",
        L"statistics_and_output", L"cleanup"
    };
    static_assert(_countof(names) == static_cast<unsigned>(Phase::Count), "Missing timing phase name");
    return names[static_cast<unsigned>(phase)];
}

inline void PrintCpu(Sample value)
{
    if (GetState().cpuError == ERROR_SUCCESS)
        wprintf(L" cpu_user_ms=%.6f cpu_kernel_ms=%.6f",
                static_cast<double>(value.user) / 10000.0, static_cast<double>(value.kernel) / 10000.0);
    else
        wprintf(L" cpu_user_ms=unavailable cpu_kernel_ms=unavailable");
}

inline void Finish(bool exitCodeKnown, int exitCode)
{
    State &state = GetState();
    if (!state.active)
        return;
    const Sample end = Capture();
    Accumulate(end);
    state.active = false;
    wprintf(L"[CPU-TIMING] summary version=1 pid=%lu completion=%ls active_phase=%ls",
            GetCurrentProcessId(), exitCodeKnown ? L"main_return" : L"early_exit", PhaseName(state.current.phase));
    if (exitCodeKnown)
        wprintf(L" exit_code=%d", exitCode);
    else
        wprintf(L" exit_code=unknown");
    if (state.clockError != ERROR_SUCCESS || state.frequency <= 0)
    {
        wprintf(L" wall_ms=unavailable clock_error=%lu\n", state.clockError);
        fflush(stdout);
        return;
    }
    const double toMs = 1000.0 / static_cast<double>(state.frequency);
    const Sample total = {end.wall - state.begin.wall, end.user - state.begin.user, end.kernel - state.begin.kernel};
    wprintf(L" wall_ms=%.6f", static_cast<double>(total.wall) * toMs);
    PrintCpu(total);
    wprintf(L" cpu_error=%lu coverage=main_to_summary\n", state.cpuError);
    for (unsigned i = 0; i < static_cast<unsigned>(Phase::Count); ++i)
    {
        const Stat &stat = state.stats[i];
        wprintf(L"[CPU-TIMING] phase=%ls segments=%llu wall_ms=%.6f first_ms=%.6f max_ms=%.6f",
                PhaseName(static_cast<Phase>(i)), static_cast<unsigned long long>(stat.segments),
                static_cast<double>(stat.total.wall) * toMs, static_cast<double>(stat.first) * toMs,
                static_cast<double>(stat.maximum) * toMs);
        PrintCpu(stat.total);
        if (stat.maxDetail != NULL)
            wprintf(L" max_detail=\"%ls\"", stat.maxDetail);
        wprintf(L"\n");
    }
    fflush(stdout);
}

inline void AtExit()
{
    Finish(false, 0);
}

inline void Begin()
{
    State &state = GetState();
    state = {};
    state.thread = GetCurrentThreadId();
    state.current = {Phase::Startup, NULL};
    LARGE_INTEGER frequency = {};
    if (!QueryPerformanceFrequency(&frequency))
        state.clockError = GetLastError() ? GetLastError() : ERROR_GEN_FAILURE;
    state.frequency = frequency.QuadPart;
    state.begin = state.last = Capture();
    state.active = true;
    // The educational CPU decoder calls exit(1) on malformed input.
    if (atexit(AtExit) != 0)
        fwprintf(stderr, L"[CPU-TIMING] error=atexit_registration_failed early_exit_summary_unavailable\n");
}
}
