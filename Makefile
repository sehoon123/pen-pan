.DEFAULT_GOAL := build

.PHONY: build test test-native check clean

build: .build/pen-pan

test: .build/pen-pan-tests
	.build/pen-pan-tests --offline

test-native: .build/pen-pan-tests
	.build/pen-pan-tests --native

check: build test test-native

.build:
	mkdir -p .build

.build/pen-pan: pen-pan.swift | .build
	xcrun swiftc -O -warnings-as-errors -parse-as-library pen-pan.swift -o $@

.build/pen-pan-tests: pen-pan.swift pen-pan-tests.swift | .build
	xcrun swiftc -O -warnings-as-errors -D TESTING -parse-as-library pen-pan.swift pen-pan-tests.swift -o $@

clean:
	rm -rf .build
