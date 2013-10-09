/******************************************************************************
 * Copyright (c) 2011, Duane Merrill.  All rights reserved.
 * Copyright (c) 2011-2013, NVIDIA CORPORATION.  All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions are met:
 *     * Redistributions of source code must retain the above copyright
 *       notice, this list of conditions and the following disclaimer.
 *     * Redistributions in binary form must reproduce the above copyright
 *       notice, this list of conditions and the following disclaimer in the
 *       documentation and/or other materials provided with the distribution.
 *     * Neither the name of the NVIDIA CORPORATION nor the
 *       names of its contributors may be used to endorse or promote products
 *       derived from this software without specific prior written permission.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
 * ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
 * WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
 * DISCLAIMED. IN NO EVENT SHALL NVIDIA CORPORATION BE LIABLE FOR ANY
 * DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
 * (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
 * LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
 * ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
 * SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 *
 ******************************************************************************/

/******************************************************************************
 * An implementation of segmented reduction using a load-balanced parallelization
 * strategy based on the MergePath decision path.
 ******************************************************************************/

// Ensure printing of CUDA runtime errors to console
#define CUB_STDERR

#include <iterator>
#include <vector>
#include <string>
#include <algorithm>
#include <stdio.h>

#include <cub/cub.cuh>

#include "../../test/test_util.h"

using namespace cub;
using namespace std;


/******************************************************************************
 * Globals, constants, and typedefs
 ******************************************************************************/

bool                    g_verbose       = false;
int                     g_iterations    = 1;
CachingDeviceAllocator  g_allocator;


/******************************************************************************
 * Utility routines
 ******************************************************************************/


/**
 * Computes the begin offsets into A and B for the specified
 * location (diagonal) along the merge decision path
 */
template <
    typename    IteratorA,
    typename    IteratorB,
    typename    SizeT>
__device__ __forceinline__ void MergePathSearch(
    SizeT       diagonal,
    IteratorA   a,
    SizeT       a_begin,
    SizeT       a_end,
    SizeT       &a_offset,
    IteratorB   b,
    SizeT       b_begin,
    SizeT       b_end,
    SizeT       &b_offset)
{
    SizeT split_min = CUB_MAX(diagonal - b_end, a_begin);
    SizeT split_max = CUB_MIN(diagonal, a_end);

    while (split_min < split_max)
    {
        SizeT split_pivot = (split_min + split_max) >> 1;
        if (a[split_pivot] <= b[diagonal - split_pivot - 1])
        {
            // Move candidate split range up A, down B
            split_min = split_pivot + 1;
        }
        else
        {
            // Move candidate split range up B, down A
            split_max = split_pivot;
        }
    }

    a_offset = split_min;
    b_offset = CUB_MIN(diagonal - split_min, b_end);
}



/******************************************************************************
 * Persistent thread block types
 ******************************************************************************/

/**
 * \brief BlockSegmentedReduceTiles implements a stateful abstraction of CUDA thread blocks for participating in device-wide segmented reduction.
 */
template <
    int                     BLOCK_THREADS,
    int                     ITEMS_PER_THREAD,
    bool                    CACHE_SEGMENT_OFFSETS,
    bool                    CACHE_ITEMS,
    BlockReduceAlgorithm    REDUCE_ALGORITHM,
    BlockScanAlgorithm      SCAN_ALGORITHM,
    typename                ValueIterator,
    typename                SegmentOffsetIterator,
    typename                OutputIterator,
    typename                ReductionOp>
struct BlockSegmentedReduceTiles
{
    //---------------------------------------------------------------------
    // Types and constants
    //---------------------------------------------------------------------

    // Constants
    enum
    {
        /// Number of work items to be processed per tile
        TILE_ITEMS = BLOCK_THREADS * ITEMS_PER_THREAD,
    };

    // Offset type
    typedef typename std::iterator_traits<SegmentOffsetIterator>::value_type SizeT;

    // Value type
    typedef typename std::iterator_traits<ValueIterator>::value_type Value;

    // Counting iterator type
    typedef CountingInputIterator<SizeT, SizeT> CountingIterator;

    // Tail flag type for marking segment discontinuities
    typedef int TailFlag;

    // BlockScan data type of (segment-id, value) tuples for reduction-by-segment
    typedef KeyValuePair<SizeT, Value> KeyValuePair;

    // BlockScan scan operator for reduction-by-segment
    typedef ReduceByKeyOp<ReductionOp> ScanOp;

    // Stateful BlockScan prefix callback type for managing a running total while scanning consecutive tiles
    typedef RunningBlockPrefixCallbackOp<
            KeyValuePair,
            ReductionOp>
        RunningPrefixCallbackOp;

    // Parameterized BlockReduce type for block-wide reduction
    typedef BlockReduce<
            Value,
            BLOCK_THREADS,
            REDUCE_ALGORITHM>
        BlockReduce;

