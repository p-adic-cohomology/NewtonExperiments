CC ?= cc
CFLAGS ?= -O2 -std=c11 -Wall -Wextra -Werror

ifeq ($(shell uname -s),Darwin)
SHARED_LDFLAGS = -Wl,-undefined,dynamic_lookup
else
SHARED_LDFLAGS =
endif

.PHONY: all clean check-pack test

all: libevaluator.so

check-pack:
	@test -n "$(FS_PACK)" || { echo "Set FS_PACK to the FunSearch pack path" >&2; exit 1; }
	@test -f "$(FS_PACK)/include/funsearch.h" || { echo "FS_PACK must contain include/funsearch.h" >&2; exit 1; }

libevaluator.so: evaluator.c ../candidate.h | check-pack
	$(CC) -I"$(FS_PACK)/include" $(CFLAGS) -fPIC -shared $(SHARED_LDFLAGS) -pthread -o $@ evaluator.c

test_shim: test_shim.c evaluator.c ../candidate.h | check-pack
	$(CC) -I"$(FS_PACK)/include" $(CFLAGS) -pthread -o $@ test_shim.c evaluator.c

init_probe: init_probe.c evaluator.c ../candidate.h | check-pack
	$(CC) -I"$(FS_PACK)/include" $(CFLAGS) -pthread -o $@ init_probe.c evaluator.c

test: test_shim
	./test_shim
	../server/test_run_funsearch.sh

clean:
	rm -f libevaluator.so test_shim init_probe
