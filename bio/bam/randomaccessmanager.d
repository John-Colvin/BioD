/*
    This file is part of BioD.
    Copyright (C) 2012    Artem Tarasov <lomereiter@gmail.com>

    BioD is free software; you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation; either version 2 of the License, or
    (at your option) any later version.

    BioD is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with this program; if not, write to the Free Software
    Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA

*/
/**
  Module for random access operations on BAM file.
 */
module bio.bam.randomaccessmanager;

import bio.bam.constants;
import bio.bam.read;
import bio.bam.readrange;
import bio.bam.baifile;
import bio.bam.bai.utils.algo;

import bio.core.bgzf.blockrange;
import bio.core.bgzf.virtualoffset;
import bio.core.bgzf.chunkinputstream;
import bio.core.utils.memoize;
import bio.core.utils.range;
import bio.core.utils.stream;

import std.system;
import std.algorithm;
import std.array;
import std.range;
import std.traits;
import std.exception;

import std.parallelism;

// made public to be accessible from utils.memoize module
auto decompressTask(BgzfBlock block) {
    auto t = task!decompressBgzfBlock(block);
    taskPool.put(t);
    return t;
}

private alias memoize!(decompressTask, 512, FifoCache, BgzfBlock) memDecompressTask;

// made public only to be accessible from std.algorithm
auto decompressSerial(BgzfBlock block) {
    return decompress(block).yieldForce();
}

// ditto
auto decompress(BgzfBlock block) { 
    return memDecompressTask(block);
}

debug {
    import std.stdio;
}

/// Class which random access tasks are delegated to.
class RandomAccessManager {

    /// Constructs new manager for BAM file
    this(string filename) {
        _filename = filename;
    }

    /// Constructs new manager with given index file.
    /// This allows to do random-access interval queries.
    ///
    /// Params:
    ///     filename =  location of BAM file
    ///     bai  =  index file
    this(string filename, ref BaiFile bai) {

        _filename = filename;
        _bai = bai;
        _found_index_file = true;
    }

    /// If file ends with EOF block, returns virtual offset of the start of EOF block.
    /// Otherwise, returns virtual offset of the physical end of file.
    VirtualOffset eofVirtualOffset() const {
        ulong file_offset = std.file.getSize(_filename);
        if (hasEofBlock()) {
            return VirtualOffset(file_offset - BAM_EOF.length, 0);
        } else {
            return VirtualOffset(file_offset, 0);
        }
    }

    /// Returns true if the file ends with EOF block, and false otherwise.
    bool hasEofBlock() const {
        auto _stream = new bio.core.utils.stream.File(_filename);
        if (_stream.size < BAM_EOF.length) {
            return false;
        }

        ubyte[BAM_EOF.length] buf;
        _stream.seekEnd(-cast(int)BAM_EOF.length);

        _stream.readExact(&buf, BAM_EOF.length);
        if (buf != BAM_EOF) {
            return false;
        }

        return true;
    }

    /// Get new IChunkInputStream starting from specified virtual offset.
    IChunkInputStream createStreamStartingFrom(VirtualOffset offset, TaskPool task_pool=null) {

        auto _stream = new bio.core.utils.stream.File(_filename);
        auto _compressed_stream = new EndianStream(_stream, Endian.littleEndian);
        _compressed_stream.seekSet(cast(size_t)(offset.coffset));

        auto bgzf_range = BgzfRange(_compressed_stream);

        static auto helper(R)(R decompressed_range, VirtualOffset offset) {

            auto adjusted_front = AugmentedDecompressedBgzfBlock(decompressed_range.front,
                                                                 offset.uoffset, 0); 
            decompressed_range.popFront();
            auto adjusted_range = chain(repeat(adjusted_front, 1), 
                                        map!makeAugmentedBlock(decompressed_range));

            return cast(IChunkInputStream)makeChunkInputStream(adjusted_range);
        }

        if (task_pool is null) {
            return helper(map!decompressSerial(bgzf_range), offset);
        } else {
            return helper(task_pool.map!(bio.core.bgzf.blockrange.decompressBgzfBlock)(bgzf_range), offset);
        }
    }

    /// Get single read at a given virtual offset.
    /// Every time new stream is used.
    BamRead getReadAt(VirtualOffset offset) {
        auto stream = createStreamStartingFrom(offset);
        return bamReadRange(stream).front.dup;
    }

    /// Get BGZF block at a given offset.
    BgzfBlock getBgzfBlockAt(ulong offset) {
        auto stream = new bio.core.utils.stream.File(_filename);
        stream.seekSet(offset);
        return BgzfRange(stream).front;
    }

