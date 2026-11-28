//! A focused SPIR-V to HLSL translator used by the Direct3D backends.
//!
//! Direct3D consumes HLSL rather than SPIR-V, so the D3D11 and D3D12
//! backends decompile the module into HLSL 5.1 before calling
//! `D3DCompile`. The translator covers the subset of SPIR-V emitted by
//! Zig's SPIR-V backend and by `glslangValidator -V` for the shader
//! stages vfrhi supports.
//!
//! The generated control flow is a small state machine. Every basic
//! block becomes a `case` of a `switch` inside a `while (true)` loop,
//! which keeps the decompiler independent of structured control flow
//! reconstruction.
//!
//! Unsupported features include atomics, storage buffers, 16-bit
//! arithmetic, 64-bit integers, descriptor indexing, ray tracing and
//! mesh shader stages. Encountering an unsupported feature returns
//! `error.Unsupported` instead of emitting incorrect HLSL.
const std = @import("std");
const rhi = @import("rhi");
const types = rhi.types;
const Allocator = std.mem.Allocator;
const log = std.log.scoped(.dx3d);

/// Errors produced while parsing or decompiling SPIR-V.
pub const TranslateError = error{
    InvalidSpirv,
    Unsupported,
} || Allocator.Error;

/// Selects the register syntax used by the generated HLSL.
pub const Backend = enum {
    /// Direct3D 11: flat register numbers across all sets.
    d3d11,
    /// Direct3D 12: registers grouped into `space` values per set.
    d3d12,
};

/// A translated shader module.
pub const Translated = struct {
    source: []u8,
    allocator: Allocator,

    /// Frees the translated source.
    pub fn deinit(self: Translated) void {
        self.allocator.free(self.source);
    }
};

/// Translates one entry point of a SPIR-V module into HLSL.
///
/// # Args
/// - `allocator`: allocator for the returned source.
/// - `words`: SPIR-V words in little-endian host order.
/// - `stage`: stage expected by the caller.
/// - `entry_point`: name of the entry point to decompile.
/// - `backend`: Direct3D backend that consumes the source.
///
/// # Return
/// HLSL source owned by the caller.
///
/// # Error
/// - `error.InvalidSpirv`: the module is malformed.
/// - `error.Unsupported`: the module uses SPIR-V features the
///   translator does not implement.
pub fn translate(
    allocator: Allocator,
    words: []const u32,
    stage: types.ShaderStage,
    entry_point: []const u8,
    backend: Backend,
) TranslateError!Translated {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var context: Context = .{
        .a = arena.allocator(),
        .words = words,
        .backend = backend,
    };
    try context.parse();
    try context.selectEntryPoint(stage, entry_point);
    const source = try context.emit();
    return .{
        .source = try allocator.dupe(u8, source),
        .allocator = allocator,
    };
}

const Source = struct {
    allocator: Allocator,
    bytes: std.ArrayListUnmanaged(u8) = .empty,
    indent: u32 = 0,

    fn write(self: *Source, text: []const u8) Allocator.Error!void {
        try self.bytes.appendSlice(self.allocator, text);
    }

    fn print(
        self: *Source,
        comptime format: []const u8,
        args: anytype,
    ) Allocator.Error!void {
        const text = try std.fmt.allocPrint(
            self.allocator,
            format,
            args,
        );
        try self.write(text);
    }

    fn line(
        self: *Source,
        comptime format: []const u8,
        args: anytype,
    ) Allocator.Error!void {
        try self.writeIndent();
        try self.print(format, args);
        try self.write("\n");
    }

    fn writeIndent(self: *Source) Allocator.Error!void {
        var i: u32 = 0;
        while (i < self.indent) : (i += 1) {
            try self.write("    ");
        }
    }
};

const Inst = struct {
    opcode: u16,
    operands: []const u32,
};

const IdKind = enum {
    none,
    type,
    constant,
    variable,
    function,
    function_parameter,
    value,
    label,
};

const IdInfo = struct {
    kind: IdKind = .none,
    /// Result type for values and function parameters.
    type_id: u32 = 0,
};

const StorageClass = struct {
    const uniform_constant: u32 = 0;
    const input: u32 = 1;
    const uniform: u32 = 2;
    const output: u32 = 3;
    const workgroup: u32 = 4;
    const private: u32 = 6;
    const function: u32 = 7;
    const push_constant: u32 = 9;
    const storage_buffer: u32 = 12;
};

const ExecutionModel = struct {
    const vertex: u32 = 0;
    const tessellation_control: u32 = 1;
    const tessellation_evaluation: u32 = 2;
    const geometry: u32 = 3;
    const fragment: u32 = 4;
    const gl_compute: u32 = 5;
};

const DecorationState = struct {
    builtin: ?u32 = null,
    location: ?u32 = null,
    binding: ?u32 = null,
    descriptor_set: ?u32 = null,
    block: bool = false,
    buffer_block: bool = false,
    row_major: bool = false,
    array_stride: ?u32 = null,
    matrix_stride: ?u32 = null,
    offset: ?u32 = null,
    flat: bool = false,
    no_perspective: bool = false,
    centroid: bool = false,
    sample: bool = false,
    invariant: bool = false,
};

const MemberDecoration = struct {
    struct_id: u32,
    member: u32,
    state: DecorationState,
};

const ImageType = struct {
    sampled_type: u32,
    dim: u32,
    depth: u32,
    arrayed: bool,
    ms: bool,
    sampled: u32,
    format: u32,
};

const TypeKind = union(enum) {
    void,
    bool,
    int: struct { width: u32, signed: bool },
    float: struct { width: u32 },
    vector: struct { component: u32, count: u32 },
    matrix: struct { column: u32, count: u32 },
    image: ImageType,
    sampler,
    sampled_image: u32,
    array: struct { element: u32, length: u32 },
    runtime_array: u32,
    struct_: struct { members: []const u32 },
    pointer: struct { storage: u32, pointee: u32 },
    function: struct { return_type: u32, params: []const u32 },
    opaque_type,
};

const ConstantKind = enum {
    bool_value,
    scalar,
    composite,
    null_value,
    unsupported,
};

const Constant = struct {
    type_id: u32,
    kind: ConstantKind,
    bool_value: bool = false,
    words: [2]u32 = .{ 0, 0 },
    word_count: u8 = 0,
    constituents: []const u32 = &.{},
};

const OpaqueKind = enum {
    texture,
    sampler,
    combined,
};

const OpaqueValue = struct {
    kind: OpaqueKind,
    texture: []const u8,
    sampler: ?[]const u8 = null,
};

const Variable = struct {
    type_id: u32,
    storage: u32,
    initializer: ?u32,
    is_global: bool,
};

const EntryPoint = struct {
    model: u32,
    function: u32,
    name: []const u8,
    interface: []const u32,
};

const ExecutionMode = struct {
    entry: u32,
    mode: u32,
    literals: []const u32,
};

const Block = struct {
    label: u32,
    inst_start: usize,
    inst_end: usize,
};

const Function = struct {
    id: u32,
    return_type: u32,
    function_type: u32,
    body_start: usize,
    body_end: usize,
    params: std.ArrayListUnmanaged(u32) = .empty,
    insts: []Inst = &.{},
    blocks: []Block = &.{},

    fn blockIndex(self: Function, label: u32) ?usize {
        for (self.blocks, 0..) |block, index| {
            if (block.label == label) return index;
        }
        return null;
    }
};

