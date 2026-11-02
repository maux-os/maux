# make finds nas, ld and rm on PATH, as `sh -c` would (they live in /bin).
hello: hello.o
	ld -o hello hello.o -L /usr/lib -l a
hello.o: hello.s
	nas -o hello.o hello.s
clean:
	rm -f hello hello.o
