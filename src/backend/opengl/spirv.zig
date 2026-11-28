//! A focused SPIR-V to GLSL translator used by the OpenGL backend.
//!
//! Core OpenGL has no portable SPIR-V entry point, so the backend
//! decompiles the module into GLSL 4.50 source before handing it to
//! the driver. The translator covers the subset of SPIR-V emitted by
//! `glslangValidator -V` / `glslc -fshader-stage=...` for the shader
//! stages vfrhi supports.
//!
//! The generated control flow is a small state machine. Every basic
//! block becomes a `case` of a `switch` inside a `while (true)` loop,
//! which keeps the decompiler independent of structured control flow
//! reconstruction. The result is not pretty, but it is valid GLSL.
//!
//! Unsupported features include 16-bit arithmetic, 64-bit integers,
//! descriptor indexing, physical storage buffers, ray tracing and mesh
//! shader stages, and SPIR-V extensions outside `GLSL.std.450`.
//! Uniform and push constant blocks are emitted with `std140` layout;
//! modules that rely on `std430` array or matrix strides inside those
//! blocks may decompile with different padding. Encountering an
//! unsupported feature returns `error.Unsupported` instead of emitting
//! incorrect GLSL.
const std = @import("std");
const rhi = @import("rhi");
const types = rhi.types;
const Allocator = std.mem.Allocator;
const log = std.log.scoped(.opengl);

/// Errors produced while parsing or decompiling SPIR-V.
pub const TranslateError = error{
    InvalidSpirv,
    Unsupported,
} || Allocator.Error;

/// A translated shader module.
pub const Translated = struct {
    source: []u8,
    allocator: Allocator,

    /// Frees the translated source.
    pub fn deinit(self: Translated) void {
        self.allocator.free(self.source);
    }
};