    // Parameterized BlockScan type for block-wide reduce-value-by-key
    typedef BlockScan<
            KeyValuePair,
            BLOCK_THREADS,
            SCAN_ALGORITHM>
        BlockScan;

    // Shared memory type for this threadblock
    struct _TempStorage
    {
        union
        {
            // Smem needed for BlockScan
            typename BlockScan::TempStorage     scan;

            // Smem needed for BlockReduce
            typename BlockReduce::TempStorage   reduce;

            struct
            {
                SizeT block_segment_idx[2];     // The starting and ending indices of segment offsets for the threadblock's region
                SizeT block_value_idx[2];       // The starting and ending indices of values for the threadblock's region

                // Smem needed for communicating start/end indices between threads for a given work tile
                SizeT thread_segment_idx[BLOCK_THREADS + 1];
                Value thread_value_idx[BLOCK_THREADS + 1];
            };
        };

        // The first partial reduction tuple scattered by this thread block
        KeyValuePair first_partial;
    };


    // Alias wrapper allowing storage to be unioned
    struct TempStorage : Uninitialized<_TempStorage> {};


    //---------------------------------------------------------------------
    // Thread fields
    //---------------------------------------------------------------------

    _TempStorage            &temp_storage;          ///< Reference to temporary storage
    SizeT                   num_values;             ///< Total number of values to reduce
    SizeT                   num_segments;           ///< Number of segments to reduce
    ValueIterator           d_values;               ///< Input pointer to an array of \p num_values values
    CountingIterator        d_value_offsets;        ///< Input pointer to an array of \p num_values value-offsets
    SegmentOffsetIterator   d_segment_end_offsets;  ///< Input pointer to an array of \p num_segments segment end-offsets
    OutputIterator          d_output;               ///< Output pointer to an array of \p num_segments segment totals
    KeyValuePair            *d_block_partials;      ///< Output pointer to an array of (gridDim.x * 2) partial reduction tuples
    Value                   identity;               ///< Identity value (for zero-length segments)
    ReductionOp             reduction_op;           ///< Reduction operator
    RunningPrefixCallbackOp prefix_op;              ///< Stateful running total for block-wide prefix scan of partial reduction tuples


    //---------------------------------------------------------------------
    // Operations
    //---------------------------------------------------------------------

    /**
     * Constructor
     */
    __device__ __forceinline__
    BlockSegmentedReduceTiles(
        TempStorage             &temp_storage,          ///< Reference to temporary storage
        SizeT                   num_values,             ///< Number of values to reduce
        SizeT                   num_segments,           ///< Number of segments to reduce
        ValueIterator           d_values,               ///< Input pointer to an array of \p num_values values
        SegmentOffsetIterator   d_segment_end_offsets,  ///< Input pointer to an array of \p num_segments segment end-offsets
        OutputIterator          d_output,               ///< Output pointer to an array of \p num_segments segment totals
        KeyValuePair            *d_block_partials,      ///< Output pointer to an array of (gridDim.x * 2) partial reduction tuples
        Value                   identity,               ///< Identity value (for zero-length segments)
        ReductionOp             reduction_op)           ///< Reduction operator
    :
        temp_storage(temp_storage.Alias()),
        num_values(num_values),
        num_segments(num_segments),
        d_values(d_values),
        d_value_offsets(0),
        d_segment_end_offsets(d_segment_end_offsets),
        d_output(d_output),
        d_block_partials(d_block_partials),
        identity(identity),
        reduction_op(reduction_op)
    {}


