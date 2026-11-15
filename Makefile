.PHONY: all clean

PROJECT := default.project.json
OUTPUT := dist/Cleaner.rbxm

SOURCES := $(shell find src -type f -name '*.luau')
SOURCE_DIRS := $(shell find src -type d)

all: $(OUTPUT)

$(OUTPUT): Makefile pesde.toml pesde.lock $(PROJECT) $(SOURCES) $(SOURCE_DIRS) | dist
	pesde install --locked
	rojo build $(PROJECT) -o $@

dist:
	mkdir -p $@

clean:
	rm -rf dist