    /// Get reads between two virtual offsets. First virtual offset must point
    /// to a start of an alignment record.
    ///
    /// If $(D task_pool) is not null, it is used for parallel decompression. Otherwise, decompression is serial.
    auto getReadsBetween(VirtualOffset from, VirtualOffset to, TaskPool task_pool=null) {
        IChunkInputStream stream = createStreamStartingFrom(from, task_pool);

        static bool offsetTooBig(BamReadBlock record, VirtualOffset vo) {
            return record.end_virtual_offset > vo;
        }

        return until!offsetTooBig(bamReadRange!withOffsets(stream), to);
    }

    bool found_index_file() @property {
        return _found_index_file;
    }
    private bool _found_index_file = false; // overwritten in constructor if filename is provided

    /// BAI file
    ref const(BaiFile) getBai() const {
        return _bai;
    }

    /// Get BAI chunks containing all alignment records overlapping specified region
    Chunk[] getChunks(int ref_id, int beg, int end) {
        enforce(found_index_file, "BAM index file (.bai) must be provided");
        enforce(ref_id >= 0 && ref_id < _bai.indices.length, "Invalid reference sequence index");

        // Select all bins that overlap with [beg, end).
        // Then from such bins select all chunks that end to the right of min_offset.
        // Sort these chunks by leftmost coordinate and remove all overlaps.

        auto min_offset = _bai.indices[ref_id].getMinimumOffset(beg);

        Chunk[] bai_chunks;
        foreach (b; _bai.indices[ref_id].bins) {
            if (!b.canOverlapWith(beg, end)) {
                continue;
            }

            foreach (chunk; b.chunks) {
                if (chunk.end > min_offset) {
                    bai_chunks ~= chunk;

                    // optimization
                    if (bai_chunks[$-1].beg < min_offset) {
                        bai_chunks[$-1].beg = min_offset;
                    }
                }
            }
        }

        sort(bai_chunks);

        return bai_chunks;
    }

    /// Fetch alignments with given reference sequence id, overlapping [beg..end)
    auto getReads(alias IteratePolicy=withOffsets)(int ref_id, uint beg, uint end) {
        auto _stream = new bio.core.utils.stream.File(_filename);
        Stream _compressed_stream = new EndianStream(_stream, Endian.littleEndian);

        auto chunks = array(nonOverlappingChunks(getChunks(ref_id, beg, end)));

        debug {
            /*
            import std.stdio;
            writeln("[random access] chunks:");
            writeln("    ", chunks);
            */
        }

        // General plan:
        //
        // chunk[0] -> bgzfRange[0] |
        // chunk[1] -> bgzfRange[1] | (2)
        //         ....             | -> (joiner(bgzfRange), [start/end v.o.])
        // chunk[k] -> bgzfRange[k] |                      |
        //         (1)                     /* parallel */  V                       (3)
        //                                  (unpacked blocks, [start/end v.o.])
        //                                                 |
        //                                                 V                       (4)
        //                                     (modified unpacked blocks)
        //                                                 |
        //                                                 V                       (5)
        //                                        IChunkInputStream
        //                                                 |
        //                                                 V                       (6)
        //                                 filter out non-overlapping records
        //                                                 |
        //                                                 V
        //                                              that's it!

        auto bgzf_range = getJoinedBgzfRange(chunks);                               // (2)
        auto decompressed_blocks = getUnpackedBlocks(bgzf_range);                   // (3)
        auto augmented_blocks = getAugmentedBlocks(decompressed_blocks, chunks);    // (4)
        IChunkInputStream stream = makeChunkInputStream(augmented_blocks);          // (5)
        auto reads = bamReadRange!IteratePolicy(stream);
        return filterBamReads(reads, ref_id, beg, end);                             // (6)
    }

private:
    
    string _filename;
    BaiFile _bai;

public:

    // Let's implement the plan described above!

    // (1) : Chunk -> [BgzfBlock]
    auto chunkToBgzfRange(Chunk chunk) {
        // FIXME: we shouldn't create new stream for each chunk!
        auto stream = new bio.core.utils.stream.File(_filename);

        stream.seekSet(cast(size_t)chunk.beg.coffset);

        static bool offsetTooBig(BgzfBlock block, ulong offset) {
            return block.start_offset > offset;
        }

        return until!offsetTooBig(BgzfRange(stream), chunk.end.coffset);
    }

    // (2) : Chunk[] -> [BgzfBlock]
    auto getJoinedBgzfRange(Chunk[] bai_chunks) {
        ReturnType!chunkToBgzfRange[] bgzf_ranges;
        bgzf_ranges.length = bai_chunks.length;
        foreach (i, ref range; bgzf_ranges) {
            range = chunkToBgzfRange(bai_chunks[i]);
        }
        auto bgzf_blocks = joiner(bgzf_ranges);
        return bgzf_blocks;
    }

