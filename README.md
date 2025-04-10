# Matrix multiplication in Zig

This program demonstrates how a matrix multiplication similar to Fortran's `matmul` could be implemented in `zig`.
For not very big matrixes up to 1024x1024, its performance is similar or even faster than `gfortran`. For bigger matrixes though, gfortran seems to be much faster (at least in my machine).

## Requirements
Zig 0.14 (not tested with other zig compiler versions)

## Usage
Run `make test` to run the tests and `make build` to build the executable named `matmul`.
Modify the main routine to experiment with different types and sizes.