/**
 * Copyright (c) Microsoft. All rights reserved.
 * This code is licensed under the MIT License (MIT).
 * THIS CODE IS PROVIDED *AS IS* WITHOUT WARRANTY OF
 * ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING ANY
 * IMPLIED WARRANTIES OF FITNESS FOR A PARTICULAR
 * PURPOSE, MERCHANTABILITY, OR NON-INFRINGEMENT.
 */

// CPU-only tests for the scratch buffer sizing in zstdgpu_resources.h. They are in their own translation unit
// because libzstdgpu.h defines ZSTDGPU_ALIGN_DEFAULT differently.

#define ZSTDGPU_DISABLE_RESOURCE_DATA_GPU 1

#include <stdint.h>

#include "zstdgpu_resources.h"

#include <gtest/gtest.h>

namespace
{
    zstdgpu_ResourceInfo InitAllStages(uint32_t frameCount,
                                       uint32_t compressedByteCount,
                                       uint32_t rawBlockCount,
                                       uint32_t rleBlockCount,
                                       uint32_t cmpBlockCount,
                                       uint32_t literalByteCount,
                                       uint32_t sequenceCount,
                                       uint32_t uncompressedByteCount)
    {
        zstdgpu_ResourceInfo info = {};
        zstdgpu_ResourceInfo_InitZero(&info);
        zstdgpu_ResourceInfo_Stage_0_Init(&info, frameCount, compressedByteCount, 0u);
        zstdgpu_ResourceInfo_Stage_1_Init(&info, rawBlockCount, rleBlockCount, cmpBlockCount);
        zstdgpu_ResourceInfo_Stage_2_Init(&info, literalByteCount, sequenceCount, uncompressedByteCount, frameCount);
        return info;
    }
} // namespace

// Each case makes one buffer too large for 32 bits. Its byte size used to wrap to a small value, so the stage that
// owns it looked small enough to allocate. The size now saturates, which pushes that stage to at least the scratch
// ceiling, where zstdgpu rejects it. The other stages stay below the ceiling.
TEST(ScratchSizingTests, OverflowingByteSizesSaturate)
{
    struct Case
    {
        const char* name;
        uint32_t frameCount;
        uint32_t compressedByteCount;
        uint32_t literalByteCount;
        uint32_t sequenceCount;
        uint32_t stageIndex;
        uint32_t zstdgpu_ResourceInfo::*byteSizeInternal;
    };

    const Case cases[] = {
        {"compressed data", 4096u, 0xFFFFFFFFu, 1u, 1u, 0u, &zstdgpu_ResourceInfo::CompressedData_ByteSizeInternal},
        {"frame references", 0x40000000u, 1u << 24, 1u, 1u, 0u, &zstdgpu_ResourceInfo::FramesRefs_ByteSizeInternal},
        {"decompressed literals", 4096u, 1u << 24, 0xFFFFFFFEu, 1u, 2u, &zstdgpu_ResourceInfo::DecompressedLiterals_ByteSizeInternal},
        {"decompressed sequences", 4096u, 1u << 24, 1u, 0x40000000u, 2u, &zstdgpu_ResourceInfo::DecompressedSequenceLLen_ByteSizeInternal},
    };

    for (const Case& c : cases)
    {
        SCOPED_TRACE(c.name);

        const zstdgpu_ResourceInfo info =
            InitAllStages(c.frameCount, c.compressedByteCount, 0u, 0u, 1u, c.literalByteCount, c.sequenceCount, 1u << 24);
        EXPECT_EQ(info.*(c.byteSizeInternal), 0xFFFFFFFFu);

        for (uint32_t stage = 0; stage < kzstdgpu_ResourceAllocation_StageCount; ++stage)
        {
            if (stage == c.stageIndex)
            {
                EXPECT_GE(info.gpuOnly_ByteCount[stage], kzstdgpu_MaxScratchHeapByteCount) << "stage " << stage;
            }
            else
            {
                EXPECT_LT(info.gpuOnly_ByteCount[stage], kzstdgpu_MaxScratchHeapByteCount) << "stage " << stage;
            }
        }
    }
}

// FseElems holds 1,408 elements per compressed block. The cases are the largest block count whose FseElems byte size
// fits in 32 bits, the smallest one whose byte size saturates (it used to wrap to 2,048 bytes), and one large enough
// to saturate the FseElems element count too. Stage 1 needs at least the scratch ceiling in all three cases.
TEST(ScratchSizingTests, FseTableByteSizesSaturate)
{
    struct Case
    {
        uint32_t cmpBlockCount;
        uint32_t fseElemsCount;
        uint32_t fseElemsByteSize;
        uint32_t fseProbsByteSize;
    };

    const Case cases[] = {
        {762599u, 1073740928u, 4294963712u, 390451072u},
        {762600u, 1073742336u, 0xFFFFFFFFu, 390451584u},
        {8388608u, 0xFFFFFFFFu, 0xFFFFFFFFu, 0xFFFFFFFFu},
    };

    for (const Case& c : cases)
    {
        SCOPED_TRACE(c.cmpBlockCount);

        const zstdgpu_ResourceInfo info =
            InitAllStages(4096u, 1u << 24, 0u, 0u, c.cmpBlockCount, 1u << 20, 1u << 16, 1u << 24);
        EXPECT_EQ(info.FseElems_Count, c.fseElemsCount);
        EXPECT_EQ(info.FseElems_ByteSize, c.fseElemsByteSize);
        EXPECT_EQ(info.FseElems_ByteSizeInternal, info.FseElems_ByteSize);
        EXPECT_EQ(info.FseProbs_ByteSize, c.fseProbsByteSize);

        EXPECT_LT(info.gpuOnly_ByteCount[0], kzstdgpu_MaxScratchHeapByteCount);
        EXPECT_GE(info.gpuOnly_ByteCount[1], kzstdgpu_MaxScratchHeapByteCount);
        EXPECT_LT(info.gpuOnly_ByteCount[2], kzstdgpu_MaxScratchHeapByteCount);
    }
}