    // (3) : [BgzfBlock] -> [DecompressedBgzfBlock]
    static auto getUnpackedBlocks(R)(R bgzf_range) {
        version(serial) {
            return map!decompressBgzfBlock(bgzf_range);
        } else {
            InputRange!DecompressedBgzfBlock result;
            if (taskPool.size < 2) {
                result = inputRangeObject(map!decompressBgzfBlock(bgzf_range));
            } else {
                // up to (taskPool.size) tasks are being executed at every moment
                auto prefetched_range = prefetch(map!decompress(bgzf_range), taskPool.size);
                result = inputRangeObject(map!"a.yieldForce()"(prefetched_range));
            }
            return result;
        }
    }

    // (4) : ([DecompressedBgzfBlock], Chunk[]) -> [AugmentedDecompressedBgzfBlock]

    // decompressed blocks:
    // [.....][......][......][......][......][......][.....][....]
    //
    // what we need (chunks):
    //   [.........]  [.........]        [...........]  [..]
    //
    // Solution: augment decompressed blocks with skip_start and skip_end members
    //           and teach ChunkInputStream to deal with ranges of such blocks.
    static struct AugmentedBlockRange(R) {
        this(R blocks, Chunk[] bai_chunks) {
            _blocks = blocks;
            if (_blocks.empty) {
                _empty = true;
            } else {
                _cur_block = _blocks.front;
                _blocks.popFront();
            }
            _chunks = bai_chunks[];
        }

        bool empty() @property {
            return _empty;
        }

        AugmentedDecompressedBgzfBlock front() @property {
            AugmentedDecompressedBgzfBlock result;
            result.block = _cur_block;

            if (_chunks.empty) {
                return result;
            }

            if (beg.coffset == result.start_offset) {
                result.skip_start = beg.uoffset;
            }

            if (end.coffset == result.start_offset) {
                auto to_skip = result.decompressed_data.length - end.uoffset;
                assert(to_skip <= ushort.max);
                result.skip_end = cast(ushort)to_skip;
            }

            return result;
        }

        void popFront() {
            if (_cur_block.start_offset == end.coffset) {
                _chunks = _chunks[1 .. $];
            }
            if (_blocks.empty) {
                _empty = true;
                return;
            }
            _cur_block = _blocks.front;
            _blocks.popFront();
        }

        private {
            R _blocks;
            ElementType!R _cur_block;
            bool _empty;
            Chunk[] _chunks;

            VirtualOffset beg() @property {
                return _chunks[0].beg;
            }

            VirtualOffset end() @property {
                return _chunks[0].end;
            }
        }
    }

    static auto getAugmentedBlocks(R)(R decompressed_blocks, Chunk[] bai_chunks) {
        return AugmentedBlockRange!R(decompressed_blocks, bai_chunks);
    }

    static struct BamReadFilter(R) {
        this(R r, int ref_id, uint beg, uint end) {
            _range = r;
            _ref_id = ref_id;
            _beg = beg;
            _end = end;
            findNext();
        }

        bool empty() @property {
            return _empty;
        }

        ElementType!R front() @property {
            return _current_read;
        }
        
        void popFront() {
            _range.popFront();
            findNext();
        }

    private: 
        R _range;
        int _ref_id;
        uint _beg;
        uint _end;
        bool _empty;
        ElementType!R _current_read;

        void findNext() {
            if (_range.empty) {
                _empty = true;
                return;
            }
            while (!_range.empty) {
                _current_read = _range.front;

                // BamReads are sorted first by ref. ID.
                auto current_ref_id = _current_read.ref_id;
                if (current_ref_id > _ref_id) {
                    // no more records for this _ref_id
                    _empty = true;
                    return;
                } else if (current_ref_id < _ref_id) {
                    // skip reads referring to sequences
                    // with ID less than ours
                    _range.popFront();
                    continue;
                }

                if (_current_read.position >= _end) {
                    _empty = true;
                    // As reads are sorted by leftmost coordinate,
                    // all remaining alignments in _range 
                    // will not overlap the interval as well.
                    // 
                    //                  [-----)
                    //                  . [-----------)
                    //                  .  [---)
                    //                  .    [-------)
                    //                  .         [-)
                    //    [beg .....  end)
                    return;
                }

                if (_current_read.position > _beg) {
                    return; // definitely overlaps
                }

                if (_current_read.position +
                    _current_read.basesCovered() <= _beg) 
                {
                    /// ends before beginning of the region
                    ///  [-----------)
                    ///               [beg .......... end)
                    _range.popFront();
                    /// Zero-length reads are also considered non-overlapping,
                    /// so for consistency the inequality 12 lines above is strict.
                } else {
                    return; /// _current_read overlaps the region
                }
            }
            _empty = true; 
        }
    }

    // Get range of alignments sorted by leftmost coordinate,
    // together with an interval [beg, end),
    // and return another range of alignments which overlap the region.
    static auto filterBamReads(R)(R r, int ref_id, uint beg, uint end) 
    {
        return BamReadFilter!R(r, ref_id, beg, end);
    }
}