const Context = struct {
    a: Allocator,
    words: []const u32,
    bound: u32 = 0,
    ids: []IdInfo = &.{},
    types: []?TypeKind = &.{},
    constants: []?Constant = &.{},
    variables: []?Variable = &.{},
    names: []?[]const u8 = &.{},
    decorations: []DecorationState = &.{},
    member_decorations: std.ArrayListUnmanaged(MemberDecoration) = .empty,
    entry_points: std.ArrayListUnmanaged(EntryPoint) = .empty,
    execution_modes: std.ArrayListUnmanaged(ExecutionMode) = .empty,
    functions: std.ArrayListUnmanaged(Function) = .empty,
    function_index: []?usize = &.{},
    glsl_std_450: ?u32 = null,
    backend: Backend = .d3d11,
    selected_entry: EntryPoint = undefined,
    selected_function: usize = 0,
    reachable: []bool = &.{},
    used_globals: []bool = &.{},
    opaque_values: []?OpaqueValue = &.{},
    inst_by_id: []?Inst = &.{},
    push_emitted: bool = false,

    fn parse(self: *Context) TranslateError!void {
        if (self.words.len < 5) return error.InvalidSpirv;
        if (self.words[0] != 0x07230203) return error.InvalidSpirv;
        self.bound = self.words[3];
        if (self.bound == 0 or self.bound > 1 << 22) {
            return error.InvalidSpirv;
        }

        self.ids = try self.a.alloc(IdInfo, self.bound);
        @memset(self.ids, .{});
        self.types = try self.a.alloc(?TypeKind, self.bound);
        @memset(self.types, null);
        self.constants = try self.a.alloc(?Constant, self.bound);
        @memset(self.constants, null);
        self.variables = try self.a.alloc(?Variable, self.bound);
        @memset(self.variables, null);
        self.names = try self.a.alloc(?[]const u8, self.bound);
        @memset(self.names, null);
        self.decorations = try self.a.alloc(DecorationState, self.bound);
        @memset(self.decorations, .{});
        self.function_index = try self.a.alloc(?usize, self.bound);
        @memset(self.function_index, null);
        self.inst_by_id = try self.a.alloc(?Inst, self.bound);
        @memset(self.inst_by_id, null);

        var current_function: ?*Function = null;
        var index: usize = 5;
        while (index < self.words.len) {
            const header = self.words[index];
            const word_count: usize = header >> 16;
            const opcode: u16 = @truncate(header);
            if (word_count == 0 or index + word_count > self.words.len) {
                return error.InvalidSpirv;
            }
            const operands = self.words[index + 1 .. index + word_count];
            const inst: Inst = .{ .opcode = opcode, .operands = operands };

            try self.parseInstruction(
                inst,
                &current_function,
                index,
            );
            index += word_count;
        }
        if (current_function != null) return error.InvalidSpirv;
    }

    fn parseInstruction(
        self: *Context,
        inst: Inst,
        current_function: *?*Function,
        word_index: usize,
    ) TranslateError!void {
        switch (inst.opcode) {
            // Debug and metadata.
            5 => try self.parseName(inst.operands),
            11 => {
                if (inst.operands.len >= 2) {
                    const name = try self.decodeString(inst.operands[1..]);
                    if (std.mem.eql(u8, name.text, "GLSL.std.450")) {
                        self.glsl_std_450 = inst.operands[0];
                    }
                }
            },
            15 => try self.parseEntryPoint(inst.operands),
            16 => try self.parseExecutionMode(inst.operands),
            71 => self.parseDecoration(inst.operands),
            72 => try self.parseMemberDecoration(inst.operands),

            // Types.
            19 => self.setType(inst.operands[0], .void),
            20 => self.setType(inst.operands[0], .bool),
            21 => {
                if (inst.operands.len < 3) return error.InvalidSpirv;
                self.setType(inst.operands[0], .{ .int = .{
                    .width = inst.operands[1],
                    .signed = inst.operands[2] != 0,
                } });
            },
            22 => {
                if (inst.operands.len < 2) return error.InvalidSpirv;
                self.setType(inst.operands[0], .{ .float = .{
                    .width = inst.operands[1],
                } });
            },
            23 => {
                if (inst.operands.len < 3) return error.InvalidSpirv;
                self.setType(inst.operands[0], .{ .vector = .{
                    .component = inst.operands[1],
                    .count = inst.operands[2],
                } });
            },
            24 => {
                if (inst.operands.len < 3) return error.InvalidSpirv;
                self.setType(inst.operands[0], .{ .matrix = .{
                    .column = inst.operands[1],
                    .count = inst.operands[2],
                } });
            },
            25 => {
                if (inst.operands.len < 8) return error.InvalidSpirv;
                self.setType(inst.operands[0], .{ .image = .{
                    .sampled_type = inst.operands[1],
                    .dim = inst.operands[2],
                    .depth = inst.operands[3],
                    .arrayed = inst.operands[4] != 0,
                    .ms = inst.operands[5] != 0,
                    .sampled = inst.operands[6],
                    .format = inst.operands[7],
                } });
            },
            26 => self.setType(inst.operands[0], .sampler),
            27 => {
                if (inst.operands.len < 2) return error.InvalidSpirv;
                self.setType(inst.operands[0], .{ .sampled_image = inst.operands[1] });
            },
            28 => {
                if (inst.operands.len < 3) return error.InvalidSpirv;
                self.setType(inst.operands[0], .{ .array = .{
                    .element = inst.operands[1],
                    .length = inst.operands[2],
                } });
            },
            29 => {
                if (inst.operands.len < 2) return error.InvalidSpirv;
                self.setType(inst.operands[0], .{ .runtime_array = inst.operands[1] });
            },
            30 => {
                if (inst.operands.len < 1) return error.InvalidSpirv;
                self.setType(inst.operands[0], .{ .struct_ = .{
                    .members = inst.operands[1..],
                } });
            },
            31 => self.setType(inst.operands[0], .opaque_type),
            32 => {
                if (inst.operands.len < 3) return error.InvalidSpirv;
                self.setType(inst.operands[0], .{ .pointer = .{
                    .storage = inst.operands[1],
                    .pointee = inst.operands[2],
                } });
            },
            33 => {
                if (inst.operands.len < 2) return error.InvalidSpirv;
                self.setType(inst.operands[0], .{ .function = .{
                    .return_type = inst.operands[1],
                    .params = inst.operands[2..],
                } });
            },

            // Constants.
            41, 48 => self.parseBoolConstant(inst.operands, true),
            42, 49 => self.parseBoolConstant(inst.operands, false),
            43, 50 => try self.parseScalarConstant(inst.operands),
            44, 51 => try self.parseCompositeConstant(inst.operands),
            46 => {
                if (inst.operands.len < 2) return error.InvalidSpirv;
                self.setConstant(inst.operands[1], .{
                    .type_id = inst.operands[0],
                    .kind = .null_value,
                });
            },
            52 => {
                if (inst.operands.len < 2) return error.InvalidSpirv;
                self.setConstant(inst.operands[1], .{
                    .type_id = inst.operands[0],
                    .kind = .unsupported,
                });
            },

            // Functions and variables.
            54 => {
                if (inst.operands.len < 4) return error.InvalidSpirv;
                try self.functions.append(self.a, .{
                    .id = inst.operands[1],
                    .return_type = inst.operands[0],
                    .function_type = inst.operands[3],
                    .body_start = word_index + 5,
                    .body_end = word_index + 5,
                });
                self.function_index[inst.operands[1]] =
                    self.functions.items.len - 1;
                self.ids[inst.operands[1]] = .{
                    .kind = .function,
                    .type_id = inst.operands[3],
                };
                current_function.* = &self.functions.items[
                    self.functions.items.len - 1
                ];
            },
            55 => {
                if (inst.operands.len < 2) return error.InvalidSpirv;
                self.ids[inst.operands[1]] = .{
                    .kind = .function_parameter,
                    .type_id = inst.operands[0],
                };
                if (current_function.*) |function| {
                    try function.params.append(self.a, inst.operands[1]);
                }
            },
            56 => {
                if (current_function.*) |function| {
                    function.body_end = word_index;
                }
                current_function.* = null;
            },
            59 => {
                if (inst.operands.len < 3) return error.InvalidSpirv;
                self.variables[inst.operands[1]] = .{
                    .type_id = inst.operands[0],
                    .storage = inst.operands[2],
                    .initializer = if (inst.operands.len >= 4)
                        inst.operands[3]
                    else
                        null,
                    .is_global = current_function.* == null,
                };
                self.ids[inst.operands[1]] = .{
                    .kind = .variable,
                    .type_id = inst.operands[0],
                };
            },
            248 => {
                if (inst.operands.len < 1) return error.InvalidSpirv;
                self.ids[inst.operands[0]] = .{
                    .kind = .label,
                };
            },
            else => {
                if (hasResult(inst.opcode) and
                    inst.operands.len >= 2)
                {
                    self.ids[inst.operands[1]] = .{
                        .kind = .value,
                        .type_id = inst.operands[0],
                    };
                    self.inst_by_id[inst.operands[1]] = inst;
                }
            },
        }
    }

    fn setType(self: *Context, id: u32, value: TypeKind) void {
        if (id >= self.bound) return;
        self.types[id] = value;
        self.ids[id] = .{ .kind = .type };
    }

    fn setConstant(self: *Context, id: u32, value: Constant) void {
        if (id >= self.bound) return;
        self.constants[id] = value;
        self.ids[id] = .{ .kind = .constant, .type_id = value.type_id };
    }

    fn parseName(
        self: *Context,
        operands: []const u32,
    ) TranslateError!void {
        if (operands.len < 2 or operands[0] >= self.bound) return;
        const name = try self.decodeString(operands[1..]);
        self.names[operands[0]] = name.text;
    }

    fn parseEntryPoint(
        self: *Context,
        operands: []const u32,
    ) TranslateError!void {
        if (operands.len < 3) return error.InvalidSpirv;
        const name = try self.decodeString(operands[2..]);
        const interface_start = 2 + name.word_count;
        if (interface_start > operands.len) return error.InvalidSpirv;
        try self.entry_points.append(self.a, .{
            .model = operands[0],
            .function = operands[1],
            .name = name.text,
            .interface = operands[interface_start..],
        });
    }

    fn parseExecutionMode(
        self: *Context,
        operands: []const u32,
    ) TranslateError!void {
        if (operands.len < 2) return error.InvalidSpirv;
        try self.execution_modes.append(self.a, .{
            .entry = operands[0],
            .mode = operands[1],
            .literals = operands[2..],
        });
    }

    fn parseDecoration(self: *Context, operands: []const u32) void {
        if (operands.len < 2 or operands[0] >= self.bound) return;
        applyDecoration(
            &self.decorations[operands[0]],
            operands[1],
            operands[2..],
        );
    }

    fn parseMemberDecoration(
        self: *Context,
        operands: []const u32,
    ) TranslateError!void {
        if (operands.len < 3) return error.InvalidSpirv;
        var state: DecorationState = .{};
        applyDecoration(&state, operands[2], operands[3..]);
        try self.member_decorations.append(self.a, .{
            .struct_id = operands[0],
            .member = operands[1],
            .state = state,
        });
    }

    fn parseBoolConstant(
        self: *Context,
        operands: []const u32,
        value: bool,
    ) void {
        if (operands.len < 2) return;
        self.setConstant(operands[1], .{
            .type_id = operands[0],
            .kind = .bool_value,
            .bool_value = value,
        });
    }

    fn parseScalarConstant(
        self: *Context,
        operands: []const u32,
    ) TranslateError!void {
        if (operands.len < 3 or operands.len > 4) {
            return error.InvalidSpirv;
        }
        if (operands.len - 2 > 2) return error.InvalidSpirv;
        var constant: Constant = .{
            .type_id = operands[0],
            .kind = .scalar,
            .word_count = @intCast(operands.len - 2),
        };
        for (operands[2..], 0..) |word, index| {
            constant.words[index] = word;
        }
        self.setConstant(operands[1], constant);
    }

    fn parseCompositeConstant(
        self: *Context,
        operands: []const u32,
    ) TranslateError!void {
        if (operands.len < 2) return error.InvalidSpirv;
        const constituents = try self.a.dupe(u32, operands[2..]);
        self.setConstant(operands[1], .{
            .type_id = operands[0],
            .kind = .composite,
            .constituents = constituents,
        });
    }

    fn selectEntryPoint(
        self: *Context,
        stage: types.ShaderStage,
        name: []const u8,
    ) TranslateError!void {
        var found: ?EntryPoint = null;
        for (self.entry_points.items) |entry| {
            if (!std.mem.eql(u8, entry.name, name)) continue;
            if (stageFromModel(entry.model) != stage) continue;
            found = entry;
            break;
        }
        self.selected_entry = found orelse {
            log.warn(
                "SPIR-V entry point '{s}' for stage {s} was not found",
                .{ name, @tagName(stage) },
            );
            return error.InvalidSpirv;
        };

        self.reachable = try self.a.alloc(bool, self.bound);
        @memset(self.reachable, false);
        self.used_globals = try self.a.alloc(bool, self.bound);
        @memset(self.used_globals, false);
        self.opaque_values = try self.a.alloc(?OpaqueValue, self.bound);
        @memset(self.opaque_values, null);

        const index = self.function_index[self.selected_entry.function] orelse
            return error.InvalidSpirv;
        self.selected_function = index;

        var work: std.ArrayListUnmanaged(u32) = .empty;
        defer work.deinit(self.a);
        try work.append(self.a, self.selected_entry.function);
        while (work.pop()) |function_id| {
            if (function_id >= self.bound or self.reachable[function_id]) {
                continue;
            }
            const function_index = self.function_index[function_id] orelse
                continue;
            self.reachable[function_id] = true;
            const function = &self.functions.items[function_index];
            try self.buildFunction(function);
            for (function.insts) |inst| {
                if (inst.opcode == 57 and inst.operands.len >= 3) {
                    try work.append(self.a, inst.operands[2]);
                }
            }
        }

        for (self.selected_entry.interface) |id| {
            if (id < self.bound) self.used_globals[id] = true;
        }
        for (self.functions.items) |function| {
            if (function.id >= self.bound or !self.reachable[function.id]) {
                continue;
            }
            for (function.insts) |inst| {
                for (inst.operands) |operand| {
                    if (operand < self.bound and
                        self.variables[operand] != null and
                        self.variables[operand].?.is_global)
                    {
                        self.used_globals[operand] = true;
                    }
                }
            }
        }
    }

    fn buildFunction(
        self: *Context,
        function: *Function,
    ) TranslateError!void {
        var insts: std.ArrayListUnmanaged(Inst) = .empty;
        defer insts.deinit(self.a);
        var blocks: std.ArrayListUnmanaged(Block) = .empty;
        defer blocks.deinit(self.a);

        var index = function.body_start;
        while (index < function.body_end) {
            const header = self.words[index];
            const word_count: usize = header >> 16;
            if (word_count == 0 or index + word_count > function.body_end) {
                return error.InvalidSpirv;
            }
            const opcode: u16 = @truncate(header);
            const operands = self.words[index + 1 .. index + word_count];
            if (opcode == 248) {
                if (operands.len < 1) return error.InvalidSpirv;
                try blocks.append(self.a, .{
                    .label = operands[0],
                    .inst_start = insts.items.len,
                    .inst_end = insts.items.len,
                });
            } else if (blocks.items.len != 0) {
                try insts.append(self.a, .{
                    .opcode = opcode,
                    .operands = operands,
                });
                blocks.items[blocks.items.len - 1].inst_end =
                    insts.items.len;
            }
            index += word_count;
        }
        function.insts = try insts.toOwnedSlice(self.a);
        function.blocks = try blocks.toOwnedSlice(self.a);
    }

    fn emit(self: *Context) TranslateError![]const u8 {
        var source: Source = .{ .allocator = self.a };
        try source.line("// Generated by vfrhi.", .{});
        try source.line("", .{});
        try self.emitStructDeclarations(&source);
        try self.emitGlobals(&source);
        try self.emitFunctionPrototypes(&source);
        try self.emitFunctions(&source);
        try self.emitEntryWrapper(&source);
        return source.bytes.items;
    }

    // ------------------------------------------------------------------
    // Structs and globals.
    // ------------------------------------------------------------------

    fn emitStructDeclarations(
        self: *Context,
        source: *Source,
    ) TranslateError!void {
        const State = enum { unvisited, visiting, done };
        const states = try self.a.alloc(State, self.bound);
        @memset(states, .unvisited);

        var id: u32 = 1;
        while (id < self.bound) : (id += 1) {
            const type_kind = self.types[id] orelse continue;
            switch (type_kind) {
                .struct_ => {},
                else => continue,
            }
            try self.emitStructDeclaration(source, id, states);
        }
    }

    fn emitStructDeclaration(
        self: *Context,
        source: *Source,
        id: u32,
        states: anytype,
    ) TranslateError!void {
        if (id >= self.bound) return error.InvalidSpirv;
        switch (states[id]) {
            .done => return,
            .visiting => return error.Unsupported,
            .unvisited => {},
        }
        states[id] = .visiting;
        const type_kind = self.types[id] orelse
            return error.InvalidSpirv;
        const info = type_kind.struct_;
        for (info.members) |member| {
            if (member < self.bound and self.types[member] != null) {
                switch (self.types[member].?) {
                    .struct_ => try self.emitStructDeclaration(
                        source,
                        member,
                        states,
                    ),
                    else => {},
                }
            }
        }
        try source.line("struct {s} {{", .{try self.structName(id)});
        source.indent += 1;
        for (info.members, 0..) |member, index| {
            const name = try self.fmt("m{d}", .{index});
            try source.line("{s};", .{
                try self.declaration(member, name),
            });
        }
        source.indent -= 1;
        try source.line("}};", .{});
        states[id] = .done;
    }

    fn emitGlobals(
        self: *Context,
        source: *Source,
    ) TranslateError!void {
        var id: u32 = 1;
        while (id < self.bound) : (id += 1) {
            const variable = self.variables[id] orelse continue;
            if (!variable.is_global or !self.used_globals[id]) continue;
            try self.emitGlobal(source, id, variable);
        }
    }

    fn emitGlobal(
        self: *Context,
        source: *Source,
        id: u32,
        variable: Variable,
    ) TranslateError!void {
        const deco = self.decorations[id];
        const pointer = self.types[variable.type_id] orelse
            return error.InvalidSpirv;
        const pointee = switch (pointer) {
            .pointer => |value| value.pointee,
            else => return error.InvalidSpirv,
        };

        switch (variable.storage) {
            StorageClass.input, StorageClass.output => {
                if (deco.builtin == null and deco.location == null) {
                    log.warn(
                        "interface variable {d} has no location",
                        .{id},
                    );
                    return error.Unsupported;
                }
                if (self.types[pointee]) |kind| {
                    switch (kind) {
                        .struct_, .array, .runtime_array => {
                            return error.Unsupported;
                        },
                        else => {},
                    }
                }
                try source.line("static {s};", .{
                    try self.declaration(pointee, try self.valueName(id)),
                });
            },
            StorageClass.uniform_constant => {
                try self.emitOpaqueResource(
                    source,
                    id,
                    pointee,
                    deco,
                );
            },
            StorageClass.uniform => {
                if (!self.isBlock(pointee)) {
                    return error.Unsupported;
                }
                try self.emitUniformBlock(
                    source,
                    id,
                    pointee,
                    deco,
                );
            },
            StorageClass.push_constant => {
                if (!self.isBlock(pointee)) {
                    return error.Unsupported;
                }
                try self.emitPushConstant(
                    source,
                    id,
                    pointee,
                );
            },
            StorageClass.private => {
                try source.line("static {s};", .{
                    try self.declaration(pointee, try self.valueName(id)),
                });
            },
            StorageClass.workgroup => {
                try source.line("groupshared {s};", .{
                    try self.declaration(pointee, try self.valueName(id)),
                });
            },
            StorageClass.storage_buffer => {
                return error.Unsupported;
            },
            else => return error.Unsupported,
        }
    }

    fn emitOpaqueResource(
        self: *Context,
        source: *Source,
        id: u32,
        pointee: u32,
        deco: DecorationState,
    ) TranslateError!void {
        const binding = deco.binding orelse {
            log.warn(
                "descriptor variable {d} has no binding decoration",
                .{id},
            );
            return error.Unsupported;
        };
        const set = deco.descriptor_set orelse 0;
        const kind = self.types[pointee] orelse
            return error.InvalidSpirv;
        switch (kind) {
            .sampled_image => |image_type| {
                const texture = try self.imageTextureType(image_type);
                const register = try self.resourceRegister(set, binding);
                const space = try self.spaceSuffix(set);
                try source.line(
                    "{s} {s} : register(t{d}{s});",
                    .{
                        texture,
                        try self.textureName(set, binding),
                        register,
                        space,
                    },
                );
                try source.line(
                    "SamplerState {s} : register(s{d}{s});",
                    .{
                        try self.samplerName(set, binding),
                        register,
                        space,
                    },
                );
            },
            .image => |image| {
                if (image.sampled == 2) {
                    return error.Unsupported;
                }
                const texture = try self.imageTextureType(pointee);
                const register = try self.resourceRegister(set, binding);
                const space = try self.spaceSuffix(set);
                try source.line(
                    "{s} {s} : register(t{d}{s});",
                    .{
                        texture,
                        try self.textureName(set, binding),
                        register,
                        space,
                    },
                );
            },
            .sampler => {
                const register = try self.resourceRegister(set, binding);
                const space = try self.spaceSuffix(set);
                try source.line(
                    "SamplerState {s} : register(s{d}{s});",
                    .{
                        try self.samplerName(set, binding),
                        register,
                        space,
                    },
                );
            },
            .array, .runtime_array => return error.Unsupported,
            else => return error.Unsupported,
        }
    }

    fn emitUniformBlock(
        self: *Context,
        source: *Source,
        id: u32,
        pointee: u32,
        deco: DecorationState,
    ) TranslateError!void {
        const binding = deco.binding orelse
            return error.Unsupported;
        const set = deco.descriptor_set orelse 0;
        const register = try self.resourceRegister(set, binding);
        const space = try self.spaceSuffix(set);
        try source.line(
            "cbuffer vfrhi_cb_s{d}_b{d} : register(b{d}{s}) {{",
            .{ set, binding, register, space },
        );
        source.indent += 1;
        try source.line("{s};", .{
            try self.declaration(pointee, try self.variableName(id)),
        });
        source.indent -= 1;
        try source.line("}};", .{});
    }

    fn emitPushConstant(
        self: *Context,
        source: *Source,
        id: u32,
        pointee: u32,
    ) TranslateError!void {
        if (self.push_emitted) return error.Unsupported;
        self.push_emitted = true;
        try source.line(
            "cbuffer vfrhi_push : register(b0{s}) {{",
            .{try self.pushRegisterSuffix()},
        );
        source.indent += 1;
        try source.line("{s};", .{
            try self.declaration(pointee, try self.variableName(id)),
        });
        source.indent -= 1;
        try source.line("}};", .{});
    }

    // ------------------------------------------------------------------
    // Functions.
    // ------------------------------------------------------------------

    fn emitFunctionPrototypes(
        self: *Context,
        source: *Source,
    ) TranslateError!void {
        for (self.functions.items) |*function| {
            if (function.id >= self.bound) continue;
            if (!self.reachable[function.id]) continue;
            if (function.id == self.selected_entry.function) continue;
            try self.emitFunctionSignature(
                source,
                function,
                false,
            );
            try source.write(";\n");
        }
    }

    fn emitFunctions(
        self: *Context,
        source: *Source,
    ) TranslateError!void {
        for (self.functions.items) |*function| {
            if (function.id >= self.bound) continue;
            if (!self.reachable[function.id]) continue;
            try self.emitFunctionSignature(source, function, true);
            try source.write(" {\n");
            source.indent += 1;
            try self.emitFunctionBody(source, function);
            source.indent -= 1;
            try source.line("}}", .{});
            try source.line("", .{});
        }
    }

    fn emitFunctionSignature(
        self: *Context,
        source: *Source,
        function: *Function,
        body: bool,
    ) TranslateError!void {
        _ = body;
        if (function.id == self.selected_entry.function) {
            try source.write("void vfrhi_entry_body(");
        } else {
            if (self.types[function.return_type]) |kind| {
                switch (kind) {
                    .void => try source.write("void "),
                    else => try source.write(try self.typeName(
                        function.return_type,
                    )),
                }
            } else {
                return error.InvalidSpirv;
            }
            try source.write(" ");
            try source.write(try self.fmt(
                "vfrhi_fn_{d}",
                .{function.id},
            ));
            try source.write("(");
        }
        if (function.id != self.selected_entry.function) {
            for (function.params.items, 0..) |param, index| {
                if (index != 0) try source.write(", ");
                try self.emitParameter(source, param);
            }
        }
        try source.write(")");
    }

    fn emitParameter(
        self: *Context,
        source: *Source,
        param: u32,
    ) TranslateError!void {
        const type_id = self.ids[param].type_id;
        const kind = self.types[type_id] orelse
            return error.InvalidSpirv;
        const effective = self.pointeeOf(type_id) orelse type_id;
        const effective_kind = self.types[effective] orelse
            return error.InvalidSpirv;
        switch (effective_kind) {
            .sampled_image => |image_type| {
                try source.write(try self.imageTextureType(image_type));
                try source.write(" ");
                try source.write(try self.textureParamName(param));
                try source.write(", SamplerState ");
                try source.write(try self.samplerParamName(param));
            },
            .image => |image| {
                if (image.sampled == 2) return error.Unsupported;
                try source.write(try self.imageTextureType(effective));
                try source.write(" ");
                try source.write(try self.textureParamName(param));
            },
            .sampler => {
                try source.write("SamplerState ");
                try source.write(try self.samplerParamName(param));
            },
            else => {
                switch (kind) {
                    .pointer => {
                        try source.write("inout ");
                        try source.write(try self.declaration(
                            effective,
                            try self.valueName(param),
                        ));
                    },
                    else => try source.write(try self.declaration(
                        type_id,
                        try self.valueName(param),
                    )),
                }
            },
        }
    }

    fn pointeeOf(self: *Context, type_id: u32) ?u32 {
        const kind = self.types[type_id] orelse return null;
        return switch (kind) {
            .pointer => |pointer| pointer.pointee,
            else => type_id,
        };
    }

    fn emitFunctionBody(
        self: *Context,
        source: *Source,
        function: *Function,
    ) TranslateError!void {
        try self.emitLocalDeclarations(source, function);
        if (function.blocks.len == 0) {
            try self.emitReturnZero(source, function);
            return;
        }

        const entry_label = function.blocks[0].label;
        try source.line("int vfrhi_pc = {d};", .{entry_label});
        try source.line("while (true) {{", .{});
        source.indent += 1;
        try source.line("switch (vfrhi_pc) {{", .{});
        source.indent += 1;
        for (function.blocks) |block| {
            try source.line("case {d}: {{", .{block.label});
            source.indent += 1;
            try self.emitBasicBlock(source, function, block);
            source.indent -= 1;
            try source.line("}}", .{});
        }
        try source.line("default: {{", .{});
        source.indent += 1;
        try self.emitReturnZero(source, function);
        source.indent -= 1;
        try source.line("}}", .{});
        source.indent -= 1;
        try source.line("}}", .{});
        source.indent -= 1;
        try source.line("}}", .{});
        try self.emitReturnZero(source, function);
    }

    fn emitLocalDeclarations(
        self: *Context,
        source: *Source,
        function: *Function,
    ) TranslateError!void {
        for (function.insts) |inst| {
            if (inst.opcode != 59 or inst.operands.len < 3) continue;
            const id = inst.operands[1];
            const variable = self.variables[id] orelse continue;
            if (variable.is_global) continue;
            const pointer = self.types[variable.type_id] orelse continue;
            const pointee = switch (pointer) {
                .pointer => |value| value.pointee,
                else => continue,
            };
            const name = try self.valueName(id);
            if (variable.initializer) |initializer| {
                try source.line("{s} = {s};", .{
                    try self.declaration(pointee, name),
                    try self.constantExpr(initializer),
                });
            } else {
                try source.line("{s};", .{
                    try self.declaration(pointee, name),
                });
            }
        }
        for (function.insts) |inst| {
            if (!hasResult(inst.opcode) or inst.operands.len < 2) {
                continue;
            }
            const id = inst.operands[1];
            const type_id = inst.operands[0];
            if (id >= self.bound or type_id >= self.bound) continue;
            if (self.ids[id].kind != .value) continue;
            if (inst.opcode == 65 or inst.opcode == 66 or
                inst.opcode == 67 or inst.opcode == 70 or
                inst.opcode == 86 or inst.opcode == 100 or
                inst.opcode == 1 or inst.opcode == 245)
            {
                continue;
            }
            if (self.isOpaque(type_id)) continue;
            if (self.types[type_id]) |value| {
                switch (value) {
                    .pointer, .function, .void => continue,
                    else => {},
                }
            }
            try source.line("{s};", .{
                try self.declaration(type_id, try self.valueName(id)),
            });
        }
        for (function.insts) |inst| {
            if (inst.opcode == 245 and inst.operands.len >= 2) {
                const id = inst.operands[1];
                if (self.isOpaque(inst.operands[0])) continue;
                try source.line("{s};", .{
                    try self.declaration(
                        inst.operands[0],
                        try self.valueName(id),
                    ),
                });
            }
        }
    }

    fn emitReturnZero(
        self: *Context,
        source: *Source,
        function: *Function,
    ) TranslateError!void {
        if (function.return_type == try self.voidTypeId()) {
            try source.line("return;", .{});
        } else {
            try source.line("return {s};", .{
                try self.nullExpr(function.return_type),
            });
        }
    }

    fn emitBasicBlock(
        self: *Context,
        source: *Source,
        function: *Function,
        block: Block,
    ) TranslateError!void {
        const insts = function.insts[block.inst_start..block.inst_end];
        for (insts) |inst| {
            switch (inst.opcode) {
                1, 8, 317, 245, 246, 247 => continue,
                else => try self.emitInstruction(
                    source,
                    function,
                    block,
                    inst,
                ),
            }
        }
    }

    fn emitInstruction(
        self: *Context,
        source: *Source,
        function: *Function,
        block: Block,
        inst: Inst,
    ) TranslateError!void {
        const operands = inst.operands;
        switch (inst.opcode) {
            59 => {},
            61 => try self.emitLoad(source, inst),
            62 => try self.emitStore(source, inst),
            63 => {
                if (operands.len < 2) return error.InvalidSpirv;
                try source.line("{s} = {s};", .{
                    try self.lvalue(operands[1]),
                    try self.lvalue(operands[0]),
                });
            },
            57 => try self.emitFunctionCall(source, inst),
            78 => try self.emitVectorInsert(source, inst),
            82 => try self.emitCompositeInsert(source, inst),
            249 => {
                if (operands.len < 1) return error.InvalidSpirv;
                try self.emitPhiAssignments(
                    source,
                    function,
                    block.label,
                    operands[0],
                );
                try source.line("vfrhi_pc = {d};", .{operands[0]});
                try source.line("continue;", .{});
            },
            250 => {
                if (operands.len < 3) return error.InvalidSpirv;
                try source.line("if ({s}) {{", .{
                    try self.valueName(operands[0]),
                });
                source.indent += 1;
                try self.emitPhiAssignments(
                    source,
                    function,
                    block.label,
                    operands[1],
                );
                try source.line("vfrhi_pc = {d};", .{operands[1]});
                source.indent -= 1;
                try source.line("}} else {{", .{});
                source.indent += 1;
                try self.emitPhiAssignments(
                    source,
                    function,
                    block.label,
                    operands[2],
                );
                try source.line("vfrhi_pc = {d};", .{operands[2]});
                source.indent -= 1;
                try source.line("}}", .{});
                try source.line("continue;", .{});
            },
            251 => try self.emitSwitch(source, function, block, inst),
            252, 4416 => {
                try source.line("discard;", .{});
                try self.emitReturnZero(source, function);
            },
            253, 255 => {
                if (function.return_type == try self.voidTypeId()) {
                    try source.line("return;", .{});
                } else {
                    try source.line("return {s};", .{
                        try self.nullExpr(function.return_type),
                    });
                }
            },
            254 => {
                if (operands.len < 1) return error.InvalidSpirv;
                try source.line("return {s};", .{
                    try self.valueName(operands[0]),
                });
            },
            99 => {
                if (operands.len < 3) return error.InvalidSpirv;
                const texture = try self.textureOf(operands[0]);
                try source.line("{s}[{s}] = {s};", .{
                    texture,
                    try self.valueName(operands[1]),
                    try self.valueName(operands[2]),
                });
            },
            224 => try source.line(
                "GroupMemoryBarrierWithGroupSync();",
                .{},
            ),
            225, 226 => try source.line("DeviceMemoryBarrier();", .{}),
            227 => {
                if (operands.len >= 2) {
                    try source.line("{s} = {s};", .{
                        try self.valueName(operands[1]),
                        try self.lvalue(operands[2]),
                    });
                }
            },
            228, 229, 230, 231, 232, 233, 234, 235, 236, 237, 238, 239, 240, 241, 242 => {
                log.warn(
                    "SPIR-V atomics are not supported by the Direct3D translator",
                    .{},
                );
                return error.Unsupported;
            },
            else => try self.emitValue(source, inst),
        }
    }

    fn emitLoad(
        self: *Context,
        source: *Source,
        inst: Inst,
    ) TranslateError!void {
        if (inst.operands.len < 3) return error.InvalidSpirv;
        const type_id = inst.operands[0];
        const result = inst.operands[1];
        const pointer = inst.operands[2];
        if (self.isOpaque(type_id)) {
            self.opaque_values[result] = try self.opaqueForPointer(pointer);
            return;
        }
        try source.line("{s} = {s};", .{
            try self.valueName(result),
            try self.lvalue(pointer),
        });
    }

    fn emitStore(
        self: *Context,
        source: *Source,
        inst: Inst,
    ) TranslateError!void {
        if (inst.operands.len < 2) return error.InvalidSpirv;
        try source.line("{s} = {s};", .{
            try self.lvalue(inst.operands[0]),
            try self.valueName(inst.operands[1]),
        });
    }

    fn emitFunctionCall(
        self: *Context,
        source: *Source,
        inst: Inst,
    ) TranslateError!void {
        if (inst.operands.len < 3) return error.InvalidSpirv;
        const result_id = inst.operands[1];
        const function_id = inst.operands[2];
        const function_name = if (function_id ==
            self.selected_entry.function)
            "vfrhi_entry_body"
        else
            try self.fmt("vfrhi_fn_{d}", .{function_id});
        var call = std.ArrayListUnmanaged(u8).empty;
        defer call.deinit(self.a);
        try call.appendSlice(self.a, function_name);
        try call.append(self.a, '(');

        const function_index = self.function_index[function_id];
        const params: []const u32 = if (function_index) |index|
            self.functions.items[index].params.items
        else
            &.{};

        var first = true;
        for (inst.operands[3..], 0..) |argument, index| {
            const param_type = if (index < params.len)
                self.ids[params[index]].type_id
            else
                self.ids[argument].type_id;
            const effective = self.pointeeOf(param_type) orelse param_type;
            const param_kind = self.types[effective];
            if (param_kind) |kind| {
                switch (kind) {
                    .sampled_image => {
                        if (!first) try call.appendSlice(self.a, ", ");
                        first = false;
                        try call.appendSlice(
                            self.a,
                            try self.textureOf(argument),
                        );
                        try call.appendSlice(self.a, ", ");
                        try call.appendSlice(
                            self.a,
                            try self.samplerOf(argument),
                        );
                        continue;
                    },
                    .image => {
                        if (!first) try call.appendSlice(self.a, ", ");
                        first = false;
                        try call.appendSlice(
                            self.a,
                            try self.textureOf(argument),
                        );
                        continue;
                    },
                    .sampler => {
                        if (!first) try call.appendSlice(self.a, ", ");
                        first = false;
                        try call.appendSlice(
                            self.a,
                            try self.samplerOf(argument),
                        );
                        continue;
                    },
                    else => {},
                }
            }
            if (!first) try call.appendSlice(self.a, ", ");
            first = false;
            const argument_name = if (self.isPointerValue(argument))
                try self.lvalue(argument)
            else
                try self.valueName(argument);
            try call.appendSlice(self.a, argument_name);
        }
        try call.append(self.a, ')');
        const return_type = self.types[inst.operands[0]] orelse
            return error.InvalidSpirv;
        switch (return_type) {
            .void => {
                try source.line("{s};", .{call.items});
                return;
            },
            else => {},
        }
        try source.line("{s} = {s};", .{
            try self.valueName(result_id),
            call.items,
        });
    }

    fn emitPhiAssignments(
        self: *Context,
        source: *Source,
        function: *Function,
        from_label: u32,
        target_label: u32,
    ) TranslateError!void {
        const index = function.blockIndex(target_label) orelse
            return error.InvalidSpirv;
        const target = function.blocks[index];
        const insts = function.insts[target.inst_start..target.inst_end];
        for (insts) |inst| {
            if (inst.opcode != 245) continue;
            if (inst.operands.len < 4) return error.InvalidSpirv;
            const result = inst.operands[1];
            var value: ?u32 = null;
            var pair: usize = 2;
            while (pair + 1 < inst.operands.len) : (pair += 2) {
                if (inst.operands[pair + 1] == from_label) {
                    value = inst.operands[pair];
                    break;
                }
            }
            const incoming = value orelse return error.InvalidSpirv;
            try source.line("{s} = {s};", .{
                try self.valueName(result),
                try self.valueName(incoming),
            });
        }
    }

    fn emitSwitch(
        self: *Context,
        source: *Source,
        function: *Function,
        block: Block,
        inst: Inst,
    ) TranslateError!void {
        const operands = inst.operands;
        if (operands.len < 2) return error.InvalidSpirv;
        try source.line("switch ({s}) {{", .{
            try self.valueName(operands[0]),
        });
        source.indent += 1;
        var pair: usize = 2;
        while (pair + 1 < operands.len) : (pair += 2) {
            try source.line("case {d}: {{", .{operands[pair]});
            source.indent += 1;
            try self.emitPhiAssignments(
                source,
                function,
                block.label,
                operands[pair + 1],
            );
            try source.line("vfrhi_pc = {d};", .{operands[pair + 1]});
            try source.line("break;", .{});
            source.indent -= 1;
            try source.line("}}", .{});
        }
        try source.line("default: {{", .{});
        source.indent += 1;
        try self.emitPhiAssignments(
            source,
            function,
            block.label,
            operands[1],
        );
        try source.line("vfrhi_pc = {d};", .{operands[1]});
        try source.line("break;", .{});
        source.indent -= 1;
        try source.line("}}", .{});
        source.indent -= 1;
        try source.line("}}", .{});
        try source.line("continue;", .{});
    }

    fn emitValue(
        self: *Context,
        source: *Source,
        inst: Inst,
    ) TranslateError!void {
        const operands = inst.operands;
        if (operands.len < 2) return error.InvalidSpirv;
        const type_id = operands[0];
        const result_id = operands[1];
        const name = try self.valueName(result_id);

        if (inst.opcode == 65 or inst.opcode == 66 or
            inst.opcode == 67 or inst.opcode == 70)
        {
            return;
        }
        if (inst.opcode == 86) {
            if (operands.len < 4) return error.InvalidSpirv;
            const image = try self.textureOf(operands[2]);
            const sampler = try self.samplerOf(operands[3]);
            self.opaque_values[result_id] = .{
                .kind = .combined,
                .texture = image,
                .sampler = sampler,
            };
            return;
        }
        if (inst.opcode == 100) {
            if (operands.len < 3) return error.InvalidSpirv;
            const image = try self.textureOf(operands[2]);
            self.opaque_values[result_id] = .{
                .kind = .texture,
                .texture = image,
            };
            return;
        }

        const expression = try self.instructionExpression(inst);
        try source.line("{s} = {s};", .{ name, expression });
        _ = type_id;
    }

    fn emitCompositeInsert(
        self: *Context,
        source: *Source,
        inst: Inst,
    ) TranslateError!void {
        const operands = inst.operands;
        if (operands.len < 5) return error.InvalidSpirv;
        const result = try self.valueName(operands[1]);
        const object = try self.valueName(operands[2]);
        const composite = try self.valueName(operands[3]);
        const composite_type = self.ids[operands[3]].type_id;
        try source.line("{s} = {s};", .{ result, composite });
        const target = try self.compositePath(
            result,
            composite_type,
            operands[4..],
        );
        try source.line("{s} = {s};", .{ target, object });
    }

    fn emitVectorInsert(
        self: *Context,
        source: *Source,
        inst: Inst,
    ) TranslateError!void {
        const operands = inst.operands;
        if (operands.len < 5) return error.InvalidSpirv;
        const result = try self.valueName(operands[1]);
        const vector = try self.valueName(operands[2]);
        const index = try self.valueName(operands[3]);
        const component = try self.valueName(operands[4]);
        try source.line("{s} = {s};", .{ result, vector });
        try source.line("{s}[{s}] = {s};", .{
            result,
            index,
            component,
        });
    }

    fn compositePath(
        self: *Context,
        base_name: []const u8,
        type_id: u32,
        indices: []const u32,
    ) TranslateError![]const u8 {
        var builder = std.ArrayListUnmanaged(u8).empty;
        defer builder.deinit(self.a);
        try builder.appendSlice(self.a, base_name);
        var current_type = type_id;
        for (indices) |index| {
            const type_kind = self.types[current_type] orelse
                return error.InvalidSpirv;
            switch (type_kind) {
                .struct_ => {
                    if (index >= type_kind.struct_.members.len) {
                        return error.InvalidSpirv;
                    }
                    try builder.appendSlice(
                        self.a,
                        try self.fmt(".m{d}", .{index}),
                    );
                    current_type = type_kind.struct_.members[index];
                },
                .array => |value| {
                    try builder.appendSlice(
                        self.a,
                        try self.fmt("[{d}]", .{index}),
                    );
                    current_type = value.element;
                },
                .runtime_array => |element| {
                    try builder.appendSlice(
                        self.a,
                        try self.fmt("[{d}]", .{index}),
                    );
                    current_type = element;
                },
                .vector => |value| {
                    try builder.appendSlice(
                        self.a,
                        try self.fmt("[{d}]", .{index}),
                    );
                    current_type = value.component;
                },
                .matrix => |value| {
                    try builder.appendSlice(
                        self.a,
                        try self.fmt("[{d}]", .{index}),
                    );
                    current_type = value.column;
                },
                else => return error.Unsupported,
            }
        }
        return self.a.dupe(u8, builder.items);
    }

    fn instructionExpression(
        self: *Context,
        inst: Inst,
    ) TranslateError![]const u8 {
        const operands = inst.operands;
        const type_id = operands[0];
        const a = if (operands.len > 2)
            try self.valueName(operands[2])
        else
            "";
        const b = if (operands.len > 3 and
            inst.opcode != 81 and inst.opcode != 68)
            try self.valueName(operands[3])
        else
            "";

        switch (inst.opcode) {
            61 => return error.InvalidSpirv,
            80 => return self.constructor(type_id, operands[2..]),
            81 => return self.compositeExtract(
                operands[2],
                operands[3..],
            ),
            77 => {
                if (operands.len < 4) return error.InvalidSpirv;
                return self.fmt(
                    "{s}[{s}]",
                    .{ a, try self.valueName(operands[3]) },
                );
            },
            79 => return self.vectorShuffle(inst),
            83 => return a,
            84 => return self.fmt("transpose({s})", .{a}),
            68 => return error.Unsupported,
            12 => return self.extInst(inst),
            86, 100 => return error.Unsupported,
            87, 88, 89, 90, 95, 96 => return self.imageInstruction(inst),
            98 => return self.imageRead(inst),
            103, 104, 105, 106, 107 => return error.Unsupported,
            109 => return self.fmt("uint({s})", .{a}),
            110 => return self.fmt("int({s})", .{a}),
            111 => return self.fmt("float({s})", .{a}),
            112 => return self.fmt("float({s})", .{a}),
            113 => return self.fmt("({s})({s})", .{
                try self.typeName(type_id),
                a,
            }),
            114, 115 => return self.fmt("({s})({s})", .{
                try self.typeName(type_id),
                a,
            }),
            116 => return error.Unsupported,
            117 => return error.Unsupported,
            118 => return error.Unsupported,
            119 => return error.Unsupported,
            120, 121, 122, 123 => return self.fmt("({s})({s})", .{
                try self.typeName(type_id),
                a,
            }),
            124 => return self.bitcast(type_id, operands[2]),
            126 => return self.fmt("(-{s})", .{a}),
            127 => return self.fmt("(-{s})", .{a}),
            128, 129, 130, 131, 132, 133, 134, 135, 136, 137, 138, 139, 140, 141 => {
                return self.binary(inst, a, b);
            },
            142, 143 => return self.fmt("({s} * {s})", .{ a, b }),
            144 => return self.fmt("({s} * {s})", .{ a, b }),
            145, 146, 147 => return self.fmt("mul({s}, {s})", .{ a, b }),
            148 => return self.fmt("dot({s}, {s})", .{ a, b }),
            149, 150, 151, 152, 153 => return error.Unsupported,
            154 => return self.fmt("any({s})", .{a}),
            155 => return self.fmt("all({s})", .{a}),
            156 => return self.fmt("isnan({s})", .{a}),
            157 => return self.fmt("isinf({s})", .{a}),
            158 => return self.fmt("isfinite({s})", .{a}),
            159 => return error.Unsupported,
            160, 161, 162, 163 => return error.Unsupported,
            164, 165, 166, 167, 168 => return self.logical(inst, a, b),
            169 => return self.select(inst),
            170, 171, 172, 173, 174, 175, 176, 177, 178, 179, 180, 181, 182, 183, 184, 185, 186, 187, 188, 189, 190, 191 => {
                return self.compare(inst, a, b);
            },
            194 => return self.fmt("({s} >> {s})", .{ a, b }),
            195 => return self.fmt("({s} >> {s})", .{ a, b }),
            196 => return self.fmt("({s} << {s})", .{ a, b }),
            197 => return self.fmt("({s} | {s})", .{ a, b }),
            198 => return self.fmt("({s} ^ {s})", .{ a, b }),
            199 => return self.fmt("({s} & {s})", .{ a, b }),
            200 => {
                const result_type = self.types[inst.operands[0]] orelse
                    return error.InvalidSpirv;
                switch (result_type) {
                    .bool => return self.fmt("(!{s})", .{a}),
                    .vector => |info| {
                        const component = self.types[info.component] orelse
                            return error.InvalidSpirv;
                        switch (component) {
                            .bool => return self.fmt("(!{s})", .{a}),
                            else => {},
                        }
                    },
                    else => {},
                }
                return self.fmt("(~{s})", .{a});
            },
            204 => return self.fmt("reversebits({s})", .{a}),
            205 => return self.fmt("countbits({s})", .{a}),
            207 => return self.fmt("ddx({s})", .{a}),
            208 => return self.fmt("ddy({s})", .{a}),
            209 => return self.fmt("fwidth({s})", .{a}),
            210 => return self.fmt("ddx({s})", .{a}),
            211 => return self.fmt("ddy({s})", .{a}),
            212 => return self.fmt("fwidth({s})", .{a}),
            213 => return self.fmt("ddx({s})", .{a}),
            214 => return self.fmt("ddy({s})", .{a}),
            215 => return self.fmt("fwidth({s})", .{a}),
            227 => return self.lvalue(operands[2]),
            else => {
                log.warn(
                    "unsupported SPIR-V opcode {d} in Direct3D translator",
                    .{inst.opcode},
                );
                return error.Unsupported;
            },
        }
    }

    fn binary(
        self: *Context,
        inst: Inst,
        a: []const u8,
        b: []const u8,
    ) TranslateError![]const u8 {
        const operator = switch (inst.opcode) {
            128, 129 => "+",
            130, 131 => "-",
            132, 133 => "*",
            134, 135, 136 => "/",
            137, 138, 139 => "%",
            140, 141 => return self.fmt("fmod({s}, {s})", .{ a, b }),
            else => return error.Unsupported,
        };
        if (inst.opcode == 139) {
            return self.fmt("((({s} % {s}) + {s}) % {s})", .{
                a,
                b,
                b,
                b,
            });
        }
        return self.fmt("({s} {s} {s})", .{ a, operator, b });
    }

    fn logical(
        self: *Context,
        inst: Inst,
        a: []const u8,
        b: []const u8,
    ) TranslateError![]const u8 {
        const result_type = self.types[inst.operands[0]] orelse
            return error.InvalidSpirv;
        const vector = switch (result_type) {
            .vector => |value| value,
            else => null,
        };
        if (vector != null) {
            const operator = switch (inst.opcode) {
                164, 166 => "|",
                165, 167 => "&",
                168 => return self.fmt("(!{s})", .{a}),
                else => return error.Unsupported,
            };
            return self.fmt("({s} {s} {s})", .{ a, operator, b });
        }
        const operator = switch (inst.opcode) {
            164, 166 => "||",
            165, 167 => "&&",
            168 => return self.fmt("(!{s})", .{a}),
            else => return error.Unsupported,
        };
        return self.fmt("({s} {s} {s})", .{ a, operator, b });
    }

    fn compare(
        self: *Context,
        inst: Inst,
        a: []const u8,
        b: []const u8,
    ) TranslateError![]const u8 {
        const operator = switch (inst.opcode) {
            170, 180, 181 => "==",
            171, 182, 183 => "!=",
            172, 173, 184, 185, 186, 187 => ">",
            174, 175, 188, 189, 190, 191 => ">=",
            176, 177 => "<",
            178, 179 => "<=",
            else => return error.Unsupported,
        };
        return self.fmt("({s} {s} {s})", .{ a, operator, b });
    }

    fn select(
        self: *Context,
        inst: Inst,
    ) TranslateError![]const u8 {
        if (inst.operands.len < 5) return error.InvalidSpirv;
        const condition_type = self.types[self.ids[inst.operands[2]].type_id] orelse
            return error.InvalidSpirv;
        switch (condition_type) {
            .vector => |info| {
                var builder = std.ArrayListUnmanaged(u8).empty;
                defer builder.deinit(self.a);
                try builder.appendSlice(
                    self.a,
                    try self.typeName(inst.operands[0]),
                );
                try builder.append(self.a, '(');
                var index: u32 = 0;
                while (index < info.count) : (index += 1) {
                    if (index != 0) try builder.appendSlice(self.a, ", ");
                    try builder.appendSlice(
                        self.a,
                        try self.fmt(
                            "({s}[{d}] ? {s}[{d}] : {s}[{d}])",
                            .{
                                try self.valueName(inst.operands[2]),
                                index,
                                try self.valueName(inst.operands[3]),
                                index,
                                try self.valueName(inst.operands[4]),
                                index,
                            },
                        ),
                    );
                }
                try builder.append(self.a, ')');
                return self.a.dupe(u8, builder.items);
            },
            else => {},
        }
        return self.fmt("({s} ? {s} : {s})", .{
            try self.valueName(inst.operands[2]),
            try self.valueName(inst.operands[3]),
            try self.valueName(inst.operands[4]),
        });
    }

    fn bitcast(
        self: *Context,
        target_type: u32,
        source: u32,
    ) TranslateError![]const u8 {
        const source_type = self.ids[source].type_id;
        const target = scalarClass(self, target_type);
        const from = scalarClass(self, source_type);
        const source_name = try self.valueName(source);
        if (target == .float and from == .float) return source_name;
        if (target == .signed and from == .signed) return source_name;
        if (target == .unsigned and from == .unsigned) return source_name;
        if (target == .signed and from == .unsigned) {
            return self.fmt("asint({s})", .{source_name});
        }
        if (target == .unsigned and from == .signed) {
            return self.fmt("asuint({s})", .{source_name});
        }
        if (target == .float and (from == .signed or from == .unsigned)) {
            return self.fmt("asfloat({s})", .{source_name});
        }
        if ((target == .signed or target == .unsigned) and
            from == .float)
        {
            if (target == .signed) {
                return self.fmt("asint({s})", .{source_name});
            }
            return self.fmt("asuint({s})", .{source_name});
        }
        return error.Unsupported;
    }

    fn constructor(
        self: *Context,
        type_id: u32,
        args: []const u32,
    ) TranslateError![]const u8 {
        const type_kind = self.types[type_id] orelse
            return error.InvalidSpirv;
        switch (type_kind) {
            .struct_, .array, .runtime_array => {
                var builder = std.ArrayListUnmanaged(u8).empty;
                defer builder.deinit(self.a);
                try builder.append(self.a, '{');
                for (args, 0..) |arg, index| {
                    if (index != 0) try builder.appendSlice(self.a, ", ");
                    try builder.appendSlice(
                        self.a,
                        try self.valueName(arg),
                    );
                }
                try builder.append(self.a, '}');
                return self.a.dupe(u8, builder.items);
            },
            .matrix => |matrix| {
                const column_type = self.types[matrix.column] orelse
                    return error.InvalidSpirv;
                const column = switch (column_type) {
                    .vector => |value| value,
                    else => return error.InvalidSpirv,
                };
                const component = try self.scalarName(column.component);
                var builder = std.ArrayListUnmanaged(u8).empty;
                defer builder.deinit(self.a);
                try builder.appendSlice(self.a, try self.typeName(type_id));
                try builder.append(self.a, '(');
                var row: u32 = 0;
                while (row < column.count) : (row += 1) {
                    var col: u32 = 0;
                    while (col < matrix.count) : (col += 1) {
                        if (row != 0 or col != 0) {
                            try builder.appendSlice(self.a, ", ");
                        }
                        if (col < args.len) {
                            try builder.appendSlice(
                                self.a,
                                try self.fmt("{s}[{d}]", .{
                                    try self.valueName(args[col]),
                                    row,
                                }),
                            );
                        } else {
                            try builder.appendSlice(
                                self.a,
                                try self.fmt("{s}(0)", .{component}),
                            );
                        }
                    }
                }
                try builder.append(self.a, ')');
                return self.a.dupe(u8, builder.items);
            },
            else => {
                var builder = std.ArrayListUnmanaged(u8).empty;
                defer builder.deinit(self.a);
                try builder.appendSlice(self.a, try self.typeName(type_id));
                try builder.append(self.a, '(');
                for (args, 0..) |arg, index| {
                    if (index != 0) try builder.appendSlice(self.a, ", ");
                    try builder.appendSlice(
                        self.a,
                        try self.valueName(arg),
                    );
                }
                try builder.append(self.a, ')');
                return self.a.dupe(u8, builder.items);
            },
        }
    }

    fn compositeExtract(
        self: *Context,
        base: u32,
        indices: []const u32,
    ) TranslateError![]const u8 {
        var expression = std.ArrayListUnmanaged(u8).empty;
        defer expression.deinit(self.a);
        try expression.appendSlice(self.a, try self.valueName(base));
        var type_id = self.ids[base].type_id;
        for (indices) |index| {
            const type_kind = self.types[type_id] orelse
                return error.InvalidSpirv;
            switch (type_kind) {
                .struct_ => {
                    if (index >= type_kind.struct_.members.len) {
                        return error.InvalidSpirv;
                    }
                    try expression.appendSlice(
                        self.a,
                        try self.fmt(".m{d}", .{index}),
                    );
                    type_id = type_kind.struct_.members[index];
                },
                .array => |value| {
                    try expression.appendSlice(
                        self.a,
                        try self.fmt("[{d}]", .{index}),
                    );
                    type_id = value.element;
                },
                .runtime_array => |element| {
                    try expression.appendSlice(
                        self.a,
                        try self.fmt("[{d}]", .{index}),
                    );
                    type_id = element;
                },
                .vector => |value| {
                    try expression.appendSlice(
                        self.a,
                        try self.fmt("[{d}]", .{index}),
                    );
                    type_id = value.component;
                },
                .matrix => |value| {
                    try expression.appendSlice(
                        self.a,
                        try self.fmt("[{d}]", .{index}),
                    );
                    type_id = value.column;
                },
                else => return error.Unsupported,
            }
        }
        return self.a.dupe(u8, expression.items);
    }

    fn vectorShuffle(
        self: *Context,
        inst: Inst,
    ) TranslateError![]const u8 {
        if (inst.operands.len < 5) return error.InvalidSpirv;
        const vector_a = inst.operands[2];
        const vector_b = inst.operands[3];
        const type_kind = self.types[inst.operands[0]] orelse
            return error.InvalidSpirv;
        const vector = switch (type_kind) {
            .vector => |value| value,
            else => return error.InvalidSpirv,
        };
        const component_type = try self.typeName(vector.component);
        const a_count = switch (self.types[self.ids[vector_a].type_id].?) {
            .vector => |value| value.count,
            else => return error.InvalidSpirv,
        };
        var builder = std.ArrayListUnmanaged(u8).empty;
        defer builder.deinit(self.a);
        try builder.appendSlice(self.a, try self.typeName(inst.operands[0]));
        try builder.append(self.a, '(');
        for (inst.operands[4..], 0..) |selector, index| {
            if (index != 0) try builder.appendSlice(self.a, ", ");
            if (selector == 0xffffffff) {
                try builder.appendSlice(
                    self.a,
                    try self.fmt("{s}(0)", .{component_type}),
                );
            } else if (selector < a_count) {
                try builder.appendSlice(
                    self.a,
                    try self.fmt("{s}[{d}]", .{
                        try self.valueName(vector_a),
                        selector,
                    }),
                );
            } else {
                try builder.appendSlice(
                    self.a,
                    try self.fmt("{s}[{d}]", .{
                        try self.valueName(vector_b),
                        selector - a_count,
                    }),
                );
            }
        }
        try builder.append(self.a, ')');
        return self.a.dupe(u8, builder.items);
    }

    fn imageInstruction(
        self: *Context,
        inst: Inst,
    ) TranslateError![]const u8 {
        const operands = inst.operands;
        if (operands.len < 4) return error.InvalidSpirv;
        const texture = try self.textureOf(operands[2]);
        const sampler = try self.samplerOf(operands[2]);
        const coord = try self.valueName(operands[3]);
        switch (inst.opcode) {
            87 => {
                if (operands.len > 4) {
                    const mask = operands[4];
                    var rest = operands[5..];
                    if (mask & 0x1 != 0) {
                        if (rest.len < 1) return error.InvalidSpirv;
                        const bias = try self.valueName(rest[0]);
                        rest = rest[1..];
                        return self.fmt(
                            "{s}.SampleBias({s}, {s}, {s})",
                            .{ texture, sampler, coord, bias },
                        );
                    }
                    if (mask & 0x2 != 0) {
                        if (rest.len < 1) return error.InvalidSpirv;
                        const lod = try self.valueName(rest[0]);
                        return self.fmt(
                            "{s}.SampleLevel({s}, {s}, {s})",
                            .{ texture, sampler, coord, lod },
                        );
                    }
                    if (mask & 0x8 != 0) {
                        if (rest.len < 1) return error.InvalidSpirv;
                        const offset = try self.valueName(rest[0]);
                        return self.fmt(
                            "{s}.Sample({s}, {s}, {s})",
                            .{ texture, sampler, coord, offset },
                        );
                    }
                    log.warn(
                        "unsupported texture image operand mask 0x{x}",
                        .{mask},
                    );
                    return error.Unsupported;
                }
                return self.fmt("{s}.Sample({s}, {s})", .{
                    texture,
                    sampler,
                    coord,
                });
            },
            88 => {
                if (operands.len < 6) return error.InvalidSpirv;
                const mask = operands[4];
                if (mask & 0x2 == 0) return error.Unsupported;
                const lod = try self.valueName(operands[5]);
                return self.fmt("{s}.SampleLevel({s}, {s}, {s})", .{
                    texture,
                    sampler,
                    coord,
                    lod,
                });
            },
            89, 90 => {
                if (operands.len < 5) return error.InvalidSpirv;
                const dref = try self.valueName(operands[4]);
                return self.fmt("{s}.SampleCmp({s}, {s}, {s})", .{
                    texture,
                    sampler,
                    coord,
                    dref,
                });
            },
            95 => {
                if (operands.len < 5) return error.InvalidSpirv;
                const lod = try self.valueName(operands[4]);
                return self.loadExpression(operands[2], coord, lod);
            },
            96 => {
                if (operands.len < 5) return error.InvalidSpirv;
                const component = try self.valueName(operands[4]);
                return self.fmt("{s}.Gather({s}, {s}, {s})", .{
                    texture,
                    sampler,
                    coord,
                    component,
                });
            },
            else => return error.Unsupported,
        }
    }

    fn imageRead(
        self: *Context,
        inst: Inst,
    ) TranslateError![]const u8 {
        const operands = inst.operands;
        if (operands.len < 4) return error.InvalidSpirv;
        const texture = try self.textureOf(operands[2]);
        const coord = try self.valueName(operands[3]);
        return self.fmt("{s}[{s}]", .{ texture, coord });
    }

    fn loadExpression(
        self: *Context,
        image_id: u32,
        coord: []const u8,
        lod: []const u8,
    ) TranslateError![]const u8 {
        const texture = try self.textureOf(image_id);
        const image = self.imageOf(image_id) orelse
            return error.Unsupported;
        const cast = switch (image.dim) {
            0 => try self.fmt("int2({s}, {s})", .{ coord, lod }),
            1 => try self.fmt("int3({s}, {s})", .{ coord, lod }),
            2 => try self.fmt("int4({s}, {s})", .{ coord, lod }),
            else => return error.Unsupported,
        };
        return self.fmt("{s}.Load({s})", .{ texture, cast });
    }

    fn extInst(
        self: *Context,
        inst: Inst,
    ) TranslateError![]const u8 {
        const operands = inst.operands;
        if (operands.len < 5) return error.InvalidSpirv;
        const set = operands[2];
        if (self.glsl_std_450 == null or set != self.glsl_std_450.?) {
            return error.Unsupported;
        }
        const instruction = operands[3];
        const name = hlslExtInstName(instruction) orelse
            return error.Unsupported;
        var builder = std.ArrayListUnmanaged(u8).empty;
        defer builder.deinit(self.a);
        try builder.appendSlice(self.a, name);
        try builder.append(self.a, '(');
        if (std.mem.eql(u8, name, "atan2") and operands.len == 6) {
            try builder.appendSlice(self.a, try self.valueName(operands[5]));
            try builder.appendSlice(self.a, ", ");
            try builder.appendSlice(self.a, try self.valueName(operands[4]));
        } else {
            for (operands[4..], 0..) |arg, index| {
                if (index != 0) try builder.appendSlice(self.a, ", ");
                try builder.appendSlice(self.a, try self.valueName(arg));
            }
        }
        try builder.append(self.a, ')');
        return self.a.dupe(u8, builder.items);
    }

    // ------------------------------------------------------------------
    // Entry point wrapper.
    // ------------------------------------------------------------------

    fn emitEntryWrapper(
        self: *Context,
        source: *Source,
    ) TranslateError!void {
        const stage = stageFromModel(self.selected_entry.model);
        switch (stage) {
            .vertex => try self.emitVertexWrapper(source),
            .fragment => try self.emitFragmentWrapper(source),
            .compute => try self.emitComputeWrapper(source),
            else => return error.Unsupported,
        }
    }

    const InterfaceVar = struct {
        id: u32,
        type_id: u32,
        builtin: ?u32,
        location: ?u32,
        decoration: DecorationState,
    };

    fn collectInterface(
        self: *Context,
        storage: u32,
    ) TranslateError![]InterfaceVar {
        var list: std.ArrayListUnmanaged(InterfaceVar) = .empty;
        defer list.deinit(self.a);
        var id: u32 = 1;
        while (id < self.bound) : (id += 1) {
            const variable = self.variables[id] orelse continue;
            if (!variable.is_global or !self.used_globals[id]) continue;
            if (variable.storage != storage) continue;
            const pointer = self.types[variable.type_id] orelse
                continue;
            const pointee = switch (pointer) {
                .pointer => |value| value.pointee,
                else => continue,
            };
            const deco = self.decorations[id];
            if (deco.builtin == null and deco.location == null) {
                continue;
            }
            try list.append(self.a, .{
                .id = id,
                .type_id = pointee,
                .builtin = deco.builtin,
                .location = deco.location,
                .decoration = deco,
            });
        }
        // Direct3D links stages by hardware register. User varyings
        // must therefore occupy the leading registers of every stage,
        // in ascending location order, while system values such as
        // `SV_Position` go last. Otherwise the vertex output shifts
        // its varyings behind the position register and pixel shader
        // linkage fails with mismatched registers.
        var index: usize = 1;
        while (index < list.items.len) : (index += 1) {
            const item = list.items[index];
            var position = index;
            while (position > 0 and interfacePrecedes(
                item,
                list.items[position - 1],
            )) {
                list.items[position] = list.items[position - 1];
                position -= 1;
            }
            list.items[position] = item;
        }
        return list.toOwnedSlice(self.a);
    }

    fn interfacePrecedes(a: InterfaceVar, b: InterfaceVar) bool {
        const a_builtin = a.builtin != null;
        const b_builtin = b.builtin != null;
        if (a_builtin != b_builtin) return !a_builtin;
        if (a_builtin) {
            if (a.builtin.? != b.builtin.?) {
                return a.builtin.? < b.builtin.?;
            }
            return a.id < b.id;
        }
        if (a.location.? != b.location.?) {
            return a.location.? < b.location.?;
        }
        return a.id < b.id;
    }

    fn emitVertexWrapper(
        self: *Context,
        source: *Source,
    ) TranslateError!void {
        const inputs = try self.collectInterface(StorageClass.input);
        defer self.a.free(inputs);
        const outputs = try self.collectInterface(StorageClass.output);
        defer self.a.free(outputs);

        var has_position = false;
        for (outputs) |output| {
            if (output.builtin == 0) has_position = true;
        }
        if (!has_position) {
            log.warn(
                "vertex shader has no Position output",
                .{},
            );
            return error.Unsupported;
        }

        if (inputs.len != 0) {
            try source.line("struct VfrhiInput {{", .{});
            source.indent += 1;
            for (inputs) |input| {
                try source.line("{s};", .{
                    try self.interfaceDeclaration(input, .input),
                });
            }
            source.indent -= 1;
            try source.line("}};", .{});
        }
        try source.line("struct VfrhiOutput {{", .{});
        source.indent += 1;
        for (outputs) |output| {
            try source.line("{s};", .{
                try self.interfaceDeclaration(output, .output),
            });
        }
        source.indent -= 1;
        try source.line("}};", .{});

        if (inputs.len != 0) {
            try source.line("VfrhiOutput main(VfrhiInput input) {{", .{});
        } else {
            try source.line("VfrhiOutput main() {{", .{});
        }
        source.indent += 1;
        for (inputs) |input| {
            try source.line("{s} = input.{s};", .{
                try self.valueName(input.id),
                try self.interfaceFieldName(input),
            });
        }
        try source.line("vfrhi_entry_body();", .{});
        try source.line("VfrhiOutput output;", .{});
        for (outputs) |output| {
            const field = try self.interfaceFieldName(output);
            try source.line("output.{s} = {s};", .{
                field,
                try self.valueName(output.id),
            });
            // Direct3D 11 has no negative viewport heights, so flip
            // the clip-space Y here to match Vulkan's top-left
            // origin. Direct3D 12 uses the same shader and a plain
            // viewport, so both backends draw the same image.
            if (output.builtin == 0) {
                try source.line("output.{s}.y = -output.{s}.y;", .{
                    field,
                    field,
                });
            }
        }
        try source.line("return output;", .{});
        source.indent -= 1;
        try source.line("}}", .{});
        try source.line("", .{});
    }

    fn emitFragmentWrapper(
        self: *Context,
        source: *Source,
    ) TranslateError!void {
        const inputs = try self.collectInterface(StorageClass.input);
        defer self.a.free(inputs);
        const outputs = try self.collectInterface(StorageClass.output);
        defer self.a.free(outputs);

        if (outputs.len == 0) {
            log.warn("fragment shader has no outputs", .{});
            return error.Unsupported;
        }

        if (inputs.len != 0) {
            try source.line("struct VfrhiInput {{", .{});
            source.indent += 1;
            for (inputs) |input| {
                try source.line("{s};", .{
                    try self.interfaceDeclaration(input, .input),
                });
            }
            source.indent -= 1;
            try source.line("}};", .{});
        }
        try source.line("struct VfrhiOutput {{", .{});
        source.indent += 1;
        for (outputs) |output| {
            try source.line("{s};", .{
                try self.interfaceDeclaration(output, .output),
            });
        }
        source.indent -= 1;
        try source.line("}};", .{});

        if (inputs.len != 0) {
            try source.line("VfrhiOutput main(VfrhiInput input) {{", .{});
        } else {
            try source.line("VfrhiOutput main() {{", .{});
        }
        source.indent += 1;
        for (inputs) |input| {
            try source.line("{s} = input.{s};", .{
                try self.valueName(input.id),
                try self.interfaceFieldName(input),
            });
        }
        try source.line("vfrhi_entry_body();", .{});
        try source.line("VfrhiOutput output;", .{});
        for (outputs) |output| {
            try source.line("output.{s} = {s};", .{
                try self.interfaceFieldName(output),
                try self.valueName(output.id),
            });
        }
        try source.line("return output;", .{});
        source.indent -= 1;
        try source.line("}}", .{});
        try source.line("", .{});
    }

    fn emitComputeWrapper(
        self: *Context,
        source: *Source,
    ) TranslateError!void {
        const inputs = try self.collectInterface(StorageClass.input);
        defer self.a.free(inputs);

        var size: [3]u32 = .{ 1, 1, 1 };
        for (self.execution_modes.items) |mode| {
            if (mode.entry != self.selected_entry.function) continue;
            if (mode.mode == 17 and mode.literals.len >= 3) {
                size = .{
                    mode.literals[0],
                    mode.literals[1],
                    mode.literals[2],
                };
            }
        }
        try source.line(
            "[numthreads({d}, {d}, {d})]",
            .{ size[0], size[1], size[2] },
        );

        var used: [6]bool = .{ false, false, false, false, false, false };
        for (inputs) |input| {
            if (input.builtin) |builtin| {
                const slot = computeBuiltinSlot(builtin) orelse
                    return error.Unsupported;
                used[slot] = true;
            } else {
                return error.Unsupported;
            }
        }

        var params = std.ArrayListUnmanaged(u8).empty;
        defer params.deinit(self.a);
        const entries = [_]struct {
            slot: usize,
            name: []const u8,
            semantic: []const u8,
        }{
            .{ .slot = 0, .name = "vfrhi_dispatch_thread_id", .semantic = "SV_DispatchThreadID" },
            .{ .slot = 1, .name = "vfrhi_group_id", .semantic = "SV_GroupID" },
            .{ .slot = 2, .name = "vfrhi_group_thread_id", .semantic = "SV_GroupThreadID" },
            .{ .slot = 3, .name = "vfrhi_group_index", .semantic = "SV_GroupIndex" },
            .{ .slot = 4, .name = "vfrhi_primitive_id", .semantic = "SV_PrimitiveID" },
            .{ .slot = 5, .name = "vfrhi_dispatch_rays", .semantic = "SV_DispatchThreadID" },
        };
        var first = true;
        for (entries) |entry| {
            if (!used[entry.slot]) continue;
            if (!first) try params.appendSlice(self.a, ", ");
            first = false;
            try params.appendSlice(self.a, try self.fmt(
                "{s} {s} : {s}",
                .{
                    if (entry.slot == 3) "uint" else "uint3",
                    entry.name,
                    entry.semantic,
                },
            ));
        }
        try source.line("void main({s}) {{", .{params.items});
        source.indent += 1;
        for (inputs) |input| {
            const slot = computeBuiltinSlot(input.builtin.?) orelse
                return error.Unsupported;
            try source.line("{s} = {s};", .{
                try self.valueName(input.id),
                entries[slot].name,
            });
        }
        try source.line("vfrhi_entry_body();", .{});
        source.indent -= 1;
        try source.line("}}", .{});
        try source.line("", .{});
    }

    fn interfaceDeclaration(
        self: *Context,
        variable: InterfaceVar,
        direction: Direction,
    ) TranslateError![]const u8 {
        const stage = stageFromModel(self.selected_entry.model);
        const type_name = try self.typeName(variable.type_id);
        const field = try self.interfaceFieldName(variable);
        if (variable.builtin) |builtin| {
            const semantic = try hlslBuiltinSemantic(
                builtin,
                stage,
                direction,
            );
            var builder = std.ArrayListUnmanaged(u8).empty;
            defer builder.deinit(self.a);
            try builder.appendSlice(self.a, type_name);
            try builder.append(self.a, ' ');
            try builder.appendSlice(self.a, field);
            try builder.appendSlice(self.a, " : ");
            try builder.appendSlice(self.a, semantic);
            return self.a.dupe(u8, builder.items);
        }
        const location = variable.location orelse
            return error.Unsupported;
        var builder = std.ArrayListUnmanaged(u8).empty;
        defer builder.deinit(self.a);
        if (direction == .input) {
            if (variable.decoration.flat) {
                try builder.appendSlice(self.a, "nointerpolation ");
            }
            if (variable.decoration.no_perspective) {
                try builder.appendSlice(self.a, "noperspective ");
            }
            if (variable.decoration.centroid) {
                try builder.appendSlice(self.a, "centroid ");
            }
            if (variable.decoration.sample) {
                try builder.appendSlice(self.a, "sample ");
            }
        }
        try builder.appendSlice(self.a, type_name);
        try builder.append(self.a, ' ');
        try builder.appendSlice(self.a, field);
        try builder.appendSlice(self.a, " : ");
        if (direction == .output and stage == .fragment) {
            try builder.appendSlice(
                self.a,
                try self.fmt("SV_Target{d}", .{location}),
            );
        } else {
            try builder.appendSlice(
                self.a,
                try self.fmt("LOCATION{d}", .{location}),
            );
        }
        return self.a.dupe(u8, builder.items);
    }

    fn interfaceFieldName(
        self: *Context,
        variable: InterfaceVar,
    ) TranslateError![]const u8 {
        if (variable.builtin) |builtin| {
            return self.fmt("vfrhi_builtin_{d}", .{builtin});
        }
        const location = variable.location orelse
            return error.Unsupported;
        return self.fmt("vfrhi_in_{d}", .{location});
    }

    // ------------------------------------------------------------------
    // Names, types and constants.
    // ------------------------------------------------------------------

    fn isPointerValue(self: *Context, id: u32) bool {
        if (id >= self.bound) return false;
        const type_id = self.ids[id].type_id;
        const type_kind = self.types[type_id] orelse return false;
        return switch (type_kind) {
            .pointer => true,
            else => false,
        };
    }

    fn lvalue(
        self: *Context,
        id: u32,
    ) TranslateError![]const u8 {
        const inst = self.inst_by_id[id];
        if (inst) |value| {
            if (value.opcode == 65 or value.opcode == 66 or
                value.opcode == 67 or value.opcode == 70)
            {
                return self.accessChain(value);
            }
        }
        if (id < self.bound and self.variables[id] != null) {
            return self.valueName(id);
        }
        if (id < self.bound and self.ids[id].kind == .function_parameter) {
            return self.valueName(id);
        }
        return error.Unsupported;
    }

    fn accessChain(
        self: *Context,
        inst: Inst,
    ) TranslateError![]const u8 {
        const operands = inst.operands;
        if (operands.len < 3) return error.InvalidSpirv;
        var builder = std.ArrayListUnmanaged(u8).empty;
        defer builder.deinit(self.a);
        try builder.appendSlice(self.a, try self.lvalue(operands[2]));

        const base_type_id = self.ids[operands[2]].type_id;
        const pointer = switch (self.types[base_type_id] orelse
            return error.InvalidSpirv) {
            .pointer => |value| value,
            else => return error.InvalidSpirv,
        };
        var current_type = pointer.pointee;
        for (operands[3..]) |index_id| {
            const type_kind = self.types[current_type] orelse
                return error.InvalidSpirv;
            switch (type_kind) {
                .struct_ => {
                    const index = try self.constantU32(index_id);
                    if (index >= type_kind.struct_.members.len) {
                        return error.InvalidSpirv;
                    }
                    try builder.appendSlice(
                        self.a,
                        try self.fmt(".m{d}", .{index}),
                    );
                    current_type = type_kind.struct_.members[index];
                },
                .array => |value| {
                    try builder.appendSlice(
                        self.a,
                        try self.fmt("[{s}]", .{
                            try self.valueName(index_id),
                        }),
                    );
                    current_type = value.element;
                },
                .runtime_array => |element| {
                    try builder.appendSlice(
                        self.a,
                        try self.fmt("[{s}]", .{
                            try self.valueName(index_id),
                        }),
                    );
                    current_type = element;
                },
                .vector => |value| {
                    try builder.appendSlice(
                        self.a,
                        try self.fmt("[{s}]", .{
                            try self.valueName(index_id),
                        }),
                    );
                    current_type = value.component;
                },
                .matrix => |value| {
                    try builder.appendSlice(
                        self.a,
                        try self.fmt("[{s}]", .{
                            try self.valueName(index_id),
                        }),
                    );
                    current_type = value.column;
                },
                else => return error.Unsupported,
            }
        }
        return self.a.dupe(u8, builder.items);
    }

    fn valueName(
        self: *Context,
        id: u32,
    ) TranslateError![]const u8 {
        if (id >= self.bound) return error.InvalidSpirv;
        if (self.opaque_values[id]) |value| {
            return value.texture;
        }
        if (self.constants[id]) |constant| {
            return self.constantExprFor(id, constant);
        }
        if (self.ids[id].kind == .function_parameter) {
            const type_id = self.ids[id].type_id;
            const effective = self.pointeeOf(type_id) orelse type_id;
            if (self.types[effective]) |kind| {
                switch (kind) {
                    .sampled_image, .image => {
                        return self.textureParamName(id);
                    },
                    .sampler => return self.samplerParamName(id),
                    else => {},
                }
            }
            return self.fmt("vfrhi_p_{d}", .{id});
        }
        if (self.ids[id].kind == .variable) {
            return self.variableName(id);
        }
        if (self.ids[id].kind == .value) {
            if (self.inst_by_id[id]) |inst| {
                if (inst.opcode == 1) {
                    return self.nullExpr(inst.operands[0]);
                }
            }
            return self.fmt("vfrhi_v_{d}", .{id});
        }
        if (self.ids[id].kind == .function) {
            return self.fmt("vfrhi_fn_{d}", .{id});
        }
        return error.InvalidSpirv;
    }

    fn variableName(
        self: *Context,
        id: u32,
    ) TranslateError![]const u8 {
        const variable = self.variables[id] orelse
            return error.InvalidSpirv;
        if (variable.storage == StorageClass.uniform_constant) {
            const info = try self.interfaceBinding(id);
            return self.fmt(
                "vfrhi_res_{d}_{d}",
                .{ info.set, info.binding },
            );
        }
        if (variable.storage == StorageClass.push_constant) {
            return self.fmt("vfrhi_push_{d}", .{id});
        }
        return self.fmt("vfrhi_v_{d}", .{id});
    }

    fn textureName(
        self: *Context,
        set: u32,
        binding: u32,
    ) TranslateError![]const u8 {
        return self.fmt("vfrhi_tex_s{d}_b{d}", .{ set, binding });
    }

    fn samplerName(
        self: *Context,
        set: u32,
        binding: u32,
    ) TranslateError![]const u8 {
        return self.fmt("vfrhi_smp_s{d}_b{d}", .{ set, binding });
    }

    fn textureParamName(
        self: *Context,
        id: u32,
    ) TranslateError![]const u8 {
        return self.fmt("vfrhi_tex_p_{d}", .{id});
    }

    fn samplerParamName(
        self: *Context,
        id: u32,
    ) TranslateError![]const u8 {
        return self.fmt("vfrhi_smp_p_{d}", .{id});
    }

    fn opaqueForPointer(
        self: *Context,
        pointer_id: u32,
    ) TranslateError!OpaqueValue {
        if (pointer_id < self.bound and self.variables[pointer_id] != null) {
            return self.opaqueForVariable(pointer_id);
        }
        if (pointer_id < self.bound and
            self.ids[pointer_id].kind == .function_parameter)
        {
            const type_id = self.ids[pointer_id].type_id;
            return self.opaqueForType(type_id, pointer_id);
        }
        if (pointer_id < self.bound and self.ids[pointer_id].kind == .value) {
            if (self.opaque_values[pointer_id]) |value| return value;
        }
        const inst = self.inst_by_id[pointer_id];
        if (inst) |value| {
            if (value.opcode == 65 or value.opcode == 66 or
                value.opcode == 67)
            {
                return self.opaqueForPointer(value.operands[2]);
            }
        }
        return error.Unsupported;
    }

    fn opaqueForVariable(
        self: *Context,
        id: u32,
    ) TranslateError!OpaqueValue {
        const variable = self.variables[id] orelse
            return error.InvalidSpirv;
        const pointer = self.types[variable.type_id] orelse
            return error.InvalidSpirv;
        const pointee = switch (pointer) {
            .pointer => |value| value.pointee,
            else => return error.InvalidSpirv,
        };
        const deco = self.decorations[id];
        const binding = deco.binding orelse return error.Unsupported;
        const set = deco.descriptor_set orelse 0;
        const kind = self.types[pointee] orelse
            return error.InvalidSpirv;
        return switch (kind) {
            .sampled_image => .{
                .kind = .combined,
                .texture = try self.textureName(set, binding),
                .sampler = try self.samplerName(set, binding),
            },
            .image => .{
                .kind = .texture,
                .texture = try self.textureName(set, binding),
            },
            .sampler => .{
                .kind = .sampler,
                .texture = try self.samplerName(set, binding),
            },
            else => error.Unsupported,
        };
    }

    fn opaqueForType(
        self: *Context,
        type_id: u32,
        id: u32,
    ) TranslateError!OpaqueValue {
        const effective = self.pointeeOf(type_id) orelse type_id;
        const kind = self.types[effective] orelse
            return error.InvalidSpirv;
        return switch (kind) {
            .sampled_image => .{
                .kind = .combined,
                .texture = try self.textureParamName(id),
                .sampler = try self.samplerParamName(id),
            },
            .image => .{
                .kind = .texture,
                .texture = try self.textureParamName(id),
            },
            .sampler => .{
                .kind = .sampler,
                .texture = try self.samplerParamName(id),
            },
            else => error.Unsupported,
        };
    }

    fn textureOf(
        self: *Context,
        id: u32,
    ) TranslateError![]const u8 {
        if (id < self.bound) {
            if (self.opaque_values[id]) |value| {
                return value.texture;
            }
            if (self.ids[id].kind == .function_parameter) {
                return (try self.opaqueForType(
                    self.ids[id].type_id,
                    id,
                )).texture;
            }
            if (self.variables[id] != null) {
                const value = try self.opaqueForVariable(id);
                return value.texture;
            }
        }
        return self.valueName(id);
    }

    fn samplerOf(
        self: *Context,
        id: u32,
    ) TranslateError![]const u8 {
        if (id < self.bound) {
            if (self.opaque_values[id]) |value| {
                if (value.sampler) |sampler| return sampler;
            }
            if (self.ids[id].kind == .function_parameter) {
                const value = try self.opaqueForType(
                    self.ids[id].type_id,
                    id,
                );
                if (value.sampler) |sampler| return sampler;
            }
            if (self.variables[id] != null) {
                const value = try self.opaqueForVariable(id);
                if (value.sampler) |sampler| return sampler;
            }
        }
        return error.Unsupported;
    }

    fn imageOf(
        self: *Context,
        id: u32,
    ) ?ImageType {
        if (id >= self.bound) return null;
        var type_id = self.ids[id].type_id;
        if (self.types[type_id]) |kind| {
            switch (kind) {
                .pointer => |pointer| type_id = pointer.pointee,
                else => {},
            }
        }
        return self.imageTypeOf(type_id);
    }

    fn constantExprFor(
        self: *Context,
        id: u32,
        constant: Constant,
    ) TranslateError![]const u8 {
        switch (constant.kind) {
            .bool_value => return if (constant.bool_value) "true" else "false",
            .scalar => return self.scalarConstant(constant),
            .composite => return self.constantComposite(id),
            .null_value => return self.nullExpr(constant.type_id),
            .unsupported => return error.Unsupported,
        }
    }

    fn constantExpr(
        self: *Context,
        id: u32,
    ) TranslateError![]const u8 {
        const constant = self.constants[id] orelse
            return error.InvalidSpirv;
        return self.constantExprFor(id, constant);
    }

    fn constantComposite(
        self: *Context,
        id: u32,
    ) TranslateError![]const u8 {
        const constant = self.constants[id] orelse
            return error.InvalidSpirv;
        return self.constructor(constant.type_id, constant.constituents);
    }

    fn scalarConstant(
        self: *Context,
        constant: Constant,
    ) TranslateError![]const u8 {
        const type_kind = self.types[constant.type_id] orelse
            return error.InvalidSpirv;
        switch (type_kind) {
            .int => |value| {
                if (value.width > 32) return error.Unsupported;
                if (value.signed) {
                    const signed: i32 = @bitCast(constant.words[0]);
                    return self.fmt("{d}", .{signed});
                }
                return self.fmt("{d}u", .{constant.words[0]});
            },
            .float => |value| {
                if (value.width == 16) return error.Unsupported;
                if (value.width == 32) {
                    const float: f32 = @bitCast(constant.words[0]);
                    if (std.math.isNan(float) or
                        std.math.isInf(float))
                    {
                        return self.fmt(
                            "asfloat(0x{x}u)",
                            .{constant.words[0]},
                        );
                    }
                    const text = try self.fmt("{d}", .{float});
                    if (std.mem.indexOfAny(u8, text, ".eE") == null) {
                        return self.fmt("{s}.0", .{text});
                    }
                    return text;
                }
                return error.Unsupported;
            },
            else => return error.Unsupported,
        }
    }

    fn nullExpr(
        self: *Context,
        type_id: u32,
    ) TranslateError![]const u8 {
        const type_kind = self.types[type_id] orelse
            return error.InvalidSpirv;
        switch (type_kind) {
            .bool => return "false",
            .int => |value| return if (value.signed) "0" else "0u",
            .float => return "0.0",
            .vector => {
                return self.fmt("({s})0", .{
                    try self.typeName(type_id),
                });
            },
            .matrix => {
                return self.fmt("({s})0", .{
                    try self.typeName(type_id),
                });
            },
            .array => |value| {
                var builder = std.ArrayListUnmanaged(u8).empty;
                defer builder.deinit(self.a);
                try builder.append(self.a, '{');
                const length = try self.constantU32(value.length);
                var index: u32 = 0;
                while (index < length) : (index += 1) {
                    if (index != 0) try builder.appendSlice(self.a, ", ");
                    try builder.appendSlice(
                        self.a,
                        try self.nullExpr(value.element),
                    );
                }
                try builder.append(self.a, '}');
                return self.a.dupe(u8, builder.items);
            },
            .runtime_array => return error.Unsupported,
            .struct_ => |info| {
                var builder = std.ArrayListUnmanaged(u8).empty;
                defer builder.deinit(self.a);
                try builder.append(self.a, '{');
                for (info.members, 0..) |member, index| {
                    if (index != 0) try builder.appendSlice(self.a, ", ");
                    try builder.appendSlice(
                        self.a,
                        try self.nullExpr(member),
                    );
                }
                try builder.append(self.a, '}');
                return self.a.dupe(u8, builder.items);
            },
            else => return error.Unsupported,
        }
    }

    fn imageTextureType(
        self: *Context,
        image_type_id: u32,
    ) TranslateError![]const u8 {
        const type_kind = self.types[image_type_id] orelse
            return error.InvalidSpirv;
        const image = switch (type_kind) {
            .image => |value| value,
            .sampled_image => |image_type| return self.imageTextureType(
                image_type,
            ),
            else => return error.InvalidSpirv,
        };
        const sampled = self.types[image.sampled_type] orelse
            return error.InvalidSpirv;
        const component = switch (sampled) {
            .float => "float",
            .int => |value| if (value.signed) "int" else "uint",
            else => return error.Unsupported,
        };
        var base: []const u8 = switch (image.dim) {
            0 => "Texture1D",
            1 => if (image.ms) "Texture2DMS" else "Texture2D",
            2 => "Texture3D",
            3 => "TextureCube",
            else => return error.Unsupported,
        };
        if (image.arrayed) {
            base = try self.fmt("{s}Array", .{base});
        }
        const value_type = if (image.depth != 0)
            try self.fmt("{s}", .{component})
        else
            try self.fmt("{s}4", .{component});
        return self.fmt("{s}<{s}>", .{ base, value_type });
    }

    fn declaration(
        self: *Context,
        type_id: u32,
        name: []const u8,
    ) TranslateError![]const u8 {
        const type_kind = self.types[type_id] orelse
            return error.InvalidSpirv;
        switch (type_kind) {
            .array => |value| {
                const suffix = try self.fmt("[{d}]", .{
                    try self.constantU32(value.length),
                });
                const inner = try self.fmt("{s}{s}", .{ name, suffix });
                return self.declaration(value.element, inner);
            },
            .runtime_array => |element| {
                const inner = try self.fmt("{s}[]", .{name});
                return self.declaration(element, inner);
            },
            else => {
                const type_name = try self.typeName(type_id);
                if (name.len == 0) return type_name;
                return self.fmt("{s} {s}", .{ type_name, name });
            },
        }
    }

    fn typeName(
        self: *Context,
        type_id: u32,
    ) TranslateError![]const u8 {
        const type_kind = self.types[type_id] orelse
            return error.InvalidSpirv;
        return switch (type_kind) {
            .void => "void",
            .bool => "bool",
            .int => |value| blk: {
                if (value.width > 32) return error.Unsupported;
                break :blk if (value.signed) "int" else "uint";
            },
            .float => |value| blk: {
                break :blk switch (value.width) {
                    32 => "float",
                    64 => "double",
                    else => return error.Unsupported,
                };
            },
            .vector => |value| blk: {
                const component = try self.scalarName(value.component);
                break :blk self.fmt("{s}{d}", .{
                    component,
                    value.count,
                });
            },
            .matrix => |value| blk: {
                const column = self.types[value.column] orelse
                    return error.InvalidSpirv;
                const vector = switch (column) {
                    .vector => |info| info,
                    else => return error.InvalidSpirv,
                };
                const component = try self.scalarName(vector.component);
                break :blk self.fmt("{s}{d}x{d}", .{
                    component,
                    vector.count,
                    value.count,
                });
            },
            .image, .sampled_image => self.imageTextureType(type_id),
            .sampler => "SamplerState",
            .array => |value| blk: {
                break :blk self.fmt("{s}[{d}]", .{
                    try self.typeName(value.element),
                    try self.constantU32(value.length),
                });
            },
            .runtime_array => |element| blk: {
                break :blk self.fmt("{s}[]", .{
                    try self.typeName(element),
                });
            },
            .struct_ => self.structName(type_id),
            .pointer => |value| self.typeName(value.pointee),
            .function => "void",
            .opaque_type => return error.Unsupported,
        };
    }

    fn scalarName(
        self: *Context,
        type_id: u32,
    ) TranslateError![]const u8 {
        const type_kind = self.types[type_id] orelse
            return error.InvalidSpirv;
        return switch (type_kind) {
            .bool => "bool",
            .int => |value| if (value.signed) "int" else "uint",
            .float => |value| if (value.width == 64) "double" else "float",
            else => return error.InvalidSpirv,
        };
    }

    fn structName(
        self: *Context,
        id: u32,
    ) TranslateError![]const u8 {
        return self.fmt("vfrhi_struct_{d}", .{id});
    }

    fn interfaceBinding(
        self: *Context,
        id: u32,
    ) TranslateError!struct { set: u32, binding: u32 } {
        const deco = self.decorations[id];
        const binding = deco.binding orelse {
            log.warn(
                "descriptor variable {d} has no binding decoration",
                .{id},
            );
            return error.Unsupported;
        };
        return .{
            .set = deco.descriptor_set orelse 0,
            .binding = binding,
        };
    }

    fn resourceRegister(
        self: *Context,
        set: u32,
        binding: u32,
    ) TranslateError!u32 {
        return switch (self.backend) {
            .d3d12 => binding,
            .d3d11 => set * 16 + binding,
        };
    }

    fn spaceSuffix(
        self: *Context,
        set: u32,
    ) TranslateError![]const u8 {
        return switch (self.backend) {
            .d3d12 => self.fmt(", space{d}", .{set}),
            .d3d11 => "",
        };
    }

    fn pushRegisterSuffix(
        self: *Context,
    ) TranslateError![]const u8 {
        return switch (self.backend) {
            .d3d12 => ", space15",
            .d3d11 => "",
        };
    }

    fn isBlock(self: *Context, type_id: u32) bool {
        const type_kind = self.types[type_id] orelse return false;
        switch (type_kind) {
            .struct_ => {},
            else => return false,
        }
        const deco = self.decorations[type_id];
        return deco.block or deco.buffer_block;
    }

    fn memberDecoration(
        self: *Context,
        struct_id: u32,
        member: u32,
    ) DecorationState {
        var result: DecorationState = .{};
        for (self.member_decorations.items) |decoration| {
            if (decoration.struct_id != struct_id) continue;
            if (decoration.member != member) continue;
            mergeDecoration(&result, decoration.state);
        }
        return result;
    }

    fn isOpaque(self: *Context, type_id: u32) bool {
        const type_kind = self.types[type_id] orelse return false;
        return switch (type_kind) {
            .image, .sampler, .sampled_image => true,
            .array => |value| self.isOpaque(value.element),
            .runtime_array => |element| self.isOpaque(element),
            else => false,
        };
    }

    fn imageTypeOf(
        self: *Context,
        type_id: u32,
    ) ?ImageType {
        const type_kind = self.types[type_id] orelse return null;
        return switch (type_kind) {
            .image => |value| value,
            .sampled_image => |image_type| self.imageTypeOf(image_type),
            .array => |value| self.imageTypeOf(value.element),
            else => null,
        };
    }

    fn constantU32(
        self: *Context,
        id: u32,
    ) TranslateError!u32 {
        const constant = self.constants[id] orelse
            return error.InvalidSpirv;
        if (constant.kind != .scalar) return error.InvalidSpirv;
        return constant.words[0];
    }

    fn voidTypeId(self: *Context) TranslateError!u32 {
        var id: u32 = 1;
        while (id < self.bound) : (id += 1) {
            if (self.types[id]) |value| {
                switch (value) {
                    .void => return id,
                    else => {},
                }
            }
        }
        return error.InvalidSpirv;
    }

    fn fmt(
        self: *Context,
        comptime format: []const u8,
        args: anytype,
    ) TranslateError![]const u8 {
        return std.fmt.allocPrint(self.a, format, args);
    }

    fn decodeString(
        self: *Context,
        words: []const u32,
    ) TranslateError!struct { text: []const u8, word_count: usize } {
        var bytes = std.ArrayListUnmanaged(u8).empty;
        defer bytes.deinit(self.a);
        for (words, 0..) |word, word_index| {
            var byte_index: u5 = 0;
            while (byte_index < 4) : (byte_index += 1) {
                const byte: u8 = @truncate(
                    word >> @intCast(byte_index * 8),
                );
                if (byte == 0) {
                    return .{
                        .text = try bytes.toOwnedSlice(self.a),
                        .word_count = word_index + 1,
                    };
                }
                try bytes.append(self.a, byte);
            }
        }
        return error.InvalidSpirv;
    }
};

