const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const maybe = stdx.maybe;
const mem = std.mem;
const log = std.log.scoped(.forest);

const stdx = @import("../stdx.zig");
const constants = @import("../constants.zig");
const vsr = @import("../vsr.zig");

const schema = @import("schema.zig");
const GridType = @import("../vsr/grid.zig").GridType;
const BlockPtr = @import("../vsr/grid.zig").BlockPtr;
const allocate_block = @import("../vsr/grid.zig").allocate_block;
const NodePool = @import("node_pool.zig").NodePool(constants.lsm_manifest_node_size, 16);
const ManifestLogType = @import("manifest_log.zig").ManifestLogType;
const ScanBufferPool = @import("scan_buffer.zig").ScanBufferPool;
const CompactionInterfaceType = @import("compaction.zig").CompactionInterfaceType;
const CompactionHelperType = @import("compaction.zig").CompactionHelperType;
const BlipStage = @import("compaction.zig").BlipStage;
const Exhausted = @import("compaction.zig").Exhausted;
const snapshot_min_for_table_output = @import("compaction.zig").snapshot_min_for_table_output;
const snapshot_max_for_table_input = @import("compaction.zig").snapshot_max_for_table_input;
const compaction_op_min = @import("compaction.zig").compaction_op_min;

const IO = @import("../io.zig").IO;

const table_count_max = @import("tree.zig").table_count_max;