    /**
     * Process the specified region of the MergePath decision path
     */
    __device__ __forceinline__ void ProcessRegion(
        SizeT block_diagonal,
        SizeT next_block_diagonal)
    {
        // Thread block initialization
        if (threadIdx.x < 2)
        {
            // Select whether to search for starting/ending diagonal
            int diagonal = (threadIdx.x == 0) ?
                block_diagonal :        // First thread searches for start indices
                next_block_diagonal;    // Second thread searches for end indices

            // Search for block starting and ending indices
            SizeT block_segment_idx;
            SizeT block_value_idx;

            MergePathSearch(
                diagonal,               // Diagonal
                d_segment_end_offsets,  // A (segment end-offsets)
                0,                      // Start index into A
                num_segments,           // End index into A
                block_segment_idx,      // [out] Block index into A
                d_value_offsets,        // B (value offsets)
                0,                      // Start index into B
                num_values,             // End index into B
                block_value_idx);       // [out] Block index into B

            // Share block starting and ending indices
            temp_storage.block_segment_idx[threadIdx.x] = block_segment_idx;
            temp_storage.block_value_idx[threadIdx.x] = block_value_idx;

            // Initialize the block's running prefix operator
            if (threadIdx.x == 0)
            {
                prefix_op.running_prefix.id = block_segment_idx;
                prefix_op.running_prefix.value = identity;

                // Initialize the "first scattered partial reduction tuple" to the prefix tuple (in case we don't actually scatter one)
                temp_storage.first_partial = prefix_op.running_prefix;
            }
        }

        // Ensure coherence of tile-starting indices
        __syncthreads();

        // Read block's starting indices
        SizeT block_segment_idx             = temp_storage.block_segment_idx[0];
        SizeT block_value_idx               = temp_storage.block_value_idx[0];

        // Remember the first segment index
        SizeT first_segment_idx = block_segment_idx;

        // Have the thread block iterate over the region
        while (block_diagonal < next_block_diagonal)
        {
            // Read block's ending indices
            SizeT next_block_id             = temp_storage.block_segment_idx[1];
            SizeT next_block_value_idx      = temp_storage.block_value_idx[1];

            // Clamp the per-thread search range to within one work-tile of block's current indices
            SizeT next_tile_block_idx = CUB_MIN(next_block_id,          block_segment_idx + TILE_ITEMS);
            SizeT next_tile_value_idx = CUB_MIN(next_block_value_idx,   block_value_idx + TILE_ITEMS);

            // Have each thread search for its segment and value end-indices
            SizeT next_thread_diagonal = block_diagonal + ((threadIdx.x + 1) * ITEMS_PER_THREAD);
            SizeT next_thread_segment_idx;
            SizeT next_thread_value_idx;

            MergePathSearch(
                next_thread_diagonal,           // Next thread diagonal
                d_segment_end_offsets,          // A (segment end-offsets)
                block_segment_idx,              // Start index into A
                next_tile_block_idx,            // End index into A
                next_thread_segment_idx,        // [out] Thread index into A
                d_value_offsets,                // B (value offsets)
                block_value_idx,                // Start index into B
                next_tile_value_idx,            // End index into B
                next_thread_value_idx);         // [out] Thread index into B

            // Share thread end-indices
            temp_storage.thread_segment_idx[threadIdx.x + 1]   = next_thread_segment_idx;
            temp_storage.thread_value_idx[threadIdx.x + 1]     = next_thread_value_idx;

            // Ensure coherence of search indices
            __syncthreads();

            // Get thread begin-indices
            SizeT thread_segment_idx    = temp_storage.thread_segment_idx[threadIdx.x];
            SizeT thread_value_idx      = temp_storage.thread_value_idx[threadIdx.x];

            // Check if first segment end-offset is in range
            bool valid_segment = (thread_segment_idx < next_thread_segment_idx);

            // Check if first value offset is in range
            bool valid_value = (thread_value_idx < next_thread_value_idx);

            // Load first segment end-offset
            SizeT segment_end_offset = (valid_segment) ?
                d_segment_end_offsets[thread_segment_idx] :
                num_values;                                                     // Out of range (the last segment end-offset is one-past the last value offset)

            // Load first value offset
            SizeT value_offset = (valid_value) ?
                d_value_offsets[thread_value_idx] :
                num_values;                                                     // Out of range (one-past the last value offset)

            // Assemble segment-demarcating tail flags and partial reduction tuples
            TailFlag        tail_flags[ITEMS_PER_THREAD];
            KeyValuePair    partial_reductions[ITEMS_PER_THREAD];

            #pragma unroll
            for (int ITEM = 0; ITEM < ITEMS_PER_THREAD; ++ITEM)
            {
                // Default tuple and flag values
                partial_reductions[ITEM].key    = thread_segment_idx;
                partial_reductions[ITEM].value  = identity;
                tail_flags[ITEM]                = 0;

                // Whether or not we slide (a) right along the segment path or (b) down the value path
                bool prefer_segment = (segment_end_offset <= value_offset);

                if (valid_segment && prefer_segment)
                {
                    // Consume this segment index

                    // Set tail flag noting the end of the segment
                    tail_flags[ITEM] = 1;

                    // Increment segment index
                    thread_segment_idx++;

                    // Read next segment end-offset (if valid)
                    if ((valid_segment = (thread_segment_idx < next_thread_segment_idx)))
                        segment_end_offset = d_segment_end_offsets[thread_segment_idx];
                }
                else if (valid_value && !prefer_segment)
                {
                    // Consume this value index

                    // Update the tuple's value with the value at this index.
                    partial_reductions[ITEM].value = d_values[thread_value_idx];

                    // Increment value index
                    thread_value_idx++;

                    // Read next value offset (if valid)
                    if ((valid_value = (thread_value_idx < next_thread_value_idx)))
                        value_offset = d_value_offsets[thread_value_idx];
                }
            }

            // Read the block's starting indices for the next work tile (i.e., the last thread's end-indices)
            block_segment_idx = temp_storage.thread_segment_idx[BLOCK_THREADS];
            block_value_idx = temp_storage.thread_value_idx[BLOCK_THREADS];

            // Barrier for smem reuse
            __syncthreads();

            // Use prefix scan to reduce values by segment-id.  The segment-reductions end up in items flagged as segment-tails.
            KeyValuePair block_aggregate;
            BlockScan(temp_storage.scan).InclusiveScan(
                partial_reductions,             // Scan input
                partial_reductions,             // Scan output
                ReduceByKeyOp(reduction_op),    // Scan operator
                block_aggregate,                // Block-wide total (unused)
                prefix_op);                     // Prefix operator for seeding the block-wide scan with the running total

            // Scatter an accumulated reduction if it is the head of a valid segment
            #pragma unroll
            for (int ITEM = 0; ITEM < ITEMS_PER_THREAD; ITEM++)
            {
                if (tail_flags[ITEM])
                {
                    SizeT segment_idx     = partial_reductions[ITEM].key;
                    Value value           = partial_reductions[ITEM].value;

                    // Write value reduction to corresponding segment id
                    d_output[segment_idx] = value;

                    // Save off the first value product that this thread block will scatter
                    if (segment_idx == first_segment_idx)
                    {
                        temp_storage.first_partial.value = value;
                    }
                }
            }

            // Barrier for smem reuse
            __syncthreads();

            // Advance to the next region in the decision path
            block_diagonal += TILE_ITEMS;
        }
    }

};


