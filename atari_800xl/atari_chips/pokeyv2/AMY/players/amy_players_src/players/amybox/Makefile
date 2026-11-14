# AMY Music Box, copper version
#   make        -> amybox.xex: the copper note engine's load segment, then the player
#   make host   -> amybox_host (logs every AMY and copper register write)
#   make check  -> CANTINA, PIANO, Rev C on: the log through the copper model and the chip
#                  model, against the engine version's log (test/engine_cantina.txt)

CL65 ?= cl65
COPPER ?= ../../copper
COMMON = ../common

all: amybox.xex

inst.h inst_words.json: mkinst.py
	python3 mkinst.py > /dev/null

copper_box.h copper_box.xex copper_box.bin: inst_words.json $(COPPER)/copgen.py $(COPPER)/amycop.py
	python3 $(COPPER)/copgen.py inst_words.json copper_box

player.xex: amybox.c songs.h inst.h copper_box.h $(COMMON)/cop.h
	$(CL65) -t atari -Oirs -I$(COMMON) -o $@ amybox.c

amybox.xex: copper_box.xex player.xex
	cat copper_box.xex player.xex > $@

host: amybox_host

amybox_host: amybox.c songs.h inst.h copper_box.h $(COMMON)/cop.h
	$(CC) -O2 -I$(COMMON) -o $@ amybox.c

test/cantina.txt: amybox_host
	./amybox_host 5 0 1500 $@ 1

check: test/cantina.txt copper_box.bin
	python3 $(COPPER)/copsim.py test/cantina.txt copper_box.bin out --frames --ref test/engine_cantina.txt

clean:
	rm -f amybox.xex player.xex amybox_host copper_box.* test/cantina.txt

.PHONY: all host check clean
