/**
 * ZstdGpuDecompressSequences_SingleStream_ScalarFseLoad32.hlsl
 *
 * A variant of the compute shader decompressessing FSE-compressed sequences
 * without pre-caching FSE tables into LDS, reading directly from the buffer.
 * Targets hardware with maximal supported wave size of 32 lanes.
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

#define kzstdgpu_DecompressSequences_SingleStream_NoLdsFseCache 1
#define kzstdgpu_TgSizeX_DecompressSequences_SingleStream 32
// AMD-selected sequence-decode kernel (the VendorId==0x1002 branch in zstdgpu.cpp maps DecompressSequences
// here). Enable the vendor-gated scalar-broadcast FSE gather: a measured AMD/RDNA3 throughput win
// (+2.0%, RX 7900 XTX) that does not transfer to other vendors, which run the LDS-FSE-cache kernels.
#define ZSTDGPU_FSE_SCALAR_BROADCAST 1
#include "ZstdGpuDecompressSequences_SingleStream.hlsli"
