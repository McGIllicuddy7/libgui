make: .
	odin build . -out:a.out -sanitize:address -debug -o:speed
release:
	odin build . -out:a.out -o:speed