const Direction = enum { input, output };

fn hlslBuiltinSemantic(
    builtin: u32,
    stage: types.ShaderStage,
    direction: Direction,
) TranslateError![]const u8 {
    return switch (builtin) {
        0 => "SV_Position",
        5 => if (stage == .vertex and direction == .input)
            "SV_VertexID"
        else
            error.Unsupported,
        6 => if (stage == .vertex and direction == .input)
            "SV_InstanceID"
        else
            error.Unsupported,
        7 => if (direction == .input)
            "SV_PrimitiveID"
        else
            error.Unsupported,
        15 => if (stage == .fragment and direction == .input)
            "SV_Position"
        else
            error.Unsupported,
        17 => if (stage == .fragment and direction == .input)
            "SV_IsFrontFace"
        else
            error.Unsupported,
        18 => if (stage == .fragment and direction == .input)
            "SV_SampleIndex"
        else
            error.Unsupported,
        20 => if (stage == .fragment and direction == .output)
            "SV_Coverage"
        else
            error.Unsupported,
        22 => if (stage == .fragment and direction == .output)
            "SV_Depth"
        else
            error.Unsupported,
        28 => if (stage == .compute and direction == .input)
            "SV_DispatchThreadID"
        else
            error.Unsupported,
        else => error.Unsupported,
    };
}

