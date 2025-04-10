build: matmul.zig
	zig build-exe -O ReleaseFast $^

test: matmul.zig
	zig test $^

clean:
	rm matmul.o matmul