/**
 * Threadblock abstraction for "fixing up" value sums from segments spanning multiple block regions.
 */
template <
    int                 BLOCK_THREADS,
    int                 ITEMS_PER_THREAD,
    BlockLoadAlgorithm  LOAD_ALGORITHM,
    bool                LOAD_WARP_TIME_SLICING,
    PtxLoadModifier     LOAD_MODIFIER,
    BlockScanAlgorithm  SCAN_ALGORITHM,
    typename            KeyValuePair,   ///< Partial reduction type
    typename            OutputIterator,     ///< Random-access output iterator pointing to an array of segment totals
    typename            ReductionOp,
    typename            SizeT>
struct BlockReducePartialsBySegment
{
    //---------------------------------------------------------------------
    // Types and constants
    //---------------------------------------------------------------------

    // Constants
    enum
    {
        TILE_ITEMS = BLOCK_THREADS * ITEMS_PER_THREAD,
    };

    // Tail flag type
    typedef int TailFlag;

    // Input iterator wrapper type for loading KeyValuePair elements through cache
    typedef CacheModifiedInputIterator<LOAD_MODIFIER, KeyValuePair, SizeT> WrappedInputIterator;

    // Value type
    typedef typename std::iterator_traits<OutputIterator>::value_type Value;

    // Stateful callback operator type for supplying BlockScan prefixes
    typedef RunningBlockPrefixCallbackOp<KeyValuePair> RunningPrefixCallbackOp;

    // Parameterized BlockLoad type
    typedef BlockLoad<
            WrappedInputIterator,
            BLOCK_THREADS,
            ITEMS_PER_THREAD,
            LOAD_ALGORITHM,
            LOAD_WARP_TIME_SLICING>
        BlockLoad;

    // Parameterized BlockScan type for block-wide reduce-value-by-key
    typedef BlockScan<
            KeyValuePair,
            BLOCK_THREADS,
            SCAN_ALGORITHM>
        BlockScan;

    // Parameterized BlockDiscontinuity type for identifying key discontinuities
    typedef BlockDiscontinuity<
            SizeT,
            BLOCK_THREADS>
        BlockDiscontinuity;

    // Shared memory type for this threadblock
    struct _TempStorage
    {
        union
        {
            typename BlockLoad::TempStorage                 load;           // Smem needed for tile loading
            struct {
                typename BlockScan::TempStorage             scan;           // Smem needed for reduce-value-by-segment scan
                typename BlockDiscontinuity::TempStorage    discontinuity;  // Smem needed for head-flagging
            };
        };
    };

    // Alias wrapper allowing storage to be unioned
    struct TempStorage : Uninitialized<_TempStorage> {};


    //---------------------------------------------------------------------
    // Thread fields
    //---------------------------------------------------------------------

    _TempStorage                &temp_storage;
    int                         num_partials;
    InputIterator               d_block_partials;
    OutputIterator              d_output;
    Value                       identity;               ///< Identity value (for zero-length segments)
    ReductionOp                 reduction_op;           ///< Reduction operator
    RunningPrefixCallbackOp                    prefix_op;              ///< Stateful thread block prefix


    //---------------------------------------------------------------------
    // Operations
    //---------------------------------------------------------------------

