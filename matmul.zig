const std = @import("std");
const expect = std.testing.expect;

// Column-major order matrix (aka Fortran-style)
// See also: https://en.wikipedia.org/wiki/Row-_and_column-major_order
// This comptime function creates a matrix with cells of type t and with rs rows and cs columns.
pub fn Matrix(comptime t: type, rs: comptime_int, cs: comptime_int) type {
    const ti = @typeInfo(t);
    const size = rs * cs;

    // Some restrictions to ensure that only well-aligned types can be used
    switch (ti) {
        .int => {
            if (ti.int.bits != 64 and ti.int.bits != 32 and ti.int.bits != 16) {
                @compileError("Matrix type must be an integer of size 32 or 64");
            }
        },
        .float => {
            if (ti.float.bits != 32 and ti.float.bits != 64) {
                @compileError("Matrix type must be a float of size 32 or 64");
            }
        },
        else => @compileError("Matrix type must be an integer or float"),
    }

    if (size > (1 << 32)) {
        @compileError("Matrix cannot have more than 2^32 items");
    }

    return struct {
        const Self = @This();

        data: *[size]t,

        // The Constructor takes an optional function that can initialize the matrix in a custom way
        // If no initializaton function is given, all values are set to zero.
        pub fn init(f: ?fn (usize, usize) t) !Self {
            const allocator = std.heap.page_allocator;
            var matrix = Self{ .data = try allocator.create([size]t) };
            if (f) |init_f| {
                for (0..rs) |row| {
                    for (0..cs) |col| {
                        matrix.set(row, col, init_f(row, col));
                    }
                }
            } else {
                matrix.data.* = [_]t{0} ** size;
            }
            return matrix;
        }

        pub fn deinit(self: *Self) void {
            std.heap.page_allocator.destroy(self.data);
        }

        // methods

        // Read a cell using column-major method
        pub inline fn at(self: Self, row: usize, col: usize) t {
            return self.data[col * rs + row];
        }

        pub inline fn slice_at(self: Self, row: usize, col: usize, slice_size: usize) []t {
            const offset: usize = col * rs + row;
            return self.data[offset..(offset + slice_size)];
        }

        // Set a cell to the given value using column-major method
        pub inline fn set(self: Self, row: usize, col: usize, value: t) void {
            self.data[col * rs + row] = value;
        }
    };
}

// Generic method that produces a matrix multiply-method for two matrixes [M x K] and [K x N].
// The resulting matrix has size [M x N].
// The caller should provide as a first argument a matrix of the appropriate size with all its cells set to zero.
// Notice that in the innermost loop, only the row indeces are changed,
// therefore - due to column-major order - the data are accessed in a continuous manner minimizing cache misses.
pub fn matrix_multiply(comptime t: type, m: comptime_int, k: comptime_int, n: comptime_int) (fn (Matrix(t, m, n), Matrix(t, m, k), Matrix(t, k, n)) void) {
    return struct {
        fn multiply(result: Matrix(t, m, n), m1: Matrix(t, m, k), m2: Matrix(t, k, n)) void {
            if (@typeInfo(t) == .float) {
                @setFloatMode(.optimized);
            }
            for (0..n) |j| {
                for (0..k) |kk| {
                    const m2_at_kk_j = m2.at(kk, j);
                    for (0..m) |i| {
                        const v = result.at(i, j) + m1.at(i, kk) * m2_at_kk_j;
                        result.set(i, j, v);
                    }
                }
            }
        }
    }.multiply;
}

// Similar to matrix_multiply, uses vectors
pub fn matrix_vec_multiply(comptime t: type, m: comptime_int, k: comptime_int, n: comptime_int) (fn (Matrix(t, m, n), Matrix(t, m, k), Matrix(t, k, n)) void) {
    // Use the suggested vector length or 4 as default. You can experiment with different vector lengths
    const veclen = std.simd.suggestVectorLength(t) orelse 4;
    const loop_count = @divFloor(m, veclen);
    const rem = m % veclen;

    return struct {
        fn multiply(result: Matrix(t, m, n), m1: Matrix(t, m, k), m2: Matrix(t, k, n)) void {
            if (@typeInfo(t) == .float) {
                @setFloatMode(.optimized);
            }
            for (0..n) |j| {
                for (0..k) |kk| {
                    const v2: @Vector(veclen, t) = @splat(m2.at(kk, j));
                    for (0..loop_count) |count| {
                        const i = count * veclen;
                        const result_slice = result.slice_at(i, j, veclen);
                        const pr: @Vector(veclen, t) = result_slice[0..veclen].*;
                        const v1: @Vector(veclen, t) = m1.slice_at(i, kk, veclen)[0..veclen].*;
                        result_slice[0..veclen].* = pr + v1 * v2;
                    }
                    // this part is emmited only if the M-dimension is not divided exctly by the vector length used
                    inline while (rem > 0) {
                        const i_rem = loop_count * veclen;
                        const v2r: @Vector(rem, t) = @splat(m2.at(kk, j));
                        const result_slice = result.slice_at(i_rem, j, rem);
                        const pr: @Vector(rem, t) = result_slice[0..rem].*;
                        const v1: @Vector(rem, t) = m1.slice_at(i_rem, kk, rem)[0..rem].*;
                        result_slice[0..rem].* = pr + v1 * v2r;
                        break;
                    }
                }
            }
        }
    }.multiply;
}

// This is an initializastion function that can be used to fill the matrix with numbers in ascending order,
// starting from 1.
pub fn ascending_filler(comptime t: type, max_col: comptime_int) (fn (usize, usize) t) {
    const ti = @typeInfo(t);
    switch (ti) {
        .int => return struct {
            fn fill(row: usize, col: usize) t {
                return @intCast(max_col * row + col + 1);
            }
        }.fill,
        .float => return struct {
            fn fill(row: usize, col: usize) t {
                return @floatFromInt(max_col * row + col + 1);
            }
        }.fill,
        else => @compileError("ascending_filler: type must be an integer or a float"),
    }
}