/// Translates one entry point of a SPIR-V module into GLSL.
///
/// # Args
/// - `allocator`: allocator for the returned source.
/// - `words`: SPIR-V words in little-endian host order.
/// - `stage`: stage expected by the caller.
/// - `entry_point`: name of the entry point to decompile.
///
/// # Return
/// GLSL source owned by the caller.
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
) TranslateError!Translated {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var context: Context = .{
        .a = arena.allocator(),
        .words = words,
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
    selected_entry: EntryPoint = undefined,
    selected_function: usize = 0,
    reachable: []bool = &.{},
    used_globals: []bool = &.{},
    opaque_expr: []?[]const u8 = &.{},
    inst_by_id: []?Inst = &.{},

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
        self.opaque_expr = try self.a.alloc(?[]const u8, self.bound);
        @memset(self.opaque_expr, null);

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
        try source.line("#version 450 core", .{});
        try source.line("", .{});

        const stage = stageFromModel(self.selected_entry.model);
        try self.emitExecutionModes(&source, stage);
        try self.emitStructDeclarations(&source);
        try self.emitGlobals(&source, stage);
        try self.emitFunctionPrototypes(&source);
        try self.emitFunctions(&source);
        return source.bytes.items;
    }

    fn emitExecutionModes(
        self: *Context,
        source: *Source,
        stage: types.ShaderStage,
    ) TranslateError!void {
        if (stage == .compute) {
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
                "layout(local_size_x = {d}, local_size_y = {d}, " ++
                    "local_size_z = {d}) in;",
                .{ size[0], size[1], size[2] },
            );
        }
        for (self.execution_modes.items) |mode| {
            if (mode.entry != self.selected_entry.function) continue;
            if (mode.mode == 9) {
                try source.line("layout(early_fragment_tests) in;", .{});
            }
        }
    }

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
            // Block structs are declared inline by emitInterfaceBlock.
            if (self.isBlock(id)) continue;
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
                    .struct_ => {
                        if (!self.isBlock(member)) {
                            try self.emitStructDeclaration(
                                source,
                                member,
                                states,
                            );
                        }
                    },
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
        stage: types.ShaderStage,
    ) TranslateError!void {
        var id: u32 = 1;
        while (id < self.bound) : (id += 1) {
            const variable = self.variables[id] orelse continue;
            if (!variable.is_global or !self.used_globals[id]) continue;
            try self.emitGlobal(source, id, variable, stage);
        }
    }

    fn emitGlobal(
        self: *Context,
        source: *Source,
        id: u32,
        variable: Variable,
        stage: types.ShaderStage,
    ) TranslateError!void {
        const deco = self.decorations[id];
        const pointer = self.types[variable.type_id] orelse
            return error.InvalidSpirv;
        const pointee = switch (pointer) {
            .pointer => |value| value.pointee,
            else => return error.InvalidSpirv,
        };
        const name = try self.globalName(id, variable, pointee);

        if (deco.builtin) |builtin| {
            if (variable.storage != StorageClass.input and
                variable.storage != StorageClass.output)
            {
                return error.Unsupported;
            }
            _ = try builtinName(builtin, stage, variable.storage);
            return;
        }

        switch (variable.storage) {
            StorageClass.input, StorageClass.output => {
                if (self.types[pointee]) |pointee_kind| {
                    switch (pointee_kind) {
                        .struct_ => {
                            if (self.isBuiltinInterfaceBlock(pointee)) {
                                return;
                            }
                            log.warn(
                                "interface block {d} has no builtin members",
                                .{pointee},
                            );
                            return error.Unsupported;
                        },
                        else => {},
                    }
                }
                const location = deco.location orelse {
                    log.warn(
                        "interface variable {s} has no location",
                        .{name},
                    );
                    return error.Unsupported;
                };
                var qualifier = std.ArrayListUnmanaged(u8).empty;
                defer qualifier.deinit(self.a);
                if (deco.invariant) try qualifier.appendSlice(
                    self.a,
                    "invariant ",
                );
                if (deco.flat) try qualifier.appendSlice(self.a, "flat ");
                if (deco.no_perspective) try qualifier.appendSlice(
                    self.a,
                    "noperspective ",
                );
                if (deco.centroid) try qualifier.appendSlice(
                    self.a,
                    "centroid ",
                );
                if (deco.sample) try qualifier.appendSlice(
                    self.a,
                    "sample ",
                );
                const direction = if (variable.storage == StorageClass.input)
                    "in"
                else
                    "out";
                try source.line(
                    "layout(location = {d}) {s}{s} {s};",
                    .{
                        location,
                        qualifier.items,
                        direction,
                        try self.declaration(pointee, name),
                    },
                );
            },
            StorageClass.uniform_constant => {
                try self.emitOpaqueUniform(
                    source,
                    id,
                    name,
                    pointee,
                    deco,
                );
            },
            StorageClass.uniform => {
                if (self.isBlock(pointee)) {
                    try self.emitInterfaceBlock(
                        source,
                        id,
                        name,
                        pointee,
                        .uniform,
                        deco,
                    );
                } else {
                    try source.line("uniform {s};", .{
                        try self.declaration(pointee, name),
                    });
                }
            },
            StorageClass.push_constant => {
                try self.emitInterfaceBlock(
                    source,
                    id,
                    "vfrhi_push_inst",
                    pointee,
                    .push_constant,
                    deco,
                );
            },
            StorageClass.storage_buffer => {
                if (!self.isBlock(pointee)) return error.Unsupported;
                try self.emitInterfaceBlock(
                    source,
                    id,
                    name,
                    pointee,
                    .storage_buffer,
                    deco,
                );
            },
            StorageClass.private => {
                try source.line("{s};", .{
                    try self.declaration(pointee, name),
                });
            },
            StorageClass.workgroup => {
                try source.line("shared {s};", .{
                    try self.declaration(pointee, name),
                });
            },
            else => return error.Unsupported,
        }
    }

    fn emitOpaqueUniform(
        self: *Context,
        source: *Source,
        id: u32,
        name: []const u8,
        pointee: u32,
        deco: DecorationState,
    ) TranslateError!void {
        _ = name;
        _ = deco;
        const info = try self.interfaceBinding(id);
        const descriptor_name = try self.descriptorName(
            info.set,
            info.binding,
        );
        if (self.isStorageImageType(pointee)) {
            const image = self.imageTypeOf(pointee) orelse
                return error.Unsupported;
            try source.line(
                "layout({s}) uniform {s};",
                .{
                    try imageFormatQualifier(image.format),
                    try self.declaration(pointee, descriptor_name),
                },
            );
        } else {
            try source.line("uniform {s};", .{
                try self.declaration(pointee, descriptor_name),
            });
        }
    }

    fn emitInterfaceBlock(
        self: *Context,
        source: *Source,
        id: u32,
        instance_name: []const u8,
        pointee: u32,
        kind: enum { uniform, storage_buffer, push_constant },
        deco: DecorationState,
    ) TranslateError!void {
        const type_kind = self.types[pointee] orelse
            return error.InvalidSpirv;
        const struct_info = switch (type_kind) {
            .struct_ => |value| value,
            else => return error.Unsupported,
        };
        const block_name = switch (kind) {
            .push_constant => "vfrhi_push",
            else => blk: {
                const info = try self.interfaceBinding(id);
                break :blk try self.descriptorName(
                    info.set,
                    info.binding,
                );
            },
        };
        const layout = switch (kind) {
            .uniform, .push_constant => "std140",
            .storage_buffer => "std430",
        };
        const qualifier = switch (kind) {
            .uniform, .push_constant => "uniform",
            .storage_buffer => "buffer",
        };
        _ = deco;
        try source.line("layout({s}) {s} {s} {{", .{
            layout,
            qualifier,
            block_name,
        });
        source.indent += 1;
        for (struct_info.members, 0..) |member, index| {
            const member_deco = self.memberDecoration(pointee, @intCast(index));
            const member_name = try self.fmt("m{d}", .{index});
            if (member_deco.offset) |offset| {
                if (member_deco.row_major) {
                    try source.line(
                        "layout(offset = {d}, row_major) {s};",
                        .{
                            offset,
                            try self.declaration(member, member_name),
                        },
                    );
                } else {
                    try source.line(
                        "layout(offset = {d}) {s};",
                        .{
                            offset,
                            try self.declaration(member, member_name),
                        },
                    );
                }
            } else if (member_deco.row_major) {
                try source.line("layout(row_major) {s};", .{
                    try self.declaration(member, member_name),
                });
            } else {
                try source.line("{s};", .{
                    try self.declaration(member, member_name),
                });
            }
        }
        source.indent -= 1;
        try source.line("}} {s};", .{instance_name});
    }

    fn emitFunctionPrototypes(
        self: *Context,
        source: *Source,
    ) TranslateError!void {
        for (self.functions.items) |*function| {
            if (function.id >= self.bound or !self.reachable[function.id]) {
                continue;
            }
            if (function.id == self.selected_entry.function) continue;
            try self.emitFunctionSignature(source, function, false);
            try source.line(";", .{});
        }
        if (self.entry_points.items.len != 1) {
            try source.line("", .{});
        }
    }

    fn emitFunctions(
        self: *Context,
        source: *Source,
    ) TranslateError!void {
        for (self.functions.items) |*function| {
            if (function.id >= self.bound or !self.reachable[function.id]) {
                continue;
            }
            if (function.id == self.selected_entry.function) continue;
            try self.emitFunctionSignature(source, function, true);
        }
        const entry = &self.functions.items[self.selected_function];
        try self.emitFunctionSignature(source, entry, true);
    }

    fn emitFunctionSignature(
        self: *Context,
        source: *Source,
        function: *Function,
        body: bool,
    ) TranslateError!void {
        const is_main = function.id == self.selected_entry.function;
        const name = if (is_main)
            "main"
        else
            try self.fmt("vfrhi_fn_{d}", .{function.id});
        const return_name = try self.typeName(function.return_type);
        try source.writeIndent();
        try source.print("{s} {s}(", .{
            if (function.return_type == try self.voidTypeId())
                "void"
            else
                return_name,
            name,
        });
        for (function.params.items, 0..) |param, index| {
            if (index != 0) try source.write(", ");
            const param_type = self.ids[param].type_id;
            const param_name = try self.fmt("p_{d}", .{param});
            const type_kind = self.types[param_type] orelse
                return error.InvalidSpirv;
            switch (type_kind) {
                .pointer => |pointer| {
                    if (self.isOpaque(pointer.pointee)) {
                        try source.print("{s}", .{
                            try self.declaration(
                                pointer.pointee,
                                param_name,
                            ),
                        });
                    } else {
                        try source.print("inout {s}", .{
                            try self.declaration(
                                pointer.pointee,
                                param_name,
                            ),
                        });
                    }
                },
                else => {
                    try source.print("{s}", .{
                        try self.declaration(param_type, param_name),
                    });
                },
            }
        }
        try source.write(")");
        if (!body) return;
        try source.write(" {\n");
        source.indent += 1;
        try self.emitFunctionBody(source, function);
        source.indent -= 1;
        try source.line("}}", .{});
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
            253 => {
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
            255 => {
                if (function.return_type == try self.voidTypeId()) {
                    try source.line("return;", .{});
                } else {
                    try source.line("return {s};", .{
                        try self.nullExpr(function.return_type),
                    });
                }
            },
            99 => {
                if (operands.len < 3) return error.InvalidSpirv;
                try source.line("imageStore({s}, {s}, {s});", .{
                    try self.valueName(operands[0]),
                    try self.valueName(operands[1]),
                    try self.valueName(operands[2]),
                });
            },
            224 => try source.line("barrier();", .{}),
            225, 226 => try source.line("memoryBarrier();", .{}),
            228 => {
                if (operands.len < 4) return error.InvalidSpirv;
                try source.line("atomicExchange({s}, {s});", .{
                    try self.lvalue(operands[0]),
                    try self.valueName(operands[3]),
                });
            },
            229 => try self.emitAtomic(source, inst, "atomicExchange"),
            230 => try self.emitAtomicCompareExchange(source, inst),
            232 => try self.emitAtomicIncrement(source, inst, "atomicAdd", 1),
            233 => try self.emitAtomicIncrement(source, inst, "atomicAdd", -1),
            234 => try self.emitAtomic(source, inst, "atomicAdd"),
            235 => try self.emitAtomic(source, inst, "atomicAdd"),
            236 => try self.emitAtomic(source, inst, "atomicMin"),
            237 => try self.emitAtomic(source, inst, "atomicMin"),
            238 => try self.emitAtomic(source, inst, "atomicMax"),
            239 => try self.emitAtomic(source, inst, "atomicMax"),
            240 => try self.emitAtomic(source, inst, "atomicAnd"),
            241 => try self.emitAtomic(source, inst, "atomicOr"),
            242 => try self.emitAtomic(source, inst, "atomicXor"),
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
        const expr = try self.lvalue(inst.operands[2]);
        if (self.isOpaque(type_id)) {
            self.opaque_expr[result] = expr;
            return;
        }
        try source.line("{s} = {s};", .{
            try self.valueName(result),
            expr,
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
            "main"
        else
            try self.fmt("vfrhi_fn_{d}", .{function_id});
        var call = std.ArrayListUnmanaged(u8).empty;
        defer call.deinit(self.a);
        try call.appendSlice(self.a, function_name);
        try call.append(self.a, '(');
        for (inst.operands[3..], 0..) |argument, index| {
            if (index != 0) try call.appendSlice(self.a, ", ");
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

    fn emitAtomic(
        self: *Context,
        source: *Source,
        inst: Inst,
        name: []const u8,
    ) TranslateError!void {
        if (inst.operands.len < 6) return error.InvalidSpirv;
        if (inst.opcode == 235) {
            try source.line("{s} = atomicAdd({s}, -{s});", .{
                try self.valueName(inst.operands[1]),
                try self.lvalue(inst.operands[2]),
                try self.valueName(inst.operands[5]),
            });
            return;
        }
        try source.line("{s} = {s}({s}, {s});", .{
            try self.valueName(inst.operands[1]),
            name,
            try self.lvalue(inst.operands[2]),
            try self.valueName(inst.operands[5]),
        });
    }

    fn emitAtomicCompareExchange(
        self: *Context,
        source: *Source,
        inst: Inst,
    ) TranslateError!void {
        const operands = inst.operands;
        if (operands.len < 7) return error.InvalidSpirv;
        try source.line("{s} = atomicCompSwap({s}, {s}, {s});", .{
            try self.valueName(operands[1]),
            try self.lvalue(operands[2]),
            try self.valueName(operands[5]),
            try self.valueName(operands[6]),
        });
    }

    fn emitAtomicIncrement(
        self: *Context,
        source: *Source,
        inst: Inst,
        name: []const u8,
        _: i32,
    ) TranslateError!void {
        if (inst.operands.len < 5) return error.InvalidSpirv;
        try source.line("{s} = {s}({s}, 1);", .{
            try self.valueName(inst.operands[1]),
            name,
            try self.lvalue(inst.operands[2]),
        });
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
            const sampler_type = try self.typeName(type_id);
            const image = try self.valueName(operands[2]);
            const sampler = try self.valueName(operands[3]);
            self.opaque_expr[result_id] = try self.fmt(
                "{s}({s}, {s})",
                .{ sampler_type, image, sampler },
            );
            return;
        }
        if (inst.opcode == 100) {
            if (operands.len < 3) return error.InvalidSpirv;
            self.opaque_expr[result_id] = try self.valueName(operands[2]);
            return;
        }

        const expression = try self.instructionExpression(inst);
        try source.line("{s} = {s};", .{ name, expression });
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
        // `OpCompositeExtract` and `OpArrayLength` carry literal
        // indices after the composite operand, so they must not be
        // resolved as ids.
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
            68 => {
                if (operands.len < 4) return error.InvalidSpirv;
                return self.fmt(
                    "{s}.m{d}.length()",
                    .{ a, operands[3] },
                );
            },
            12 => return self.extInst(inst),
            86 => return error.Unsupported,
            98 => {
                if (operands.len < 4) return error.InvalidSpirv;
                return self.fmt(
                    "imageLoad({s}, {s})",
                    .{ a, try self.valueName(operands[3]) },
                );
            },
            103 => {
                if (operands.len < 4) return error.InvalidSpirv;
                return self.fmt(
                    "textureSize({s}, {s})",
                    .{ a, try self.valueName(operands[3]) },
                );
            },
            104 => return self.fmt("imageSize({s})", .{a}),
            106 => return self.fmt("textureQueryLevels({s})", .{a}),
            107 => return self.fmt("textureSamples({s})", .{a}),
            87, 88, 89, 90, 95, 96 => {
                return self.imageInstruction(inst);
            },
            109 => return self.fmt("uint({s})", .{a}),
            110 => return self.fmt("int({s})", .{a}),
            111 => return self.fmt("float({s})", .{a}),
            112 => return self.fmt("float({s})", .{a}),
            114, 115 => return self.fmt("({s})({s})", .{
                try self.typeName(type_id),
                a,
            }),
            116 => return self.fmt("uint({s})", .{a}),
            117 => return self.fmt("int({s})", .{a}),
            118 => return self.fmt("float({s})", .{a}),
            119 => return self.fmt("double({s})", .{a}),
            120, 121, 122, 123 => return self.fmt("({s})({s})", .{
                try self.typeName(type_id),
                a,
            }),
            124 => return self.bitcast(type_id, operands[2]),
            126 => return self.fmt("(-{s})", .{a}),
            127 => return self.fmt("(-{s})", .{a}),
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
            => return self.binary(inst, a, b),
            142, 143 => return self.fmt("({s} * {s})", .{ a, b }),
            144, 145, 146 => return self.fmt("({s} * {s})", .{ a, b }),
            147 => return self.fmt("outerProduct({s}, {s})", .{ a, b }),
            148 => return self.fmt("dot({s}, {s})", .{ a, b }),
            149 => return self.fmt("uaddCarry({s}, {s})", .{ a, b }),
            150 => return self.fmt("usubBorrow({s}, {s})", .{ a, b }),
            151 => return self.fmt("umulExtended({s}, {s})", .{ a, b }),
            152 => return self.fmt("imulExtended({s}, {s})", .{ a, b }),
            154 => return self.fmt("any({s})", .{a}),
            155 => return self.fmt("all({s})", .{a}),
            156 => return self.fmt("isnan({s})", .{a}),
            157 => return self.fmt("isinf({s})", .{a}),
            164, 165, 166, 167, 168 => return self.logical(inst, a, b),
            169 => return self.select(inst),
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
            => return self.compare(inst, a, b),
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
                            .bool => return self.fmt("not({s})", .{a}),
                            else => {},
                        }
                    },
                    else => {},
                }
                return self.fmt("(~{s})", .{a});
            },
            204 => return self.fmt("bitfieldReverse({s})", .{a}),
            205 => return self.fmt("bitCount({s})", .{a}),
            207 => return self.fmt("dFdx({s})", .{a}),
            208 => return self.fmt("dFdy({s})", .{a}),
            209 => return self.fmt("fwidth({s})", .{a}),
            210 => return self.fmt("dFdxFine({s})", .{a}),
            211 => return self.fmt("dFdyFine({s})", .{a}),
            212 => return self.fmt("fwidthFine({s})", .{a}),
            213 => return self.fmt("dFdxCoarse({s})", .{a}),
            214 => return self.fmt("dFdyCoarse({s})", .{a}),
            215 => return self.fmt("fwidthCoarse({s})", .{a}),
            227 => return self.lvalue(operands[2]),
            else => {
                log.warn(
                    "unsupported SPIR-V opcode {d} in OpenGL translator",
                    .{inst.opcode},
                );
                return error.Unsupported;
            },
        }
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
            140, 141 => "%",
            else => return error.Unsupported,
        };
        const expression = try self.fmt("({s} {s} {s})", .{
            a,
            operator,
            b,
        });
        if (inst.opcode == 140 or inst.opcode == 141) {
            return self.fmt("mod({s}, {s})", .{ a, b });
        }
        return expression;
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
        if (vector) |info| {
            if (inst.opcode == 168) {
                return self.fmt("not({s})", .{a});
            }
            if (inst.opcode == 164 or inst.opcode == 165) {
                return self.fmt("{s}({s}, {s})", .{
                    if (inst.opcode == 164) "equal" else "notEqual",
                    a,
                    b,
                });
            }
            var builder = std.ArrayListUnmanaged(u8).empty;
            defer builder.deinit(self.a);
            try builder.appendSlice(self.a, try self.typeName(inst.operands[0]));
            try builder.append(self.a, '(');
            const operator: []const u8 = if (inst.opcode == 166)
                " || "
            else
                " && ";
            var index: u32 = 0;
            while (index < info.count) : (index += 1) {
                if (index != 0) try builder.appendSlice(self.a, ", ");
                try builder.appendSlice(
                    self.a,
                    try self.fmt("({s}[{d}]{s}{s}[{d}])", .{
                        a,
                        index,
                        operator,
                        b,
                        index,
                    }),
                );
            }
            try builder.append(self.a, ')');
            return self.a.dupe(u8, builder.items);
        }
        const operator = switch (inst.opcode) {
            164, 166 => "||",
            165, 167 => "&&",
            168 => "!",
            else => return error.Unsupported,
        };
        if (inst.opcode == 168) {
            return self.fmt("(!{s})", .{a});
        }
        return self.fmt("({s} {s} {s})", .{ a, operator, b });
    }

    fn compare(
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
            const function = switch (inst.opcode) {
                170, 180, 181 => "equal",
                171, 182, 183 => "notEqual",
                172, 173, 184, 185, 186, 187 => "greaterThan",
                174, 175, 188, 189, 190, 191 => "greaterThanEqual",
                176, 177 => "lessThan",
                178, 179 => "lessThanEqual",
                else => return error.Unsupported,
            };
            return self.fmt("{s}({s}, {s})", .{ function, a, b });
        }
        const operator = switch (inst.opcode) {
            170, 180, 181, 164 => "==",
            171, 182, 183, 165 => "!=",
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
        if (target == .float and from == .signed) {
            return self.fmt("intBitsToFloat({s})", .{source_name});
        }
        if (target == .float and from == .unsigned) {
            return self.fmt("uintBitsToFloat({s})", .{source_name});
        }
        if (target == .signed and from == .float) {
            return self.fmt("floatBitsToInt({s})", .{source_name});
        }
        if (target == .unsigned and from == .float) {
            return self.fmt("floatBitsToUint({s})", .{source_name});
        }
        return self.fmt("{s}({s})", .{
            try self.typeName(target_type),
            source_name,
        });
    }

    fn constructor(
        self: *Context,
        type_id: u32,
        args: []const u32,
    ) TranslateError![]const u8 {
        var builder = std.ArrayListUnmanaged(u8).empty;
        defer builder.deinit(self.a);
        try builder.appendSlice(self.a, try self.typeName(type_id));
        try builder.append(self.a, '(');
        for (args, 0..) |arg, index| {
            if (index != 0) try builder.appendSlice(self.a, ", ");
            try builder.appendSlice(self.a, try self.valueName(arg));
        }
        try builder.append(self.a, ')');
        return self.a.dupe(u8, builder.items);
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
                    try expression.appendSlice(
                        self.a,
                        try self.fmt(".m{d}", .{index}),
                    );
                    if (index >= type_kind.struct_.members.len) {
                        return error.InvalidSpirv;
                    }
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
        const sampler = try self.valueName(operands[2]);
        const coord = try self.valueName(operands[3]);
        switch (inst.opcode) {
            87 => {
                if (operands.len > 4) {
                    return self.sampledWithOperands(
                        "texture",
                        sampler,
                        coord,
                        operands[4..],
                    );
                }
                return self.fmt("texture({s}, {s})", .{
                    sampler,
                    coord,
                });
            },
            88 => {
                if (operands.len < 6) return error.InvalidSpirv;
                return self.sampledWithOperands(
                    "textureLod",
                    sampler,
                    coord,
                    operands[4..],
                );
            },
            89 => {
                if (operands.len < 5) return error.InvalidSpirv;
                return self.fmt("texture({s}, {s}, {s})", .{
                    sampler,
                    coord,
                    try self.valueName(operands[4]),
                });
            },
            90 => {
                if (operands.len < 6) return error.InvalidSpirv;
                return self.fmt("textureLod({s}, {s}, {s})", .{
                    sampler,
                    coord,
                    try self.valueName(operands[4]),
                });
            },
            95 => return self.fmt("texelFetch({s}, {s}, 0)", .{
                sampler,
                coord,
            }),
            96 => {
                if (operands.len < 5) return error.InvalidSpirv;
                return self.fmt("textureGather({s}, {s}, {s})", .{
                    sampler,
                    coord,
                    try self.valueName(operands[4]),
                });
            },
            else => return error.Unsupported,
        }
    }

    fn sampledWithOperands(
        self: *Context,
        function: []const u8,
        sampler: []const u8,
        coord: []const u8,
        operands: []const u32,
    ) TranslateError![]const u8 {
        if (operands.len == 0) {
            return self.fmt("{s}({s}, {s})", .{
                function,
                sampler,
                coord,
            });
        }
        const mask = operands[0];
        var rest = operands[1..];
        if (mask & 0x1 != 0) {
            if (rest.len < 1) return error.InvalidSpirv;
            const bias = try self.valueName(rest[0]);
            rest = rest[1..];
            return self.fmt("{s}({s}, {s}, {s})", .{
                function,
                sampler,
                coord,
                bias,
            });
        }
        if (mask & 0x2 != 0) {
            if (rest.len < 1) return error.InvalidSpirv;
            const lod = try self.valueName(rest[0]);
            return self.fmt("textureLod({s}, {s}, {s})", .{
                sampler,
                coord,
                lod,
            });
        }
        if (mask & 0x8 != 0) {
            if (rest.len < 1) return error.InvalidSpirv;
            const offset = try self.valueName(rest[0]);
            return self.fmt("textureOffset({s}, {s}, {s})", .{
                sampler,
                coord,
                offset,
            });
        }
        log.warn(
            "unsupported texture image operand mask 0x{x}",
            .{mask},
        );
        return error.Unsupported;
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
        const name = glslStd450Name(instruction) orelse
            return error.Unsupported;
        var builder = std.ArrayListUnmanaged(u8).empty;
        defer builder.deinit(self.a);
        try builder.appendSlice(self.a, name);
        try builder.append(self.a, '(');
        if (name.len == 4 and std.mem.eql(u8, name, "atan") and
            operands.len == 6)
        {
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
        var appended = false;
        for (operands[3..]) |index_id| {
            const type_kind = self.types[current_type] orelse
                return error.InvalidSpirv;
            switch (type_kind) {
                .struct_ => {
                    const index = try self.constantU32(index_id);
                    if (index >= type_kind.struct_.members.len) {
                        return error.InvalidSpirv;
                    }
                    const member_deco = self.memberDecoration(
                        current_type,
                        index,
                    );
                    if (member_deco.builtin) |builtin| {
                        if (appended) return error.Unsupported;
                        builder.clearRetainingCapacity();
                        try builder.appendSlice(
                            self.a,
                            try builtinName(
                                builtin,
                                stageFromModel(self.selected_entry.model),
                                StorageClass.output,
                            ),
                        );
                    } else {
                        try builder.appendSlice(
                            self.a,
                            try self.fmt(".m{d}", .{index}),
                        );
                    }
                    appended = true;
                    current_type = type_kind.struct_.members[index];
                },
                .array => |value| {
                    try builder.appendSlice(
                        self.a,
                        try self.fmt("[{s}]", .{
                            try self.valueName(index_id),
                        }),
                    );
                    appended = true;
                    current_type = value.element;
                },
                .runtime_array => |element| {
                    try builder.appendSlice(
                        self.a,
                        try self.fmt("[{s}]", .{
                            try self.valueName(index_id),
                        }),
                    );
                    appended = true;
                    current_type = element;
                },
                .vector => |value| {
                    try builder.appendSlice(
                        self.a,
                        try self.fmt("[{s}]", .{
                            try self.valueName(index_id),
                        }),
                    );
                    appended = true;
                    current_type = value.component;
                },
                .matrix => |value| {
                    try builder.appendSlice(
                        self.a,
                        try self.fmt("[{s}]", .{
                            try self.valueName(index_id),
                        }),
                    );
                    appended = true;
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
        if (self.opaque_expr[id]) |expression| return expression;
        if (self.constants[id]) |constant| {
            return self.constantExprFor(id, constant);
        }
        if (self.ids[id].kind == .function_parameter) {
            return self.fmt("p_{d}", .{id});
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
        if (self.decorations[id].builtin) |builtin| {
            return builtinName(
                builtin,
                stageFromModel(self.selected_entry.model),
                variable.storage,
            );
        }
        if (variable.storage == StorageClass.uniform_constant) {
            const info = try self.interfaceBinding(id);
            return self.descriptorName(info.set, info.binding);
        }
        if (variable.storage == StorageClass.push_constant) {
            return "vfrhi_push_inst";
        }
        return self.fmt("vfrhi_var_{d}", .{id});
    }

    fn globalName(
        self: *Context,
        id: u32,
        variable: Variable,
        pointee: u32,
    ) TranslateError![]const u8 {
        _ = variable;
        _ = pointee;
        return self.variableName(id);
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
        if (self.decorations[id].builtin == 25) {
            return "gl_WorkGroupSize";
        }
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
                    if (std.math.isNan(float)) {
                        return self.fmt(
                            "uintBitsToFloat(0x{x}u)",
                            .{constant.words[0]},
                        );
                    }
                    if (std.math.isInf(float)) {
                        return self.fmt(
                            "uintBitsToFloat(0x{x}u)",
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
                return self.fmt("{s}(0)", .{
                    try self.typeName(type_id),
                });
            },
            .matrix => {
                return self.fmt("{s}(0.0)", .{
                    try self.typeName(type_id),
                });
            },
            .array => |value| {
                var builder = std.ArrayListUnmanaged(u8).empty;
                defer builder.deinit(self.a);
                try builder.appendSlice(self.a, try self.typeName(type_id));
                try builder.append(self.a, '(');
                const length = try self.constantU32(value.length);
                var index: u32 = 0;
                while (index < length) : (index += 1) {
                    if (index != 0) try builder.appendSlice(self.a, ", ");
                    try builder.appendSlice(
                        self.a,
                        try self.nullExpr(value.element),
                    );
                }
                try builder.append(self.a, ')');
                return self.a.dupe(u8, builder.items);
            },
            .runtime_array => return error.Unsupported,
            .struct_ => |info| {
                var builder = std.ArrayListUnmanaged(u8).empty;
                defer builder.deinit(self.a);
                try builder.appendSlice(self.a, try self.structName(type_id));
                try builder.append(self.a, '(');
                for (info.members, 0..) |member, index| {
                    if (index != 0) try builder.appendSlice(self.a, ", ");
                    try builder.appendSlice(
                        self.a,
                        try self.nullExpr(member),
                    );
                }
                try builder.append(self.a, ')');
                return self.a.dupe(u8, builder.items);
            },
            else => return error.Unsupported,
        }
    }

    fn imageSamplerName(
        self: *Context,
        image_type_id: u32,
        storage: bool,
    ) TranslateError![]const u8 {
        const type_kind = self.types[image_type_id] orelse
            return error.InvalidSpirv;
        const image = switch (type_kind) {
            .image => |value| value,
            else => return error.InvalidSpirv,
        };
        const dimension = switch (image.dim) {
            0 => "1D",
            1 => "2D",
            2 => "3D",
            3 => "Cube",
            4 => "2DRect",
            5 => "Buffer",
            else => return error.Unsupported,
        };
        var builder = std.ArrayListUnmanaged(u8).empty;
        defer builder.deinit(self.a);
        if (storage) {
            try builder.appendSlice(self.a, "image");
        } else if (image.depth != 0) {
            try builder.appendSlice(self.a, "sampler");
        } else if (image.sampled == 2) {
            try builder.appendSlice(self.a, "image");
        } else {
            try builder.appendSlice(self.a, "sampler");
        }
        try builder.appendSlice(self.a, dimension);
        if (image.ms) try builder.appendSlice(self.a, "MS");
        if (image.arrayed) try builder.appendSlice(self.a, "Array");
        if (!storage and image.depth != 0) {
            try builder.appendSlice(self.a, "Shadow");
        }
        return self.a.dupe(u8, builder.items);
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
                if (value.width == 64) return error.Unsupported;
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
                break :blk self.fmt("{s}vec{d}", .{
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
                if (vector.count == value.count) {
                    break :blk self.fmt("{s}mat{d}", .{
                        component,
                        value.count,
                    });
                }
                break :blk self.fmt("{s}mat{d}x{d}", .{
                    component,
                    value.count,
                    vector.count,
                });
            },
            .image => |value| blk: {
                break :blk self.imageSamplerName(
                    type_id,
                    value.sampled == 2,
                );
            },
            .sampler => "sampler",
            .sampled_image => |image_type| blk: {
                break :blk self.imageSamplerName(image_type, false);
            },
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
            .bool => "b",
            .int => |value| if (value.signed) "i" else "u",
            .float => |value| if (value.width == 64) "d" else "",
            else => return error.InvalidSpirv,
        };
    }

    fn structName(
        self: *Context,
        id: u32,
    ) TranslateError![]const u8 {
        return self.fmt("vfrhi_struct_{d}", .{id});
    }

    fn descriptorName(
        self: *Context,
        set: u32,
        binding: u32,
    ) TranslateError![]const u8 {
        return self.fmt("vfrhi_set_{d}_binding_{d}", .{ set, binding });
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

    fn isBlock(self: *Context, type_id: u32) bool {
        const type_kind = self.types[type_id] orelse return false;
        switch (type_kind) {
            .struct_ => {},
            else => return false,
        }
        const deco = self.decorations[type_id];
        return deco.block or deco.buffer_block;
    }

    fn isBuiltinInterfaceBlock(self: *Context, type_id: u32) bool {
        if (!self.isBlock(type_id)) return false;
        const type_kind = self.types[type_id] orelse return false;
        const info = switch (type_kind) {
            .struct_ => |value| value,
            else => return false,
        };
        if (info.members.len == 0) return false;
        for (info.members, 0..) |_, index| {
            const deco = self.memberDecoration(
                type_id,
                @intCast(index),
            );
            if (deco.builtin == null) return false;
        }
        return true;
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

    fn isStorageImageType(self: *Context, type_id: u32) bool {
        const type_kind = self.types[type_id] orelse return false;
        return switch (type_kind) {
            .image => |value| value.sampled == 2,
            .array => |value| self.isStorageImageType(value.element),
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
