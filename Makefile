.PHONY: test check-source

test:
	python3 -m unittest discover -s tests -v

check-source:
	xcrun clang -arch x86_64 -mmacosx-version-min=10.13 -fobjc-arc -Wno-deprecated-declarations -fsyntax-only src/AquariumCompatibility.m
