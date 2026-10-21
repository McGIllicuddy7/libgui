make: .
	odin build . -out:a.out -sanitize:address -debug
release:
	odin build . -out:a.out -o:speed