    /**
     * Constructor
     */
    __device__ __forceinline__
    BlockReducePartialsBySegment(
        TempStorage                 &temp_storage,
        int                         num_partials,
        InputIterator    d_block_partials,
        OutputIterator              d_output,
        Value                       identity,               ///< Identity value (for zero-length segments)
        ReductionOp                 reduction_op)
    :
        temp_storage(temp_storage.Alias()),
        num_partials(num_partials),
        d_block_partials(d_block_partials),
        d_output(d_output),
        identity(identity),
        reduction_op(reduction_op)
    {
        if (threadIdx.x == 0)
        {
            // Initialize running prefix to the first segment index paired with identity
            prefix_op.running_prefix.id    = d_block_partials[0].id;
            prefix_op.running_prefix.value        = identity;
        }
    }



    /**
     * Processes a reduce-value-by-key input tile, outputting reductions for each segment
     */
    template <bool FULL_TILE>
    __device__ __forceinline__
    void ProcessTile(
        int block_offset,
        int guarded_items = 0)
    {
        SizeT               rows[ITEMS_PER_THREAD];
        KeyValuePair    partial_sums[ITEMS_PER_THREAD];
        TailFlag            tail_flags[ITEMS_PER_THREAD];

        // Load a tile of block partials from previous kernel
        if (FULL_TILE)
        {
            // Full tile
#if CUB_PTX_VERSION >= 350
            LoadBlocked<LOAD_LDG>(threadIdx.x, d_block_partials + block_offset, partial_sums);
#else
            LoadBlocked(threadIdx.x, d_block_partials + block_offset, partial_sums);
#endif
        }
        else
        {
            // Partial tile (extend zero-valued coordinates of the last value-product for out-of-bounds items)
            KeyValuePair default_sum;
            default_sum.segment = temp_storage.last_block_row;
            default_sum.value = Value(0);

#if CUB_PTX_VERSION >= 350
            LoadBlocked<LOAD_LDG>(threadIdx.x, d_block_partials + block_offset, partial_sums, guarded_items, default_sum);
#else
            LoadBlocked(threadIdx.x, d_block_partials + block_offset, partial_sums, guarded_items, default_sum);
#endif
        }

        // Copy out segment IDs for segment-head flagging
        #pragma unroll
        for (int ITEM = 0; ITEM < ITEMS_PER_THREAD; ITEM++)
        {
            rows[ITEM] = partial_sums[ITEM].segment;
        }

        // Flag segment heads by looking for discontinuities
        BlockDiscontinuity(temp_storage.discontinuity).FlagHeads(
            rows,                           // Original segment ids
            tail_flags,                     // (Out) Head flags
            NewRowOp(),                     // Functor for detecting start of new rows
            prefix_op.running_prefix.segment);   // Last segment ID from previous tile to compare with first segment ID in this tile

        // Reduce reduce-value-by-segment across partial_sums using exclusive prefix scan
        KeyValuePair block_aggregate;
        BlockScan(temp_storage.scan).ExclusiveScan(
            partial_sums,                   // Scan input
            partial_sums,                   // Scan output
            ReduceByKeyOp(),                // Scan operator
            block_aggregate,                // Block-wide total (unused)
            prefix_op);                     // Prefix operator for seeding the block-wide scan with the running total

        // Scatter an accumulated reduction if it is the head of a valid segment
        #pragma unroll
        for (int ITEM = 0; ITEM < ITEMS_PER_THREAD; ITEM++)
        {
            if (tail_flags[ITEM])
            {
                d_result[partial_sums[ITEM].segment] = partial_sums[ITEM].value;
            }
        }
    }


    /**
     * Iterate over input tiles belonging to this thread block
     */
    __device__ __forceinline__
    void ProcessTiles()
    {
        // Process full tiles
        int block_offset = 0;
        while (block_offset <= num_partials - TILE_ITEMS)
        {
            ProcessTile<true>(block_offset);
            block_offset += TILE_ITEMS;
        }

        // Process final value tile (if present)
        int guarded_items = num_partials - block_offset;
        if (guarded_items)
        {
            ProcessTile<false>(block_offset, guarded_items);
        }

        // Scatter the final aggregate (this kernel contains only 1 threadblock)
        if (threadIdx.x == 0)
        {
            d_result[prefix_op.running_prefix.segment] = prefix_op.running_prefix.value;
        }
    }
};


/******************************************************************************
 * Kernel entrypoints
 ******************************************************************************/



/**
 * SpMV kernel whose thread blocks each process a contiguous segment of sparse COO tiles.
 */
template <
    int                             BLOCK_THREADS,
    int                             ITEMS_PER_THREAD,
    typename                        SizeT,
    typename                        Value>
