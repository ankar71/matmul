# Matrix multiplication in Zig

This program demonstrates how a matrix multiplication similar to Fortran's `matmul` could be implemented in `zig`.
For not very big matrixes (like 1024x1024), its performance is similar or even faster than `gfortran`. For bigger matrixes though, gfortran seems to be much faster (at least in my machine).

Two implementation variants are used, with and without vectors. The results are similar, the vector-variant doesn't seem to have a performance advantage.

## Requirements
Zig 0.14 (not tested with other zig compiler versions)

## Usage
Run `make test` to run the tests and `make build` to build the executable named `matmul`.
The try
```
matmul [n]
```
where `n` is the number of repetitions (default is 10).
Modify the main routine to experiment with different types and sizes. Very big matrixes (like 4096x4096) take many seconds, use `1` as `n` in this case.