pub fn ForestType(comptime _Storage: type, comptime groove_cfg: anytype) type {
    var groove_fields: []const std.builtin.Type.StructField = &.{};
    var groove_options_fields: []const std.builtin.Type.StructField = &.{};

    for (std.meta.fields(@TypeOf(groove_cfg))) |field| {
        const Groove = @field(groove_cfg, field.name);
        groove_fields = groove_fields ++ [_]std.builtin.Type.StructField{
            .{
                .name = field.name,
                .type = Groove,
                .default_value = null,
                .is_comptime = false,
                .alignment = @alignOf(Groove),
            },
        };

        groove_options_fields = groove_options_fields ++ [_]std.builtin.Type.StructField{
            .{
                .name = field.name,
                .type = Groove.Options,
                .default_value = null,
                .is_comptime = false,
                .alignment = @alignOf(Groove),
            },
        };
    }

    const _Grooves = @Type(.{
        .Struct = .{
            .layout = .Auto,
            .fields = groove_fields,
            .decls = &.{},
            .is_tuple = false,
        },
    });

    const _GroovesOptions = @Type(.{
        .Struct = .{
            .layout = .Auto,
            .fields = groove_options_fields,
            .decls = &.{},
            .is_tuple = false,
        },
    });

    {
        // Verify that every tree id is unique.
        comptime var ids: []const u16 = &.{};

        inline for (std.meta.fields(_Grooves)) |groove_field| {
            const Groove = groove_field.type;

            for (std.meta.fields(@TypeOf(Groove.config.ids))) |field| {
                const id = @field(Groove.config.ids, field.name);
                assert(id > 0);
                assert(std.mem.indexOfScalar(u16, ids, id) == null);

                ids = ids ++ [_]u16{id};
            }
        }
    }

    const TreeInfo = struct {
        Tree: type,
        tree_name: []const u8,
        tree_id: u16,
        groove_name: []const u8,
        groove_tree: union(enum) { objects, ids, indexes: []const u8 },
    };

    // Invariants:
    // - tree_infos[tree_id - tree_id_range.min].tree_id == tree_id
    // - tree_infos.len == tree_id_range.max - tree_id_range.min
    const _tree_infos: []const TreeInfo = tree_infos: {
        var tree_infos: []const TreeInfo = &[_]TreeInfo{};
        for (std.meta.fields(_Grooves)) |groove_field| {
            const Groove = groove_field.type;

            tree_infos = tree_infos ++ &[_]TreeInfo{.{
                .Tree = Groove.ObjectTree,
                .tree_name = groove_field.name,
                .tree_id = @field(Groove.config.ids, "timestamp"),
                .groove_name = groove_field.name,
                .groove_tree = .objects,
            }};

            if (Groove.IdTree != void) {
                tree_infos = tree_infos ++ &[_]TreeInfo{.{
                    .Tree = Groove.IdTree,
                    .tree_name = groove_field.name ++ ".id",
                    .tree_id = @field(Groove.config.ids, "id"),
                    .groove_name = groove_field.name,
                    .groove_tree = .ids,
                }};
            }

            for (std.meta.fields(Groove.IndexTrees)) |tree_field| {
                tree_infos = tree_infos ++ &[_]TreeInfo{.{
                    .Tree = tree_field.type,
                    .tree_name = groove_field.name ++ "." ++ tree_field.name,
                    .tree_id = @field(Groove.config.ids, tree_field.name),
                    .groove_name = groove_field.name,
                    .groove_tree = .{ .indexes = tree_field.name },
                }};
            }
        }

        var tree_id_min = std.math.maxInt(u16);
        for (tree_infos) |tree_info| tree_id_min = @min(tree_id_min, tree_info.tree_id);

        var tree_infos_sorted: [tree_infos.len]TreeInfo = undefined;
        var tree_infos_set = std.StaticBitSet(tree_infos.len).initEmpty();
        for (tree_infos) |tree_info| {
            const tree_index = tree_info.tree_id - tree_id_min;
            assert(!tree_infos_set.isSet(tree_index));

            tree_infos_sorted[tree_index] = tree_info;
            tree_infos_set.set(tree_index);
        }

        // There are no gaps in the tree ids.
        assert(tree_infos_set.count() == tree_infos.len);

        break :tree_infos tree_infos_sorted[0..];
    };

    const Grid = GridType(_Storage);

    // TODO: With all this trouble, why not just store the compaction memory here and move it out
    // of Tree entirely...
    const CompactionInterface = CompactionInterfaceType(Grid, _tree_infos);
    const CompactionHelper = CompactionHelperType(Grid);

    return struct {
        const Forest = @This();

        const ManifestLog = ManifestLogType(Storage);

        const Callback = *const fn (*Forest) void;
        const GroovesBitSet = std.StaticBitSet(std.meta.fields(Grooves).len);

        pub const Storage = _Storage;
        pub const groove_config = groove_cfg;
        pub const Grooves = _Grooves;
        pub const GroovesOptions = _GroovesOptions;
        pub const tree_infos = _tree_infos;
        pub const tree_id_range = .{
            .min = tree_infos[0].tree_id,
            .max = tree_infos[tree_infos.len - 1].tree_id,
        };

        const CompactionPipeline = struct {
            /// If you think of a pipeline diagram, a pipeline slot is a single instruction.
            const PipelineSlot = struct {
                interface: CompactionInterface,
                pipeline: *CompactionPipeline,
                active_operation: BlipStage,
                compaction_index: usize,
            };

            const compaction_count = tree_infos.len * constants.lsm_levels;
            const CompactionBitset = std.StaticBitSet(compaction_count);

            grid: *Grid,

            /// Raw, linear buffer of blocks + reads / writes that will be split up. The
            /// CompactionPipeline owns this memory, and anything pointing to a CompactionBlock
            /// ultimately lives here.
            compaction_blocks: []CompactionHelper.CompactionBlock,

            compactions: stdx.BoundedArray(CompactionInterface, compaction_count) = .{},

            bar_active: CompactionBitset = CompactionBitset.initEmpty(),
            beat_active: CompactionBitset = CompactionBitset.initEmpty(),
            beat_reserved: CompactionBitset = CompactionBitset.initEmpty(),

            // TODO: This whole interface around slot_filled_count / slot_running_count needs to be
            // refactored.
            slots: [3]?PipelineSlot = .{ null, null, null },
            slot_filled_count: usize = 0,
            slot_running_count: usize = 0,

            // Used for invoking the CPU work after a next_tick.
            cpu_slot: ?*PipelineSlot = null,

            state: enum { filling, full, draining, drained } = .filling,

            next_tick: Grid.NextTick = undefined,

            forest: ?*Forest = null,
            callback: ?*const fn (*Forest) void = null,

            pub fn init(allocator: mem.Allocator, grid: *Grid) !CompactionPipeline {
                // CompactionBlock has some metadata, but we only look at the Block for now which
                // makes up the bulk.
                const block_count = @divExact(
                    constants.compaction_block_memory,
                    constants.block_size,
                );
                log.debug("compaction_block_memory={} block_count={}", .{
                    constants.compaction_block_memory,
                    block_count,
                });

                const compaction_blocks = try allocator.alloc(
                    CompactionHelper.CompactionBlock,
                    block_count,
                );
                errdefer allocator.free(compaction_blocks);

                for (compaction_blocks, 0..) |*compaction_block, i| {
                    errdefer for (compaction_blocks[0..i]) |block| allocator.free(block.block);
                    compaction_block.* = .{
                        .block = try allocate_block(allocator),
                    };
                }
                errdefer for (compaction_blocks) |block| allocator.free(block.block);

                return .{
                    .compaction_blocks = compaction_blocks,
                    .grid = grid,
                };
            }

            pub fn deinit(self: *CompactionPipeline, allocator: mem.Allocator) void {
                for (self.compaction_blocks) |block| allocator.free(block.block);
                allocator.free(self.compaction_blocks);
            }

            pub fn reset(self: *CompactionPipeline) void {
                self.* = .{
                    .grid = self.grid,
                    .compaction_blocks = self.compaction_blocks,
                };
            }

            /// Our source and output blocks (excluding index blocks for now) are split two ways.
            /// First, equally by pipeline stage, then by table a / table b:
            /// -------------------------------------------------------------
            /// | Pipeline 0                  | Pipeline 1                  |
            /// |-----------------------------|-----------------------------|
            /// | Table A     | Table B       | Table A     | Table B       |
            /// -------------------------------------------------------------
            fn divide_blocks(self: *CompactionPipeline) CompactionHelper.CompactionBlocks {
                // Some blocks only need to be valid for a beat, after which they're used for
                // the next compaction.
                const minimum_block_count_beat: u64 = blk: {
                    var minimum_block_count: u64 = 0;

                    // We need a minimum of 2 source value blocks; one from each table.
                    minimum_block_count += 2;

                    // We need a minimum of 1 output value block.
                    minimum_block_count += 1;

                    // Because we're a 3 stage pipeline, with the middle stage (merge) having a
                    // data dependency on both read and write value blocks, we need to split our
                    // memory in the middle. This results in a doubling of what we have so far.
                    minimum_block_count *= 2;

                    break :blk minimum_block_count;
                };

                // Some blocks need to be reserved for the lifetime of the bar, and can't
                // be shared between compactions, so these are all multipled by the number
                // of trees:
                const block_count_bar: u64 = blk: {
                    var block_count: u64 = 0;

                    // Source index blocks. For now, just require we have 2.
                    block_count += 2;

                    // Immutable value block. Used when level_a comes from the immutable table.
                    block_count += 1;

                    // Output index blocks. Minimum of 2 since one can be writing while the other
                    // is being used.
                    block_count += 2;

                    block_count *= tree_infos.len;

                    break :blk block_count;
                };

                assert(self.compaction_blocks.len >= block_count_bar + minimum_block_count_beat);

                // Reserve the top of the block address space for the bar scoped blocks.
                const blocks =
                    self.compaction_blocks[0 .. self.compaction_blocks.len - block_count_bar];
                assert(blocks.len >= minimum_block_count_beat);

                for (blocks) |*block| {
                    block.next = null;
                    block.stage = .free;
                }

                // Source index blocks is always 2 for now.
                const source_index_blocks = blocks[0..2];

                // Split the remaining blocks equally, with the remainder going to the target pool.
                // TODO: Splitting equally is definitely not the best way!
                // TODO: If level_b is 0, level_a needs no memory at all.
                var equal_split_count = @divFloor(blocks.len - 2, 3);
                if (equal_split_count % 2 != 0) equal_split_count -= 1; // Must be even, for now.

                const source_value_level_a = blocks[2..][0..equal_split_count];
                const source_value_level_b = blocks[2 + equal_split_count ..][0..equal_split_count];

                // TODO: This wastes the remainder, but we have other code that requires the count
                // to be even for now.
                const target_value_blocks =
                    blocks[2 + equal_split_count + equal_split_count ..][0..equal_split_count];

                log.debug("divide_blocks: block_count_bar={} source_index_blocks.len={} " ++
                    "source_value_level_a.len={} source_value_level_b.len={} " ++
                    " target_value_blocks.len={}", .{
                    block_count_bar,
                    source_index_blocks.len,
                    source_value_level_a.len,
                    source_value_level_b.len,
                    target_value_blocks.len,
                });

                {
                    const subdivision: []const []CompactionHelper.CompactionBlock = &.{
                        source_index_blocks,
                        source_value_level_a,
                        source_value_level_b,
                        target_value_blocks,
                    };
                    for (subdivision, 0..) |slice_a, i| {
                        for (subdivision[0..i]) |slice_b| {
                            assert(stdx.disjoint_slices(
                                CompactionHelper.CompactionBlock,
                                CompactionHelper.CompactionBlock,
                                slice_a,
                                slice_b,
                            ));
                        }
                    }
                }

                return .{
                    .source_index_blocks = source_index_blocks,
                    .source_value_blocks = .{
                        CompactionHelper.BlockFIFO.init(source_value_level_a),
                        CompactionHelper.BlockFIFO.init(source_value_level_b),
                    },
                    .target_value_blocks = CompactionHelper.BlockFIFO.init(target_value_blocks),
                };
            }

            pub fn beat(
                self: *CompactionPipeline,
                forest: *Forest,
                op: u64,
                callback: Callback,
            ) void {
                const compaction_beat = op % constants.lsm_batch_multiple;
                const first_beat = compaction_beat == 0;
                const half_beat = compaction_beat == @divExact(constants.lsm_batch_multiple, 2);

                self.slot_filled_count = 0;
                self.slot_running_count = 0;

                if (first_beat or half_beat) {
                    if (first_beat)
                        self.bar_active = CompactionBitset.initEmpty();

                    var compaction_blocks = self.compaction_blocks;
                    for (self.compactions.slice(), 0..) |*compaction, i| {
                        if (compaction.info.level_b % 2 == 0 and first_beat) continue;
                        if (compaction.info.level_b % 2 != 0 and half_beat) continue;

                        // TODO: divide_blocks ensures blocks aren't aliased, this code should do
                        // the same.
                        const len = compaction_blocks.len; // Line length limits...
                        const immutable_table_a_block = compaction_blocks[len - 1].block;
                        const blocks = compaction_blocks[len - 3 .. len - 1];
                        for (blocks) |*block| {
                            block.next = null;
                            block.stage = .free;
                        }

                        compaction_blocks.len -= 3;

                        const ring_buffer = CompactionHelper.BlockFIFO.init(blocks);

                        if (!compaction.info.move_table) {
                            // A compaction is marked as live at the start of a bar, unless it's
                            // move_table...
                            self.bar_active.set(i);

                            // ... and has its bar scoped buffers and budget assigned.
                            // TODO: This is an _excellent_ value to fuzz on.
                            // NB: While compaction is deterministic regardless of how much memory
                            // you give it, it's _not_ deterministic across different target
                            // budgets. This is because the target budget determines the beat grid
                            // block allocation, so whatever function calculates this in the future
                            // needs to itself be deterministic.
                            compaction.bar_setup_budget(
                                @divExact(constants.lsm_batch_multiple, 2),
                                ring_buffer,
                                immutable_table_a_block,
                            );
                        }
                    }
                }

                // At the start of a beat, the active compactions are those that are still active
                // in the bar.
                self.beat_active = self.bar_active;

                // TODO: Assert no compactions are running, and the pipeline is empty in a better
                // way. Maybe move to a union enum for state.
                for (self.slots) |slot| assert(slot == null);
                assert(self.callback == null);
                assert(self.forest == null);

                for (self.compactions.slice(), 0..) |*compaction, i| {
                    if (!self.bar_active.isSet(i)) continue;
                    if (compaction.info.move_table) continue;

                    self.beat_reserved.set(i);
                    compaction.beat_grid_reserve();
                }

                self.callback = callback;
                self.forest = forest;

                if (forest.compaction_pipeline.compactions.count() == 0) {
                    // No compactions - we're done! Likely we're < lsm_batch_multiple but it could
                    // be that empty ops were pulsed through.
                    maybe(op < constants.lsm_batch_multiple);

                    self.grid.on_next_tick(beat_finished_next_tick, &self.next_tick);
                    return;
                }

                // Everything up to this point has been sync and deterministic. We now enter
                // async-land by starting a read. The blip_callback will do the rest, including
                // filling and draining.
                self.state = .filling;
                self.advance_pipeline();
            }

            fn beat_finished_next_tick(next_tick: *Grid.NextTick) void {
                const self = @fieldParentPtr(CompactionPipeline, "next_tick", next_tick);

                assert(self.beat_active.count() == 0);
                assert(self.slot_filled_count == 0);
                assert(self.slot_running_count == 0);
                for (self.slots) |slot| assert(slot == null);

                assert(self.callback != null and self.forest != null);

                const callback = self.callback.?;
                const forest = self.forest.?;

                self.callback = null;
                self.forest = null;

                callback(forest);
            }

            // TODO: It would be great to get rid of *anyopaque here. Batiati's scan approach
            // wouldn't compile for some reason.
            fn blip_callback(
                compaction_interface_opaque: *anyopaque,
                maybe_exhausted: ?Exhausted,
            ) void {
                const compaction_interface: *CompactionInterface = @ptrCast(
                    @alignCast(compaction_interface_opaque),
                );
                const pipeline = @fieldParentPtr(
                    PipelineSlot,
                    "interface",
                    compaction_interface,
                ).pipeline;

                // TODO: Better way of getting the slot?
                const slot = blk: for (0..3) |i| {
                    if (pipeline.slots[i]) |*slot| {
                        if (&slot.interface == compaction_interface) {
                            log.debug("matching slot is {}", .{i});
                            break :blk slot;
                        }
                    }
                } else @panic("no matching slot");

                // Currently only merge is allowed to tell us we're exhausted.
                // TODO: In future, this will be extended to read, which might be able to, based
                // on key ranges.
                assert(maybe_exhausted == null or slot.active_operation == .merge);

                if (maybe_exhausted) |exhausted| {
                    if (exhausted.beat) {
                        log.debug("blip_callback: entering draining state", .{});
                        pipeline.state = .draining;
                    }

                    if (exhausted.bar) {
                        // If the bar is exhausted the beat must be exhausted too.
                        assert(pipeline.state == .draining);
                        log.debug(
                            "blip_callback: unsetting bar_active[{}]",
                            .{slot.compaction_index},
                        );
                        pipeline.bar_active.unset(slot.compaction_index);
                    }
                }

                pipeline.slot_running_count -= 1;
                if (pipeline.slot_running_count > 0) return;

                log.debug("blip_callback: all slots joined - advancing pipeline", .{});
                pipeline.advance_pipeline();
            }

            fn advance_pipeline(self: *CompactionPipeline) void {
                const active_compaction_index = self.beat_active.findFirstSet() orelse {
                    log.debug("advance_pipeline: all compactions finished - " ++
                        "calling beat_finished_next_tick()", .{});
                    self.grid.on_next_tick(beat_finished_next_tick, &self.next_tick);
                    return;
                };
                log.debug("advance_pipeline: active compaction is: {}", .{active_compaction_index});

                if (self.state == .filling or self.state == .full) {
                    // Advanced any filled stages, making sure to start our IO before CPU.
                    for (self.slots[0..self.slot_filled_count], 0..) |*slot_wrapped, i| {
                        const slot: *PipelineSlot = &slot_wrapped.*.?;

                        switch (slot.active_operation) {
                            .read => {
                                log.debug("advance_pipeline: read done, scheduling " ++
                                    "blip_merge on {}", .{i});

                                assert(self.cpu_slot == null);

                                self.cpu_slot = slot;
                                slot.active_operation = .merge;
                                self.slot_running_count += 1;

                                // TODO: This doesn't actually allow the CPU work and IO work to
                                // happen at the same time! next_tick goes to a queue which is
                                // processed before submitted IO...
                                self.grid.on_next_tick(
                                    advance_pipeline_next_tick,
                                    &self.next_tick,
                                );
                            },
                            .merge => {
                                log.debug("advance_pipeline: merge done, calling " ++
                                    "blip_write on {}", .{i});

                                slot.active_operation = .write;
                                self.slot_running_count += 1;
                                slot.interface.blip_write(blip_callback);
                            },
                            .write => {
                                log.debug("advance_pipeline: write done, calling " ++
                                    "blip_read on {}", .{i});
                                slot.active_operation = .read;
                                self.slot_running_count += 1;
                                slot.interface.blip_read(blip_callback);
                            },
                            .drained => unreachable,
                        }
                    }

                    // Fill any empty slots (slots always start in read).
                    if (self.state == .filling) {
                        const slot_idx = self.slot_filled_count;

                        log.debug("advance_pipeline: filling slot={} with blip_read", .{slot_idx});
                        assert(self.slots[slot_idx] == null);

                        self.slots[slot_idx] = .{
                            .pipeline = self,
                            .interface = self.compactions.slice()[active_compaction_index],
                            .active_operation = .read,
                            .compaction_index = active_compaction_index,
                        };

                        if (slot_idx == 0) {
                            self.slots[slot_idx].?.interface.beat_blocks_assign(
                                self.divide_blocks(),
                            );
                        }

                        // We always start with a read.
                        self.slot_running_count += 1;
                        self.slot_filled_count += 1;

                        self.slots[slot_idx].?.interface.blip_read(blip_callback);

                        if (self.slot_filled_count == 3) {
                            self.state = .full;
                        }
                    }
                } else if (self.state == .draining) {
                    // We enter the draining state by blip_merge. Any concurrent writes would have
                    // a barrier along with it, but we need to worry about writing the blocks that
                    // this last blip_merge _just_ created.
                    for (self.slots[0..self.slot_filled_count]) |*slot_wrapped| {
                        const slot: *PipelineSlot = &slot_wrapped.*.?;

                        switch (slot.active_operation) {
                            .merge => {
                                slot.active_operation = .write;
                                self.slot_running_count += 1;
                                self.state = .drained;
                                slot.interface.blip_write(blip_callback);
                            },
                            else => {
                                slot.active_operation = .drained;
                            },
                        }
                    }
                } else if (self.state == .drained) {
                    log.debug("advance_pipeline: final blip_write finished", .{});

                    // TODO: Resetting these below variables like this isn't great.
                    self.beat_active.unset(self.slots[0].?.compaction_index);

                    self.slot_filled_count = 0;
                    assert(self.slot_running_count == 0);
                    self.state = .filling;
                    self.slots = .{ null, null, null };

                    return self.advance_pipeline();
                } else unreachable;

                // TODO: Take a leaf out of vsr's book and implement logging showing state.
            }

            fn advance_pipeline_next_tick(next_tick: *Grid.NextTick) void {
                const self = @fieldParentPtr(CompactionPipeline, "next_tick", next_tick);
                assert(self.cpu_slot != null);
                const cpu_slot = self.cpu_slot.?;
                self.cpu_slot = null;

                // TODO: next_tick will just invoke our CPU work sync. We need to submit to the
                // underlying event loop before calling blip_merge.
                // var timeouts: usize = 0;
                // var etime = false;
                // self.grid.superblock.storage.io.flush_submissions(0, &timeouts, &etime) catch
                //     unreachable;

                assert(cpu_slot.active_operation == .merge);
                assert(self.slot_running_count > 0);

                log.debug("advance_pipeline_next_tick: calling blip_merge on cpu_slot", .{});
                cpu_slot.interface.blip_merge(blip_callback);
            }

            fn beat_grid_forfeit_all(self: *CompactionPipeline) void {
                var i = self.compactions.count();
                while (i > 0) {
                    i -= 1;

                    // We need to run this for all compactions that ran acquire - even if they
                    // transitioned to being finished, so we can't just use bar_active.
                    if (!self.beat_reserved.isSet(i)) continue;

                    // TODO: CompactionInterface internally stores a pointer to the real
                    // Compaction interface, so by-value is OK, but we're a bit all over the place.
                    self.compactions.slice()[i].beat_grid_forfeit();
                    self.beat_reserved.unset(i);
                }

                assert(self.beat_reserved.count() == 0);
            }
        };

        progress: ?union(enum) {
            open: struct { callback: Callback },
            checkpoint: struct { callback: Callback },
            compact: struct {
                op: u64,
                callback: Callback,
            },
        } = null,

        compaction_progress: enum { idle, trees_or_manifest, trees_and_manifest } = .idle,

        grid: *Grid,
        grooves: Grooves,
        node_pool: *NodePool,
        manifest_log: ManifestLog,
        manifest_log_progress: enum { idle, compacting, done, skip } = .idle,

        compaction_pipeline: CompactionPipeline,

        scan_buffer_pool: ScanBufferPool,

        pub fn init(
            allocator: mem.Allocator,
            grid: *Grid,
            node_count: u32,
            // (e.g.) .{ .transfers = .{ .cache_entries_max = 128, … }, .accounts = … }
            grooves_options: GroovesOptions,
        ) !Forest {
            // NodePool must be allocated to pass in a stable address for the Grooves.
            const node_pool = try allocator.create(NodePool);
            errdefer allocator.destroy(node_pool);

            // TODO: look into using lsm_table_size_max for the node_count.
            node_pool.* = try NodePool.init(allocator, node_count);
            errdefer node_pool.deinit(allocator);

            var manifest_log = try ManifestLog.init(allocator, grid, .{
                .tree_id_min = tree_id_range.min,
                .tree_id_max = tree_id_range.max,
                // TODO Make this a runtime argument (from the CLI, derived from storage-size-max if
                // possible).
                .forest_table_count_max = table_count_max,
            });
            errdefer manifest_log.deinit(allocator);

            var grooves: Grooves = undefined;
            var grooves_initialized: usize = 0;

            errdefer inline for (std.meta.fields(Grooves), 0..) |field, field_index| {
                if (grooves_initialized >= field_index + 1) {
                    @field(grooves, field.name).deinit(allocator);
                }
            };

            inline for (std.meta.fields(Grooves)) |groove_field| {
                const groove = &@field(grooves, groove_field.name);
                const Groove = @TypeOf(groove.*);
                const groove_options: Groove.Options = @field(grooves_options, groove_field.name);

                groove.* = try Groove.init(allocator, node_pool, grid, groove_options);
                grooves_initialized += 1;
            }

            var compaction_pipeline = try CompactionPipeline.init(allocator, grid);
            errdefer compaction_pipeline.deinit(allocator);

            const scan_buffer_pool = try ScanBufferPool.init(allocator);
            errdefer scan_buffer_pool.deinit(allocator);

            return Forest{
                .grid = grid,
                .grooves = grooves,
                .node_pool = node_pool,
                .manifest_log = manifest_log,

                .compaction_pipeline = compaction_pipeline,

                .scan_buffer_pool = scan_buffer_pool,
            };
        }

        pub fn deinit(forest: *Forest, allocator: mem.Allocator) void {
            inline for (std.meta.fields(Grooves)) |field| {
                @field(forest.grooves, field.name).deinit(allocator);
            }

            forest.manifest_log.deinit(allocator);
            forest.node_pool.deinit(allocator);
            allocator.destroy(forest.node_pool);

            forest.compaction_pipeline.deinit(allocator);
            forest.scan_buffer_pool.deinit(allocator);
        }

        pub fn reset(forest: *Forest) void {
            inline for (std.meta.fields(Grooves)) |field| {
                @field(forest.grooves, field.name).reset();
            }

            forest.manifest_log.reset();
            forest.node_pool.reset();
            forest.scan_buffer_pool.reset();
            forest.compaction_pipeline.reset();

            forest.* = .{
                // Don't reset the grid – replica is responsible for grid cancellation.
                .grid = forest.grid,
                .grooves = forest.grooves,
                .node_pool = forest.node_pool,
                .manifest_log = forest.manifest_log,

                .compaction_pipeline = forest.compaction_pipeline,

                .scan_buffer_pool = forest.scan_buffer_pool,
            };
        }

        pub fn open(forest: *Forest, callback: Callback) void {
            assert(forest.progress == null);
            assert(forest.manifest_log_progress == .idle);

            forest.progress = .{ .open = .{ .callback = callback } };

            inline for (std.meta.fields(Grooves)) |field| {
                @field(forest.grooves, field.name).open_commence(&forest.manifest_log);
            }

            forest.manifest_log.open(manifest_log_open_event, manifest_log_open_callback);
        }

        fn manifest_log_open_event(
            manifest_log: *ManifestLog,
            table: *const schema.ManifestNode.TableInfo,
        ) void {
            const forest = @fieldParentPtr(Forest, "manifest_log", manifest_log);
            assert(forest.progress.? == .open);
            assert(forest.manifest_log_progress == .idle);
            assert(table.label.level < constants.lsm_levels);
            assert(table.label.event != .remove);

            switch (table.tree_id) {
                inline tree_id_range.min...tree_id_range.max => |tree_id| {
                    var tree: *TreeForIdType(tree_id) = forest.tree_for_id(tree_id);
                    tree.open_table(table);
                },
                else => {
                    log.err("manifest_log_open_event: unknown table in manifest: {}", .{table});
                    @panic("Forest.manifest_log_open_event: unknown table in manifest");
                },
            }
        }

        fn manifest_log_open_callback(manifest_log: *ManifestLog) void {
            const forest = @fieldParentPtr(Forest, "manifest_log", manifest_log);
            assert(forest.progress.? == .open);
            assert(forest.manifest_log_progress == .idle);
            forest.verify_tables_recovered();

            inline for (std.meta.fields(Grooves)) |field| {
                @field(forest.grooves, field.name).open_complete();
            }
            forest.verify_table_extents();

            const callback = forest.progress.?.open.callback;
            forest.progress = null;
            callback(forest);
        }

        pub fn compact(forest: *Forest, callback: Callback, op: u64) void {
            const compaction_beat = op % constants.lsm_batch_multiple;

            const first_beat = compaction_beat == 0;
            const last_half_beat = compaction_beat ==
                @divExact(constants.lsm_batch_multiple, 2) - 1;
            const half_beat = compaction_beat == @divExact(constants.lsm_batch_multiple, 2);
            const last_beat = compaction_beat == constants.lsm_batch_multiple - 1;
            assert(@intFromBool(first_beat) + @intFromBool(last_half_beat) +
                @intFromBool(half_beat) + @intFromBool(last_beat) <= 1);

            log.debug("entering forest.compact() op={} constants.lsm_batch_multiple={} " ++
                "first_beat={} last_half_beat={} half_beat={} last_beat={}", .{
                op,
                constants.lsm_batch_multiple,
                first_beat,
                last_half_beat,
                half_beat,
                last_beat,
            });

            // Setup loop, runs only on the first beat of every bar, before any async work is done.
            // If we recovered from a checkpoint, we must avoid replaying one bar of
            // compactions that were applied before the checkpoint. Repeating these ops'
            // compactions would actually perform different compactions than before,
            // causing the storage state of the replica to diverge from the cluster.
            // See also: compaction_op_min().
            if ((first_beat or half_beat) and
                !forest.grid.superblock.working.vsr_state.op_compacted(op))
            {
                if (first_beat)
                    assert(forest.compaction_pipeline.compactions.count() == 0);

                // Iterate by levels first, then trees, as we expect similar levels to have similar
                // time-of-death for writes. This helps internal SSD GC.
                for (0..constants.lsm_levels) |level_b| {
                    inline for (tree_id_range.min..tree_id_range.max + 1) |tree_id| {
                        var tree = tree_for_id(forest, tree_id);
                        assert(tree.compactions.len == constants.lsm_levels);

                        var compaction = &tree.compactions[level_b];

                        // This returns information on what compaction work needs to be done. In
                        // future, this will be used to schedule compactions in a more optimal way.
                        if ((compaction.level_b % 2 != 0 and first_beat) or
                            (compaction.level_b % 2 == 0 and half_beat))
                        {
                            if (compaction.bar_setup(tree, op)) |info| {
                                forest.compaction_pipeline.compactions.append_assume_capacity(
                                    CompactionInterface.init(info, compaction),
                                );
                                log.debug("level_b={} tree={s} op={}", .{
                                    level_b,
                                    tree.config.name,
                                    op,
                                });
                            }
                        }
                    }
                }
            }

            forest.progress = .{ .compact = .{
                .op = op,
                .callback = callback,
            } };

            // Compaction only starts > lsm_batch_multiple because nothing compacts in the first
            // bar.
            assert(op >= constants.lsm_batch_multiple or
                forest.compaction_pipeline.compactions.count() == 0);
            assert(forest.compaction_progress == .idle);

            forest.compaction_progress = .trees_or_manifest;
            forest.compaction_pipeline.beat(forest, op, compact_callback);

            // Manifest log compaction. Run on the last beat of the bar.
            // TODO: Figure out a plan wrt the pacing here. Putting it on the last beat kinda-sorta
            // balances out, because we expect to naturally do less other compaction work on the
            // last beat.
            // The first bar has no manifest compaction.
            if ((last_beat or last_half_beat) and op > constants.lsm_batch_multiple) {
                forest.manifest_log_progress = .compacting;
                forest.manifest_log.compact(compact_manifest_log_callback, op);
                forest.compaction_progress = .trees_and_manifest;
            } else {
                assert(forest.manifest_log_progress == .idle);
            }
        }

        fn compact_callback(forest: *Forest) void {
            assert(forest.progress.? == .compact);
            assert(forest.compaction_progress != .idle);

            if (forest.compaction_progress == .trees_and_manifest)
                assert(forest.manifest_log_progress != .idle);

            forest.compaction_progress = if (forest.compaction_progress == .trees_and_manifest)
                .trees_or_manifest
            else
                .idle;
            if (forest.compaction_progress != .idle) return;

            forest.verify_table_extents();

            const progress = &forest.progress.?.compact;

            assert(forest.progress.? == .compact);
            const op = forest.progress.?.compact.op;

            const compaction_beat = op % constants.lsm_batch_multiple;
            const last_half_beat = compaction_beat == @divExact(
                constants.lsm_batch_multiple,
                2,
            ) - 1;
            const last_beat = compaction_beat == constants.lsm_batch_multiple - 1;

            // Forfeit any remaining grid reservations.
            forest.compaction_pipeline.beat_grid_forfeit_all();

            // Apply the changes to the manifest. This will run at the target compaction beat
            // that is requested.
            if (last_beat or last_half_beat) {
                for (forest.compaction_pipeline.compactions.slice()) |*compaction| {
                    if (compaction.info.level_b % 2 == 0 and last_half_beat) continue;
                    if (compaction.info.level_b % 2 != 0 and last_beat) continue;

                    assert(forest.manifest_log_progress == .compacting or
                        forest.manifest_log_progress == .done);
                    compaction.bar_apply_to_manifest();
                }
            }

            // Swap the mutable and immutable tables; this must happen on the last beat, regardless
            // of pacing.
            if (last_beat) {
                inline for (tree_id_range.min..tree_id_range.max + 1) |tree_id| {
                    const tree = tree_for_id(forest, tree_id);

                    log.debug("swap_mutable_and_immutable({s})", .{tree.config.name});
                    tree.swap_mutable_and_immutable(
                        snapshot_min_for_table_output(compaction_op_min(op)),
                    );

                    // Ensure tables haven't overflowed.
                    tree.manifest.assert_level_table_counts();
                }

                // While we're here, check that all compactions have finished by the last beat, and
                // reset our pipeline state.
                assert(forest.compaction_pipeline.bar_active.count() == 0);
                forest.compaction_pipeline.compactions.clear();
            }

            // Groove sync compaction - must be done after all async work for the beat completes???
            inline for (std.meta.fields(Grooves)) |field| {
                @field(forest.grooves, field.name).compact(op);
            }

            // On the last beat of the bar, make sure that manifest log compaction is finished.
            if (last_beat or last_half_beat) {
                switch (forest.manifest_log_progress) {
                    .idle => {},
                    .compacting => unreachable,
                    .done => {
                        forest.manifest_log.compact_end();
                        forest.manifest_log_progress = .idle;
                    },
                    .skip => {},
                }
            }

            const callback = progress.callback;
            forest.progress = null;

            callback(forest);
        }

        fn compact_manifest_log_callback(manifest_log: *ManifestLog) void {
            const forest = @fieldParentPtr(Forest, "manifest_log", manifest_log);
            assert(forest.manifest_log_progress == .compacting);

            forest.manifest_log_progress = .done;

            if (forest.progress) |progress| {
                assert(progress == .compact);

                forest.compact_callback();
            } else {
                // The manifest log compaction completed between compaction beats.
            }
        }

        fn GrooveFor(comptime groove_field_name: []const u8) type {
            const groove_field = @field(std.meta.FieldEnum(Grooves), groove_field_name);
            return std.meta.FieldType(Grooves, groove_field);
        }

        pub fn checkpoint(forest: *Forest, callback: Callback) void {
            assert(forest.progress == null);
            assert(forest.manifest_log_progress == .idle);
            forest.grid.assert_only_repairing();
            forest.verify_table_extents();

            forest.progress = .{ .checkpoint = .{ .callback = callback } };

            inline for (std.meta.fields(Grooves)) |field| {
                @field(forest.grooves, field.name).assert_between_bars();
            }

            forest.manifest_log.checkpoint(checkpoint_manifest_log_callback);
        }

        fn checkpoint_manifest_log_callback(manifest_log: *ManifestLog) void {
            const forest = @fieldParentPtr(Forest, "manifest_log", manifest_log);
            assert(forest.progress.? == .checkpoint);
            assert(forest.manifest_log_progress == .idle);
            forest.verify_table_extents();
            forest.verify_tables_recovered();

            const callback = forest.progress.?.checkpoint.callback;
            forest.progress = null;
            callback(forest);
        }

        fn TreeForIdType(comptime tree_id: u16) type {
            const tree_info = tree_infos[tree_id - tree_id_range.min];
            assert(tree_info.tree_id == tree_id);

            return tree_info.Tree;
        }

        pub fn tree_for_id(forest: *Forest, comptime tree_id: u16) *TreeForIdType(tree_id) {
            const tree_info = tree_infos[tree_id - tree_id_range.min];
            assert(tree_info.tree_id == tree_id);

            var groove = &@field(forest.grooves, tree_info.groove_name);

            switch (tree_info.groove_tree) {
                .objects => return &groove.objects,
                .ids => return &groove.ids,
                .indexes => |index_name| return &@field(groove.indexes, index_name),
            }
        }

        pub fn tree_for_id_const(
            forest: *const Forest,
            comptime tree_id: u16,
        ) *const TreeForIdType(tree_id) {
            const tree_info = tree_infos[tree_id - tree_id_range.min];
            assert(tree_info.tree_id == tree_id);

            const groove = &@field(forest.grooves, tree_info.groove_name);

            switch (tree_info.groove_tree) {
                .objects => return &groove.objects,
                .ids => return &groove.ids,
                .indexes => |index_name| return &@field(groove.indexes, index_name),
            }
        }

        /// Verify that `ManifestLog.table_extents` has an extent for every active table.
        ///
        /// (Invoked between beats.)
        fn verify_table_extents(forest: *const Forest) void {
            var tables_count: usize = 0;
            inline for (tree_id_range.min..tree_id_range.max + 1) |tree_id| {
                for (0..constants.lsm_levels) |level| {
                    const tree_level = forest.tree_for_id_const(tree_id).manifest.levels[level];
                    tables_count += tree_level.tables.len();

                    if (constants.verify) {
                        var tables_iterator = tree_level.tables.iterator_from_index(0, .ascending);
                        while (tables_iterator.next()) |table| {
                            assert(forest.manifest_log.table_extents.get(table.address) != null);
                        }
                    }
                }
            }
            assert(tables_count == forest.manifest_log.table_extents.count());
        }

        /// Verify the tables recovered into the ManifestLevels after opening the manifest log.
        ///
        /// There are two strategies to reconstruct the LSM's manifest levels (i.e. the list of
        /// tables) from a superblock manifest:
        ///
        /// 1. Iterate the manifest events in chronological order, replaying each
        ///    insert/update/remove in sequence.
        /// 2. Iterate the manifest events in reverse-chronological order, ignoring events for
        ///    tables that have already been encountered.
        ///
        /// The manifest levels constructed by each strategy are identical.
        ///
        /// 1. This function implements strategy 1, to validate `ManifestLog.open()`.
        /// 2. `ManifestLog.open()` implements strategy 2.
        ///
        /// (Strategy 2 minimizes the number of ManifestLevel mutations.)
        ///
        /// (Invoked immediately after open() or checkpoint()).
        fn verify_tables_recovered(forest: *const Forest) void {
            const ForestTableIteratorType =
                @import("./forest_table_iterator.zig").ForestTableIteratorType;
            const ForestTableIterator = ForestTableIteratorType(Forest);

            assert(forest.grid.superblock.opened);
            assert(forest.manifest_log.opened);

            if (Forest.Storage != @import("../testing/storage.zig").Storage) return;

            // The manifest log is opened, which means we have all of the manifest blocks.
            // But if the replica is syncing, those blocks might still be writing (and thus not in
            // the TestStorage when we go to retrieve them).
            if (forest.grid.superblock.working.vsr_state.sync_op_max > 0) return;

            // The latest version of each table, keyed by table checksum.
            // Null when the table has been deleted.
            var tables_latest = std.AutoHashMap(u128, struct {
                table: schema.ManifestNode.TableInfo,
                manifest_block: u64,
                manifest_entry: u32,
            }).init(forest.grid.superblock.storage.allocator);
            defer tables_latest.deinit();

            // Replay manifest events in chronological order.
            // Accumulate all tables that belong in the recovered forest's ManifestLevels.
            for (0..forest.manifest_log.log_block_checksums.count) |i| {
                const block_checksum = forest.manifest_log.log_block_checksums.get(i).?;
                const block_address = forest.manifest_log.log_block_addresses.get(i).?;
                assert(block_address > 0);

                const block = forest.grid.superblock.storage.grid_block(block_address).?;
                const block_header = schema.header_from_block(block);
                assert(block_header.address == block_address);
                assert(block_header.checksum == block_checksum);
                assert(block_header.block_type == .manifest);

                const block_schema = schema.ManifestNode.from(block);
                assert(block_schema.entry_count > 0);
                assert(block_schema.entry_count <= schema.ManifestNode.entry_count_max);

                for (block_schema.tables_const(block), 0..) |*table, entry| {
                    if (table.label.event == .remove) {
                        maybe(tables_latest.remove(table.checksum));
                    } else {
                        tables_latest.put(table.checksum, .{
                            .table = table.*,
                            .manifest_block = block_address,
                            .manifest_entry = @intCast(entry),
                        }) catch @panic("oom");
                    }
                }

                if (i > 0) {
                    // Verify the linked-list.
                    const block_previous = schema.ManifestNode.previous(block).?;
                    assert(block_previous.checksum ==
                        forest.manifest_log.log_block_checksums.get(i - 1).?);
                    assert(block_previous.address ==
                        forest.manifest_log.log_block_addresses.get(i - 1).?);
                }
            }

            // Verify that the SuperBlock Manifest's table extents are correct.
            var tables_latest_iterator = tables_latest.valueIterator();
            var table_extent_counts: usize = 0;
            while (tables_latest_iterator.next()) |table| {
                const table_extent = forest.manifest_log.table_extents.get(table.table.address).?;
                assert(table.manifest_block == table_extent.block);
                assert(table.manifest_entry == table_extent.entry);

                table_extent_counts += 1;
            }
            assert(table_extent_counts == forest.manifest_log.table_extents.count());

            // Verify the tables in `tables` are exactly the tables recovered by the Forest.
            var forest_tables_iterator = ForestTableIterator{};
            while (forest_tables_iterator.next(forest)) |forest_table_item| {
                const table_latest = tables_latest.get(forest_table_item.checksum).?;
                assert(table_latest.table.label.level == forest_table_item.label.level);
                assert(std.meta.eql(table_latest.table.key_min, forest_table_item.key_min));
                assert(std.meta.eql(table_latest.table.key_max, forest_table_item.key_max));
                assert(table_latest.table.checksum == forest_table_item.checksum);
                assert(table_latest.table.address == forest_table_item.address);
                assert(table_latest.table.snapshot_min == forest_table_item.snapshot_min);
                assert(table_latest.table.snapshot_max == forest_table_item.snapshot_max);
                assert(table_latest.table.tree_id == forest_table_item.tree_id);

                const table_removed = tables_latest.remove(forest_table_item.checksum);
                assert(table_removed);
            }
            assert(tables_latest.count() == 0);
        }
    };
}