__launch_bounds__ (BLOCK_THREADS)
__global__ void CooKernel(
    GridEvenShare<int>              even_share,
    KeyValuePair<SizeT, Value> *d_block_partials,
    SizeT                        *d_rows,
    SizeT                        *d_columns,
    Value                           *d_values,
    Value                           *d_vector,
    Value                           *d_result)
{
    // Specialize SpMV threadblock abstraction type
    typedef BlockSegmentedReduceTiles<BLOCK_THREADS, ITEMS_PER_THREAD, SizeT, Value> BlockSegmentedReduceTiles;

    // Shared memory allocation
    __shared__ typename BlockSegmentedReduceTiles::TempStorage temp_storage;

    // Initialize threadblock even-share to tell us where to start and stop our tile-processing
    even_share.BlockInit();

    // Construct persistent thread block
    BlockSegmentedReduceTiles(
        temp_storage,
        d_rows,
        d_columns,
        d_values,
        d_vector,
        d_result,
        d_block_partials,
        even_share.block_offset,
        even_share.block_end).ProcessTiles();
}


/**
 * Kernel for "fixing up" an array of interblock SpMV value products.
 */
template <
    int                             BLOCK_THREADS,
    int                             ITEMS_PER_THREAD,
    typename                        SizeT,
    typename                        Value>
__launch_bounds__ (BLOCK_THREADS,  1)
__global__ void CooFinalizeKernel(
    KeyValuePair<SizeT, Value> *d_block_partials,
    int                             num_partials,
    Value                           *d_result)
{
    // Specialize "fix-up" threadblock abstraction type
    typedef BlockSegmentedReducePartials<BLOCK_THREADS, ITEMS_PER_THREAD, SizeT, Value> BlockSegmentedReducePartials;

    // Shared memory allocation
    __shared__ typename BlockSegmentedReducePartials::TempStorage temp_storage;

    // Construct persistent thread block
    BlockSegmentedReducePartials persistent_block(temp_storage, d_result, d_block_partials, num_partials);

    // Process input tiles
    persistent_block.ProcessTiles();
}



//---------------------------------------------------------------------
// Host subroutines
//---------------------------------------------------------------------


/**
 * Simple test of device
 */
template <
    int                         COO_BLOCK_THREADS,
    int                         COO_ITEMS_PER_THREAD,
    int                         COO_SUBSCRIPTION_FACTOR,
    int                         FINALIZE_BLOCK_THREADS,
    int                         FINALIZE_ITEMS_PER_THREAD,
    typename                    SizeT,
    typename                    Value>
