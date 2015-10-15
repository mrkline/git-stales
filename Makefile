DC = dmd
DFLAGS = -w -wi

all: debug

debug: DFLAGS += -debug -unittest -g
debug: stales

release: DFLAGS += -release -O
release: stales

stales: stales.d help.d
	$(DC) $(DFLAGS) -of$@ $^

clean:
	rm -f stales *.o

.PHONY: all, clean, debug, release
