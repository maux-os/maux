# make finds nas, ld and rm on PATH, as `sh -c` would (they live in /bin).
LS.SYSTEM: ls.o
	ld -t FF -a 2000 -o LS.SYSTEM ls.o
ls.o: ls.s
	nas -o ls.o ls.s
test: LS.SYSTEM
	rm -f GOT
	sh mkwant
	bye LS.SYSTEM
	sh check
clean:
	rm -f LS.SYSTEM ls.o GOT WANT