fn computeBuiltinSlot(builtin: u32) ?usize {
    return switch (builtin) {
        28 => 0,
        26 => 1,
        27 => 2,
        29 => 3,
        7 => 4,
        else => null,
    };
}

fn hlslExtInstName(instruction: u32) ?[]const u8 {
    return switch (instruction) {
        1 => "round",
        2 => "round",
        3 => "trunc",
        4 => "abs",
        5 => "abs",
        6 => "sign",
        7 => "sign",
        8 => "floor",
        9 => "ceil",
        10 => "frac",
        11 => "radians",
        12 => "degrees",
        13 => "sin",
        14 => "cos",
        15 => "tan",
        16 => "asin",
        17 => "acos",
        18 => "atan2",
        19 => "sinh",
        20 => "cosh",
        21 => "tanh",
        22 => "asinh",
        23 => "acosh",
        24 => "atanh",
        25 => "atan2",
        26 => "pow",
        27 => "exp",
        28 => "log",
        29 => "exp2",
        30 => "log2",
        31 => "sqrt",
        32 => "rsqrt",
        33 => "determinant",
        34 => null,
        37, 38, 39 => "min",
        40, 41, 42 => "max",
        43, 44, 45 => "clamp",
        46 => "lerp",
        48 => "step",
        49 => "smoothstep",
        50 => "mad",
        53 => "ldexp",
        54, 55, 56, 57, 58 => null,
        60, 61, 62, 63, 64 => null,
        66 => "length",
        67 => "distance",
        68 => "cross",
        69 => "normalize",
        70 => "faceforward",
        71 => "reflect",
        72 => "refract",
        73 => "firstbitlow",
        74, 75 => "firstbithigh",
        76 => "EvaluateAttributeCentroid",
        77 => "EvaluateAttributeAtSample",
        78 => "EvaluateAttributeSnapped",
        79 => "min",
        80 => "max",
        81 => "clamp",
        else => null,
    };
}

