# AMY Rev C drum machine, note-engine version
#   make        -> amy_drums.xex (needs cc65 on PATH)
#   make host   -> amy_drums_host; ./amy_drums_host writes amy_log.txt
#   make wav    -> engine + chip model render of the log (numpy, scipy)
#   make test   -> the cc65 build run in sim65 must give the host's log;
#                  log and kit checks

CL65 ?= cl65
SIM65 ?= sim65

amy_drums.xex: amy_drums.c amy_io.h
	$(CL65) -t atari -O -Ln amy_drums.lbl -o $@ amy_drums.c

host: amy_drums_host

amy_drums_host: amy_drums.c amy_host.c amy_io.h
	$(CC) -O2 -Wall -Wextra -o $@ amy_drums.c amy_host.c

amy_log.txt: amy_drums_host
	./amy_drums_host

wav: amy_log.txt
	python3 tools/render.py amy_log.txt amy_drums_preview.wav

test/amy_drums.sim: amy_drums.c amy_host.c amy_io.h
	$(CL65) -t sim6502 -O -DAMY_SIM -o $@ amy_drums.c amy_host.c

test: amy_drums.xex test/amy_drums.sim amy_log.txt
	cd test && $(SIM65) amy_drums.sim && cmp amy_log.txt ../amy_log.txt && echo "sim65 log identical to host"
	python3 test/check_log.py amy_log.txt

clean:
	rm -f amy_drums.xex amy_drums.lbl amy_drums_host amy_log.txt test/amy_drums.sim test/amy_log.txt *.o

.PHONY: host wav test clean
