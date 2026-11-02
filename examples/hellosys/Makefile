# make finds nas, ld and rm on PATH, as `sh -c` would (they live in /bin).
HELLO.SYSTEM: hello.o
	ld -t FF -a 2000 -o HELLO.SYSTEM hello.o
hello.o: hello.s
	nas -o hello.o hello.s
clean:
	rm -f HELLO.SYSTEM hello.o /mnt/MAUX/RESULT
