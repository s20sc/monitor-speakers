SOURCES := $(wildcard Sources/*.swift)
BIN := bin/monitor-speakers

$(BIN): $(SOURCES)
	@mkdir -p bin
	swiftc -O -o $(BIN) $(SOURCES)

.PHONY: clean
clean:
	rm -rf bin
