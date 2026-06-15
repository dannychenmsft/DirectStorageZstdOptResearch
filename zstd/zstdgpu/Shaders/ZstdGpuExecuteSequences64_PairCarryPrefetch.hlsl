/**
 * ZstdGpuExecuteSequences64_PairCarryPrefetch.hlsl
 *
 * NVIDIA-only specialisation of the execute-sequences compute shader. Identical to
 * ZstdGpuExecuteSequences64 except it enables ZSTDGPU_EXECSEQ_PAIR_CARRY_PREFETCH, which deepens the
 * per-pair metadata software-pipeline in zstdgpu_ExecuteSequences_Lit (carry both sequences of the
 * 2x-unrolled pair across the loop backedge and prefetch the next pair's full {MLen,LLen,Offs}). This is
 * a measured win on NVIDIA (RTX 4080 SUPER) but regresses AMD RDNA3, so only the NVIDIA VendorId path in
 * zstdgpu.cpp maps ExecuteSequences to this kernel; all other vendors keep ZstdGpuExecuteSequences64.
 *
 * Copyright (c) Microsoft. All rights reserved.
 * This code is licensed under the MIT License (MIT).
 * THIS CODE IS PROVIDED *AS IS* WITHOUT WARRANTY OF
 * ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING ANY
 * IMPLIED WARRANTIES OF FITNESS FOR A PARTICULAR
 * PURPOSE, MERCHANTABILITY, OR NON-INFRINGEMENT.
 *
 * Advanced Technology Group (ATG)
 * Author(s):   Pavel Martishevsky (pamartis@microsoft.com)
 */

#define MAX_COPY_SIZE 64
#define ZSTDGPU_EXECSEQ_PAIR_CARRY_PREFETCH 1
#include "ZstdGpuExecuteSequences.hlsli"
