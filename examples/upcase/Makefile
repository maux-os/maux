# make finds nas, ld and rm on PATH, as `sh -c` would (they live in /bin).
upcase: upcase.o
	ld -o upcase upcase.o -L /usr/lib -l a
upcase.o: upcase.s
	nas -o upcase.o upcase.s
clean:
	rm -f upcase upcase.o