void TestDevice(
    CooGraph<SizeT, Value>&  coo_graph,
    Value*                      h_vector,
    Value*                      h_reference)
{
    typedef KeyValuePair<SizeT, Value> KeyValuePair;

    const int COO_TILE_SIZE = COO_BLOCK_THREADS * COO_ITEMS_PER_THREAD;

    // SOA device storage
    SizeT        *d_rows;             // SOA graph segment coordinates
    SizeT        *d_columns;          // SOA graph col coordinates
    Value           *d_values;           // SOA graph values
    Value           *d_vector;           // Vector multiplicand
    Value           *d_result;           // Output segment
    KeyValuePair  *d_block_partials;   // Temporary storage for communicating reduction partials between threadblocks

    // Create SOA version of coo_graph on host
    int             num_edges   = coo_graph.coo_tuples.size();
    SizeT        *h_rows     = new SizeT[num_edges];
    SizeT        *h_columns  = new SizeT[num_edges];
    Value           *h_values   = new Value[num_edges];
    for (int i = 0; i < num_edges; i++)
    {
        h_rows[i]       = coo_graph.coo_tuples[i].segment;
        h_columns[i]    = coo_graph.coo_tuples[i].col;
        h_values[i]     = coo_graph.coo_tuples[i].val;
    }

    // Get CUDA properties
    Device device_props;
    CubDebugExit(device_props.Init());

    // Determine launch configuration from kernel properties
    int coo_sm_occupancy;
    CubDebugExit(device_props.MaxSmOccupancy(
        coo_sm_occupancy,
        CooKernel<COO_BLOCK_THREADS, COO_ITEMS_PER_THREAD, SizeT, Value>,
        COO_BLOCK_THREADS));
    int max_coo_grid_size   = device_props.sm_count * coo_sm_occupancy * COO_SUBSCRIPTION_FACTOR;

    // Construct an even-share work distribution
    GridEvenShare<int> even_share(num_edges, max_coo_grid_size, COO_TILE_SIZE);
    int coo_grid_size  = even_share.grid_size;
    int num_partials   = coo_grid_size * 2;

    // Allocate COO device arrays
    CubDebugExit(g_allocator.DeviceAllocate((void**)&d_rows,            sizeof(SizeT) * num_edges));
    CubDebugExit(g_allocator.DeviceAllocate((void**)&d_columns,         sizeof(SizeT) * num_edges));
    CubDebugExit(g_allocator.DeviceAllocate((void**)&d_values,          sizeof(Value) * num_edges));
    CubDebugExit(g_allocator.DeviceAllocate((void**)&d_vector,          sizeof(Value) * coo_graph.col_dim));
    CubDebugExit(g_allocator.DeviceAllocate((void**)&d_result,          sizeof(Value) * coo_graph.row_dim));
    CubDebugExit(g_allocator.DeviceAllocate((void**)&d_block_partials,  sizeof(KeyValuePair) * num_partials));

    // Copy host arrays to device
    CubDebugExit(cudaMemcpy(d_rows,     h_rows,     sizeof(SizeT) * num_edges,       cudaMemcpyHostToDevice));
    CubDebugExit(cudaMemcpy(d_columns,  h_columns,  sizeof(SizeT) * num_edges,       cudaMemcpyHostToDevice));
    CubDebugExit(cudaMemcpy(d_values,   h_values,   sizeof(Value) * num_edges,          cudaMemcpyHostToDevice));
    CubDebugExit(cudaMemcpy(d_vector,   h_vector,   sizeof(Value) * coo_graph.col_dim,  cudaMemcpyHostToDevice));

    // Bind textures
    TexVector<Value>::BindTexture(d_vector, coo_graph.col_dim);

    // Print debug info
    printf("CooKernel<%d, %d><<<%d, %d>>>(...), Max SM occupancy: %d\n",
        COO_BLOCK_THREADS, COO_ITEMS_PER_THREAD, coo_grid_size, COO_BLOCK_THREADS, coo_sm_occupancy);
    if (coo_grid_size > 1)
    {
        printf("CooFinalizeKernel<<<1, %d>>>(...)\n", FINALIZE_BLOCK_THREADS);
    }
    fflush(stdout);

    CubDebugExit(cudaDeviceSetSharedMemConfig(cudaSharedMemBankSizeEightByte));

    // Run kernel (always run one iteration without timing)
    GpuTimer gpu_timer;
    float elapsed_millis = 0.0;
    for (int i = 0; i <= g_iterations; i++)
    {
        gpu_timer.Start();

        // Initialize output
        CubDebugExit(cudaMemset(d_result, 0, coo_graph.row_dim * sizeof(Value)));

        // Run the COO kernel
        CooKernel<COO_BLOCK_THREADS, COO_ITEMS_PER_THREAD><<<coo_grid_size, COO_BLOCK_THREADS>>>(
            even_share,
            d_block_partials,
            d_rows,
            d_columns,
            d_values,
            d_vector,
            d_result);

        if (coo_grid_size > 1)
        {
            // Run the COO finalize kernel
            CooFinalizeKernel<FINALIZE_BLOCK_THREADS, FINALIZE_ITEMS_PER_THREAD><<<1, FINALIZE_BLOCK_THREADS>>>(
                d_block_partials,
                num_partials,
                d_result);
        }

        gpu_timer.Stop();

        if (i > 0)
            elapsed_millis += gpu_timer.ElapsedMillis();
    }

    // Force any kernel stdio to screen
    CubDebugExit(cudaThreadSynchronize());
    fflush(stdout);

    // Display timing
    if (g_iterations > 0)
    {
        float avg_elapsed = elapsed_millis / g_iterations;
        int total_bytes = ((sizeof(SizeT) + sizeof(SizeT)) * 2 * num_edges) + (sizeof(Value) * coo_graph.row_dim);
        printf("%d iterations, average elapsed (%.3f ms), utilized bandwidth (%.3f GB/s), GFLOPS(%.3f)\n",
            g_iterations,
            avg_elapsed,
            total_bytes / avg_elapsed / 1000.0 / 1000.0,
            num_edges * 2 / avg_elapsed / 1000.0 / 1000.0);
    }

    // Check results
    int compare = CompareDeviceResults(h_reference, d_result, coo_graph.row_dim, true, g_verbose);
    printf("%s\n", compare ? "FAIL" : "PASS");
    AssertEquals(0, compare);

    // Cleanup
    TexVector<Value>::UnbindTexture();
    CubDebugExit(g_allocator.DeviceFree(d_block_partials));
    CubDebugExit(g_allocator.DeviceFree(d_rows));
    CubDebugExit(g_allocator.DeviceFree(d_columns));
    CubDebugExit(g_allocator.DeviceFree(d_values));
    CubDebugExit(g_allocator.DeviceFree(d_vector));
    CubDebugExit(g_allocator.DeviceFree(d_result));
    delete[] h_rows;
    delete[] h_columns;
    delete[] h_values;
}


/**
 * Compute reference answer on CPU
 */
template <typename SizeT, typename Value>
void ComputeReference(
    CooGraph<SizeT, Value>&  coo_graph,
    Value*                      h_vector,
    Value*                      h_reference)
{
    for (SizeT i = 0; i < coo_graph.row_dim; i++)
    {
        h_reference[i] = 0.0;
    }

    for (SizeT i = 0; i < coo_graph.coo_tuples.size(); i++)
    {
        h_reference[coo_graph.coo_tuples[i].segment] +=
            coo_graph.coo_tuples[i].val *
            h_vector[coo_graph.coo_tuples[i].col];
    }
}


