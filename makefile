make: .
	odin build . -out:a.out -debug -sanitize:address
release:
	odin build . -out:a.out -o:size
