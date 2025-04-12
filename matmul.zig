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

    const multiply = matrix_multiply(cell_t, size, size, size);

    var result = try Matrix(cell_t, size, size).init(null);
    defer result.deinit();

    multiply(result, m1, m2);

    try expect(std.mem.eql(cell_t, m1.data, result.data));
}

// Two matrixes with all their cells equal to 1 should produce, when multiplied,
// a matrix which has all its cells equal to the size of their common dimension.
test "multiply const matrix" {
    const cell_t = i32;
    const size_m = 16;
    const size_k = 24;
    const size_n = 20;
    var m1 = try Matrix(cell_t, size_m, size_k).init(const_filler(cell_t, 1));
    defer m1.deinit();

    var m2 = try Matrix(cell_t, size_k, size_n).init(const_filler(cell_t, 1));
    defer m2.deinit();

    const multiply = matrix_multiply(cell_t, size_m, size_k, size_n);

    var result = try Matrix(cell_t, size_m, size_n).init(null);
    defer result.deinit();
    multiply(result, m1, m2);
    const size = size_m * size_n;
    const expected: [size]cell_t = [_]cell_t{size_k} ** size;

    try expect(std.mem.eql(cell_t, &expected, result.data));
}

pub fn main() !void {
    @setFloatMode(.optimized);

    const args = try std.process.argsAlloc(std.heap.page_allocator);
    defer std.process.argsFree(std.heap.page_allocator, args);
    var ntimes: usize = 10;
    if (args.len >= 2) {
        if (std.fmt.parseUnsigned(usize, args[1], 0)) |times| {
            ntimes = times;
        } else |_| {
            std.debug.print("Invalid value '{s}' ignored\n", .{args[1]});
        }
    }
    std.debug.print("Multiplication will be repeated {} times\n", .{ntimes});

    // Change the following values to experiment with different types and sizes
    const size_m = 640;
    const size_k = 512;
    const size_n = 640;
    const cell_t = f64;

    var m1 = try Matrix(cell_t, size_m, size_k).init(const_filler(cell_t, 1));
    std.debug.print("Matrix 1: {}x{}, type {}\n", .{ size_m, size_k, cell_t });
    defer m1.deinit();

    var m2 = try Matrix(cell_t, size_k, size_n).init(const_filler(cell_t, 1));
    std.debug.print("Matrix 2: {}x{}, type {}\n", .{ size_k, size_n, cell_t });
    defer m2.deinit();

    // 'multiply' is a function that multiplies a MxK matrix with a KxN matrix
    // and produces a MxN matrix.
    const multiply = matrix_multiply(cell_t, size_m, size_k, size_n);
    var product = try Matrix(cell_t, size_m, size_n).init(null);
    defer product.deinit();

    const start_time = std.time.milliTimestamp();
    for (0..ntimes) |_| {
        multiply(product, m1, m2);
    }
    const end_time = std.time.milliTimestamp();

    std.debug.print("Product : {}x{}, type {}\n", .{ size_m, size_n, cell_t });
    const total_time = end_time - start_time;
    const secs = @divFloor(total_time, 1000);
    const msecs = @rem(total_time, 1000);
    if (ntimes > 1) {
        std.debug.print("Time for {} repetitions: {}s and {}ms\n", .{ ntimes, secs, msecs });
    } else {
        std.debug.print("Time: {}s and {}ms\n", .{ secs, msecs });
    }
}