/**
 * Assign arbitrary values to vector items
 */
template <typename Value>
void AssignVectorValues(Value *vector, int col_dim)
{
    for (int i = 0; i < col_dim; i++)
    {
        vector[i] = 1.0;
    }
}


/**
 * Main
 */
int main(int argc, char** argv)
{
    typedef int         SizeT;      // uint32s as segment IDs
    typedef double      Value;      // double-precision floating point values


    // Initialize command line
    CommandLineArgs args(argc, argv);
    g_verbose = args.CheckCmdLineFlag("v");
    args.GetCmdLineArgument("i", g_iterations);

    // Print usage
    if (args.CheckCmdLineFlag("help"))
    {
        printf("%s\n [--device=<device-id>] [--v] [--iterations=<test iterations>] [--grid-size=<grid-size>]\n"
            "\t--type=wheel --spokes=<spokes>\n"
            "\t--type=grid2d --width=<width> [--no-self-loops]\n"
            "\t--type=grid3d --width=<width> [--no-self-loops]\n"
            "\t--type=market --file=<file>\n"
            "\n", argv[0]);
        exit(0);
    }

    // Initialize device
    CubDebugExit(args.DeviceInit());

    // Get graph type
    string type;
    args.GetCmdLineArgument("type", type);

    // Generate graph structure

    CpuTimer timer;
    timer.Start();
    CooGraph<SizeT, Value> coo_graph;
    if (type == string("grid2d"))
    {
        SizeT width;
        args.GetCmdLineArgument("width", width);
        bool self_loops = !args.CheckCmdLineFlag("no-self-loops");
        printf("Generating %s grid2d width(%d)... ", (self_loops) ? "5-pt" : "4-pt", width); fflush(stdout);
        if (coo_graph.InitGrid2d(width, self_loops)) exit(1);
    } else if (type == string("grid3d"))
    {
        SizeT width;
        args.GetCmdLineArgument("width", width);
        bool self_loops = !args.CheckCmdLineFlag("no-self-loops");
        printf("Generating %s grid3d width(%d)... ", (self_loops) ? "7-pt" : "6-pt", width); fflush(stdout);
        if (coo_graph.InitGrid3d(width, self_loops)) exit(1);
    }
    else if (type == string("wheel"))
    {
        SizeT spokes;
        args.GetCmdLineArgument("spokes", spokes);
        printf("Generating wheel spokes(%d)... ", spokes); fflush(stdout);
        if (coo_graph.InitWheel(spokes)) exit(1);
    }
    else if (type == string("market"))
    {
        string filename;
        args.GetCmdLineArgument("file", filename);
        printf("Generating MARKET for %s... ", filename.c_str()); fflush(stdout);
        if (coo_graph.InitMarket(filename)) exit(1);
    }
    else
    {
        printf("Unsupported graph type\n");
        exit(1);
    }
    timer.Stop();
    printf("Done (%.3fs). %d non-zeros, %d rows, %d columns\n",
        timer.ElapsedMillis() / 1000.0,
        coo_graph.coo_tuples.size(),
        coo_graph.row_dim,
        coo_graph.col_dim);
    fflush(stdout);

    if (g_verbose)
    {
        cout << coo_graph << "\n";
    }

    // Create vector
    Value *h_vector = new Value[coo_graph.col_dim];
    AssignVectorValues(h_vector, coo_graph.col_dim);
    if (g_verbose)
    {
        printf("Vector[%d]: ", coo_graph.col_dim);
        DisplayResults(h_vector, coo_graph.col_dim);
        printf("\n\n");
    }

    // Compute reference answer
    Value *h_reference = new Value[coo_graph.row_dim];
    ComputeReference(coo_graph, h_vector, h_reference);
    if (g_verbose)
    {
        printf("Results[%d]: ", coo_graph.row_dim);
        DisplayResults(h_reference, coo_graph.row_dim);
        printf("\n\n");
    }

    // Parameterization for SM35
    enum
    {
        COO_BLOCK_THREADS           = 64,
        COO_ITEMS_PER_THREAD        = 10,
        COO_SUBSCRIPTION_FACTOR     = 4,
        FINALIZE_BLOCK_THREADS      = 256,
        FINALIZE_ITEMS_PER_THREAD   = 4,
    };

    // Run GPU version
    TestDevice<
        COO_BLOCK_THREADS,
        COO_ITEMS_PER_THREAD,
        COO_SUBSCRIPTION_FACTOR,
        FINALIZE_BLOCK_THREADS,
        FINALIZE_ITEMS_PER_THREAD>(coo_graph, h_vector, h_reference);

    // Cleanup
    delete[] h_vector;
    delete[] h_reference;

    return 0;
}