fn applyDecoration(
    state: *DecorationState,
    decoration: u32,
    operands: []const u32,
) void {
    switch (decoration) {
        2 => state.block = true,
        3 => state.buffer_block = true,
        4 => state.row_major = true,
        6 => if (operands.len >= 1) {
            state.array_stride = operands[0];
        },
        7 => if (operands.len >= 1) {
            state.matrix_stride = operands[0];
        },
        11 => if (operands.len >= 1) {
            state.builtin = operands[0];
        },
        13 => state.no_perspective = true,
        14 => state.flat = true,
        16 => state.centroid = true,
        17 => state.sample = true,
        18 => state.invariant = true,
        30 => if (operands.len >= 1) {
            state.location = operands[0];
        },
        33 => if (operands.len >= 1) {
            state.binding = operands[0];
        },
        34 => if (operands.len >= 1) {
            state.descriptor_set = operands[0];
        },
        35 => if (operands.len >= 1) {
            state.offset = operands[0];
        },
        else => {},
    }
}

fn mergeDecoration(
    destination: *DecorationState,
    source: DecorationState,
) void {
    if (source.builtin) |value| destination.builtin = value;
    if (source.location) |value| destination.location = value;
    if (source.binding) |value| destination.binding = value;
    if (source.descriptor_set) |value| destination.descriptor_set = value;
    if (source.array_stride) |value| destination.array_stride = value;
    if (source.matrix_stride) |value| destination.matrix_stride = value;
    if (source.offset) |value| destination.offset = value;
    destination.block = destination.block or source.block;
    destination.buffer_block =
        destination.buffer_block or source.buffer_block;
    destination.row_major = destination.row_major or source.row_major;
    destination.flat = destination.flat or source.flat;
    destination.no_perspective =
        destination.no_perspective or source.no_perspective;
    destination.centroid = destination.centroid or source.centroid;
    destination.sample = destination.sample or source.sample;
    destination.invariant = destination.invariant or source.invariant;
}