pub fn diagonal_filler(comptime t: type, v: t) (fn (usize, usize) t) {
    return struct {
        fn fill(row: usize, col: usize) t {
            if (row == col) {
                return v;
            }
            return 0;
        }
    }.fill;
}

pub fn const_filler(comptime t: type, v: t) (fn (usize, usize) t) {
    return struct {
        fn fill(row: usize, col: usize) t {
            _ = row;
            _ = col;
            return v;
        }
    }.fill;
}

// A matrix multiplied by the idenity matrix should produce the same matrix.
test "multiply with identity matrix" {
    const cell_t = f32;
    const size = 16;

    var m1 = try Matrix(cell_t, size, size).init(ascending_filler(cell_t, size));
    defer m1.deinit();
    var m2 = try Matrix(cell_t, size, size).init(diagonal_filler(cell_t, 1));
    defer m2.deinit();

    var result = try Matrix(cell_t, size, size).init(null);
    defer result.deinit();

    const multiply = matrix_multiply(cell_t, size, size, size);
    multiply(result, m1, m2);
    try expect(std.mem.eql(cell_t, m1.data, result.data));

    // repeate using vectors
    const vec_multiply = matrix_vec_multiply(cell_t, size, size, size);
    result.data.* = [_]cell_t{0} ** (size * size);
    vec_multiply(result, m1, m2);
    try expect(std.mem.eql(cell_t, m1.data, result.data));
}

// Two matrixes with all their cells equal to 1 should produce, when multiplied,
// a matrix which has all its cells equal to the size of their common dimension.
test "multiply const matrix" {
    const cell_t = i32;
    const size_m = 22;
    const size_k = 24;
    const size_n = 20;
    var m1 = try Matrix(cell_t, size_m, size_k).init(const_filler(cell_t, 1));
    defer m1.deinit();

    var m2 = try Matrix(cell_t, size_k, size_n).init(const_filler(cell_t, 1));
    defer m2.deinit();

    var result = try Matrix(cell_t, size_m, size_n).init(null);
    defer result.deinit();

    const size = size_m * size_n;
    const expected: [size]cell_t = [_]cell_t{size_k} ** size;

    const multiply = matrix_multiply(cell_t, size_m, size_k, size_n);
    multiply(result, m1, m2);
    try expect(std.mem.eql(cell_t, &expected, result.data));

    // repeate using vectors
    const vec_multiply = matrix_vec_multiply(cell_t, size_m, size_k, size_n);
    result.data.* = [_]cell_t{0} ** (size);
    vec_multiply(result, m1, m2);
    try expect(std.mem.eql(cell_t, &expected, result.data));
}

fn parse_ntimes() !usize {
    const args = try std.process.argsAlloc(std.heap.page_allocator);
    defer std.process.argsFree(std.heap.page_allocator, args);

    var result: usize = 10;
    if (args.len >= 2) {
        if (std.fmt.parseUnsigned(usize, args[1], 0)) |times| {
            result = times;
        } else |_| {
            std.debug.print("Invalid value '{s}' ignored\n", .{args[1]});
        }
    }
    return result;
}

fn perform(use_vectors: bool, ntimes: usize) !i64 {
    // Change the following values to experiment with different types and sizes
    const cell_t = f64;
    const size_m = 1024;
    const size_k = 1280;
    const size_n = 1024;

    // 'multiply' and 'vec_multiply' are functions that multiply a MxK matrix with a KxN matrix
    // and produce a MxN matrix.
    const multiply = matrix_multiply(cell_t, size_m, size_k, size_n);
    const vec_multiply = matrix_vec_multiply(cell_t, size_m, size_k, size_n);

    var m1 = try Matrix(cell_t, size_m, size_k).init(const_filler(cell_t, 1));
    std.debug.print("Matrix 1: {}x{}, type {}\n", .{ size_m, size_k, cell_t });
    defer m1.deinit();

    var m2 = try Matrix(cell_t, size_k, size_n).init(const_filler(cell_t, 1));
    std.debug.print("Matrix 2: {}x{}, type {}\n", .{ size_k, size_n, cell_t });
    defer m2.deinit();

    var product = try Matrix(cell_t, size_m, size_n).init(null);
    defer product.deinit();

    const start_time = std.time.milliTimestamp();
    if (use_vectors) {
        for (0..ntimes) |_| {
            vec_multiply(product, m1, m2);
        }
    } else {
        for (0..ntimes) |_| {
            multiply(product, m1, m2);
        }
    }
    const end_time = std.time.milliTimestamp();

    std.debug.print("Product : {}x{}, type {}\n", .{ size_m, size_n, cell_t });
    return end_time - start_time;
}

fn report(time_in_ms: i64, msg: []const u8) void {
    const secs = @divFloor(time_in_ms, 1000);
    const msecs = @rem(time_in_ms, 1000);
    std.debug.print("{s}: {}s and {}ms\n-----\n", .{ msg, secs, msecs });
}

pub fn main() !void {
    const ntimes = try parse_ntimes();
    std.debug.print("Repetitions: {}\n*****\n", .{ntimes});

    std.debug.print("Starting the no-vector variant...\n", .{});
    const tt1 = try perform(false, ntimes);
    report(tt1, "Time without vectors:");

    std.debug.print("Starting the vector variant...\n", .{});
    const tt2 = try perform(true, ntimes);
    report(tt2, "Time with vectors:");
}
