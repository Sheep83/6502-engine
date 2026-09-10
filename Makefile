# 6502-engine — deliberately uncomplicated.
KA    ?= /Users/brianmorrice/dev/tools/kickassembler/KickAss.jar
X64   ?= /opt/homebrew/bin/x64sc
C1541 ?= /opt/homebrew/bin/c1541
ROOT  := $(CURDIR)

PRG   := $(ROOT)/build/engine.prg
D64   := $(ROOT)/build/engine.d64

# The acceptance launch options, defined ONCE.
#
# They live here and nowhere else because drift between two copies of this
# command line is exactly what broke manual fixture selection: .vscode/tasks.json
# carried its own hand-written x64sc invocation, that copy had no -default, and
# the user's saved vicerc bound the host SPACE key to an emulated joystick.
#
#   -default    ignore ~/.config/vice/vicerc entirely
#   +saveres    ...and never write our settings back over the user's own
#   -joydev1 0  detach BOTH joystick devices. Control port 1 is CIA1 $DC01 and
#   -joydev2 0  control port 2 is CIA1 $DC00 -- the exact two registers the
#               fixture-select scan uses. A keyset or numpad binding consumes
#               the host key and drives those lines before the keyboard matrix
#               ever sees it, so the scan reads nothing and nothing happens.
#   +keyset     belt and braces: no keyset joystick at all.
#
# Normal speed, no monitor, no warp: the only configuration in which what you
# see is what the machine really does.
VICE_OPTS := -default +saveres -pal -joydev1 0 -joydev2 0 +keyset

.PHONY: all build d64 test-p0 test run run-d64 capture clean

all: build

# Fixed output location. No per-run directories, ever.
build:
	@mkdir -p build
	java -jar $(KA) src/main.asm -odir $(ROOT)/build -o $(PRG) -vicesymbols

# A bootable disk image of the same binary. Nothing in the test path needs it;
# it exists so the program can be launched the way real hardware would load it.
d64: build
	@rm -f $(D64)
	@$(C1541) -format "6502engine,01" d64 $(D64) >/dev/null
	@$(C1541) $(D64) -write $(PRG) engine >/dev/null
	@echo "wrote $(D64)"

test-p0: build
	python3 tests/test_p0.py

test: test-p0

# The acceptance configuration.
#
# VICE runs in the FOREGROUND. It used to be launched with a trailing `&`, and
# that is why the VS Code "Run in VICE" task appeared to do nothing: make
# returned the instant it had forked, VS Code treated the task as finished and
# killed its whole process tree, taking the emulator with it. Held in the
# foreground, the task lives exactly as long as the emulator does and ending the
# task stops it cleanly -- which is also the process ownership this repository
# asks for everywhere else.
#
# From a terminal, background it yourself if you want the prompt back: `make run &`.
run: build
	$(X64) $(VICE_OPTS) -autostartprgmode 1 -autostart $(PRG)

run-d64: d64
	$(X64) $(VICE_OPTS) -autostart $(D64)

capture: build
	python3 tools/capture_p0.py

clean:
	rm -f build/*.prg build/*.d64 build/*.vs build/*.sym