const ScalarClass = enum {
    other,
    float,
    signed,
    unsigned,
};

fn scalarClass(context: *Context, type_id: u32) ScalarClass {
    const type_kind = context.types[type_id] orelse return .other;
    return switch (type_kind) {
        .float => .float,
        .int => |value| if (value.signed) .signed else .unsigned,
        .vector => |value| scalarClass(context, value.component),
        else => .other,
    };
}

fn hasResult(opcode: u16) bool {
    return switch (opcode) {
        1,
        12,
        57,
        60,
        61,
        65,
        66,
        67,
        68,
        70,
        77,
        78,
        79,
        80,
        81,
        82,
        83,
        84,
        86,
        87,
        88,
        89,
        90,
        91,
        92,
        93,
        94,
        95,
        96,
        97,
        98,
        100,
        103,
        104,
        105,
        106,
        107,
        109,
        110,
        111,
        112,
        113,
        114,
        115,
        116,
        117,
        118,
        119,
        120,
        121,
        122,
        123,
        124,
        126,
        127,
        128,
        129,
        130,
        131,
        132,
        133,
        134,
        135,
        136,
        137,
        138,
        139,
        140,
        141,
        142,
        143,
        144,
        145,
        146,
        147,
        148,
        149,
        150,
        151,
        152,
        154,
        155,
        156,
        157,
        158,
        159,
        160,
        161,
        162,
        163,
        164,
        165,
        166,
        167,
        168,
        169,
        170,
        171,
        172,
        173,
        174,
        175,
        176,
        177,
        178,
        179,
        180,
        181,
        182,
        183,
        184,
        185,
        186,
        187,
        188,
        189,
        190,
        191,
        194,
        195,
        196,
        197,
        198,
        199,
        200,
        201,
        202,
        203,
        204,
        205,
        207,
        208,
        209,
        210,
        211,
        212,
        213,
        214,
        215,
        227,
        229,
        230,
        231,
        232,
        233,
        234,
        235,
        236,
        237,
        238,
        239,
        240,
        241,
        242,
        245,
        => true,
        else => false,
    };
}

