/**
 * ZstdGpuExecuteSequences64_PairCarryPrefetch.hlsl
 *
 * A specialisation for the compute shader that executes sequences. Identical output to
 * ZstdGpuExecuteSequences64, but with a deeper sequence-metadata prefetch: both sequences of the
 * current pair are carried across the loop backedge while the entire next pair is prefetched. This
 * is vendor-gated to NVIDIA (see the ExecuteSequences kernel selection in zstdgpu.cpp): it improves
 * throughput on NVIDIA but regresses AMD RDNA3.
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
