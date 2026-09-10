APPNAME ?= gitstatusd
PRESET ?= default

ZSH := $(shell command -v zsh 2> /dev/null)

# The real build lives in CMakeLists.txt (see CMakePresets.json for the
# configurations). This is a convenience wrapper for the dynamic developer
# build; ./build is still what produces the static binaries we ship.

all: $(APPNAME)

$(APPNAME): usrbin/$(APPNAME)

.PHONY: usrbin/$(APPNAME)
usrbin/$(APPNAME):
	cmake --preset $(PRESET)
	cmake --build --preset $(PRESET) --parallel
	cp -f -- out/$(PRESET)/gitstatusd $@

test: usrbin/$(APPNAME)
	ctest --preset $(PRESET)

clean:
	rm -rf -- out obj

zwc:
	$(or $(ZSH),:) -fc 'for f in *.zsh install; do zcompile -R -- $$f.zwc $$f || exit; done'

minify:
	rm -rf -- .clang-format .clang-tidy .git .gitattributes .gitignore .vscode CMakeLists.txt CMakePresets.json deps docs out src test usrbin/.gitkeep LICENSE Makefile README.md build mbuild

pkg: zwc
	GITSTATUS_DAEMON= GITSTATUS_CACHE_DIR=$(shell pwd)/usrbin ./install -f

.PHONY: all $(APPNAME) test clean zwc minify pkg help

help:
	@echo "Usage: make [TARGET] [PRESET=default|static|asan|tsan]"
	@echo "Available targets:"
	@echo "  all         Build $(APPNAME) with cmake (default target)"
	@echo "  test        Run test/run.sh against the built binary via ctest"
	@echo "  clean       Remove generated files and directories"
	@echo "  zwc         Compile Zsh files"
	@echo "  minify      Remove unnecessary files and folders"
	@echo "  pkg         Create a package"