fn stageFromModel(model: u32) types.ShaderStage {
    return switch (model) {
        ExecutionModel.vertex => .vertex,
        ExecutionModel.tessellation_control => .tessellation_control,
        ExecutionModel.tessellation_evaluation => .tessellation_evaluation,
        ExecutionModel.geometry => .geometry,
        ExecutionModel.fragment => .fragment,
        ExecutionModel.gl_compute => .compute,
        else => .vertex,
    };
}

fn builtinName(
    builtin: u32,
    stage: types.ShaderStage,
    storage: u32,
) TranslateError![]const u8 {
    return switch (builtin) {
        0 => "gl_Position",
        1 => "gl_PointSize",
        3 => "gl_ClipDistance",
        4 => "gl_CullDistance",
        5 => "gl_VertexID",
        6 => "gl_InstanceID",
        7 => "gl_PrimitiveID",
        8 => "gl_InvocationID",
        9 => "gl_Layer",
        10 => "gl_ViewportIndex",
        11 => "gl_TessLevelOuter",
        12 => "gl_TessLevelInner",
        13 => "gl_TessCoord",
        14 => "gl_PatchVerticesIn",
        15 => "gl_FragCoord",
        16 => "gl_PointCoord",
        17 => "gl_FrontFacing",
        18 => "gl_SampleID",
        19 => "gl_SamplePosition",
        20 => "gl_SampleMask",
        22 => "gl_FragDepth",
        23 => "gl_HelperInvocation",
        24 => "gl_NumWorkGroups",
        25 => "gl_WorkGroupSize",
        26 => "gl_WorkGroupID",
        27 => "gl_LocalInvocationID",
        28 => "gl_GlobalInvocationID",
        29 => "gl_LocalInvocationIndex",
        36 => "gl_SubgroupSize",
        37 => "gl_SubgroupInvocationID",
        else => {
            _ = stage;
            _ = storage;
            return error.Unsupported;
        },
    };
}

