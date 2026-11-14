# AMY Rev C drum machine, copper version
#   make        -> amy_drums.xex: the copper note engine's load segment, then the player
#                  (needs cc65 on PATH and python3)
#   make host   -> amy_drums_host; ./amy_drums_host writes amy_log.txt
#   make check  -> the log through the copper model and the chip model, against the
#                  engine version's log (test/engine_log.txt)
#   make test   -> the cc65 build run in sim65 must give the host's log

CL65 ?= cl65
SIM65 ?= sim65
COPPER ?= ../../copper
COMMON = ../common

all: amy_drums.xex

# the kit's engine words -> the copper note engine
kitdump: amy_drums.c amy_host.c amy_io.h
	$(CC) -O2 -DKITDUMP -I$(COMMON) -o $@ amy_drums.c amy_host.c

kit.json: kitdump
	./kitdump > $@

copper_kit.h copper_kit.xex copper_kit.bin: kit.json $(COPPER)/copgen.py $(COPPER)/amycop.py
	python3 $(COPPER)/copgen.py kit.json copper_kit

player.xex: amy_drums.c amy_io.h copper_kit.h $(COMMON)/cop.h
	$(CL65) -t atari -O -I$(COMMON) -Ln amy_drums.lbl -o $@ amy_drums.c

amy_drums.xex: copper_kit.xex player.xex
	cat copper_kit.xex player.xex > $@

host: amy_drums_host

amy_drums_host: amy_drums.c amy_host.c amy_io.h copper_kit.h $(COMMON)/cop.h
	$(CC) -O2 -Wall -Wextra -I$(COMMON) -o $@ amy_drums.c amy_host.c

amy_log.txt: amy_drums_host
	./amy_drums_host

check: amy_log.txt copper_kit.bin
	python3 $(COPPER)/copsim.py amy_log.txt copper_kit.bin out --ref test/engine_log.txt

test/amy_drums.sim: amy_drums.c amy_host.c amy_io.h copper_kit.h
	$(CL65) -t sim6502 -O -DAMY_SIM -I$(COMMON) -o $@ amy_drums.c amy_host.c

test: amy_drums.xex test/amy_drums.sim amy_log.txt
	cd test && $(SIM65) amy_drums.sim && cmp amy_log.txt ../amy_log.txt && echo "sim65 log identical to host"

clean:
	rm -f amy_drums.xex player.xex amy_drums.lbl amy_drums_host kitdump kit.json copper_kit.* amy_log.txt test/amy_drums.sim test/amy_log.txt *.o

.PHONY: all host check test clean