fn imageFormatQualifier(format: u32) TranslateError![]const u8 {
    return switch (format) {
        1 => "rgba32f",
        2 => "rgba16f",
        3 => "r32f",
        4 => "rgba8",
        5 => "rgba8_snorm",
        6 => "rg32f",
        7 => "rg16f",
        8 => "r11f_g11f_b10f",
        9 => "r16f",
        10 => "rgba16",
        11 => "rgb10_a2",
        12 => "rg16",
        13 => "rg8",
        14 => "r16",
        15 => "r8",
        16 => "rgba16_snorm",
        17 => "rg16_snorm",
        18 => "rg8_snorm",
        19 => "r16_snorm",
        20 => "r8_snorm",
        21 => "rgba32i",
        22 => "rgba16i",
        23 => "rgba8i",
        24 => "r32i",
        25 => "rg32i",
        26 => "rg16i",
        27 => "rg8i",
        28 => "r16i",
        29 => "r8i",
        30 => "rgba32ui",
        31 => "rgba16ui",
        32 => "rgba8ui",
        33 => "r32ui",
        34 => "rg32ui",
        35 => "rg16ui",
        36 => "rg8ui",
        37 => "r16ui",
        38 => "r8ui",
        else => error.Unsupported,
    };
}

fn glslStd450Name(instruction: u32) ?[]const u8 {
    return switch (instruction) {
        1 => "round",
        2 => "roundEven",
        3 => "trunc",
        4 => "abs",
        5 => "abs",
        6 => "sign",
        7 => "sign",
        8 => "floor",
        9 => "ceil",
        10 => "fract",
        11 => "radians",
        12 => "degrees",
        13 => "sin",
        14 => "cos",
        15 => "tan",
        16 => "asin",
        17 => "acos",
        18 => "atan",
        19 => "sinh",
        20 => "cosh",
        21 => "tanh",
        22 => "asinh",
        23 => "acosh",
        24 => "atanh",
        25 => "atan",
        26 => "pow",
        27 => "exp",
        28 => "log",
        29 => "exp2",
        30 => "log2",
        31 => "sqrt",
        32 => "inversesqrt",
        33 => "determinant",
        34 => "inverse",
        37 => "min",
        38 => "min",
        39 => "min",
        40 => "max",
        41 => "max",
        42 => "max",
        43 => "clamp",
        44 => "clamp",
        45 => "clamp",
        46 => "mix",
        48 => "step",
        49 => "smoothstep",
        50 => "fma",
        53 => "ldexp",
        54 => "packSnorm4x8",
        55 => "packUnorm4x8",
        56 => "packSnorm2x16",
        57 => "packUnorm2x16",
        58 => "packHalf2x16",
        60 => "unpackSnorm2x16",
        61 => "unpackUnorm2x16",
        62 => "unpackHalf2x16",
        63 => "unpackSnorm4x8",
        64 => "unpackUnorm4x8",
        66 => "length",
        67 => "distance",
        68 => "cross",
        69 => "normalize",
        70 => "faceforward",
        71 => "reflect",
        72 => "refract",
        73 => "findLSB",
        74 => "findMSB",
        75 => "findMSB",
        76 => "interpolateAtCentroid",
        77 => "interpolateAtSample",
        78 => "interpolateAtOffset",
        79 => "min",
        80 => "max",
        81 => "clamp",
        else => null,
    };
}
