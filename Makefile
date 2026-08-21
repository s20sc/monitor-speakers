SOURCES := $(wildcard Sources/*.swift)
BIN := bin/monitor-speakers
APP := bin/Monitor Speakers.app

$(BIN): $(SOURCES)
	@mkdir -p bin
	swiftc -O -o $(BIN) $(SOURCES)

# Menu bar app bundle. Ad-hoc signed so TCC records a stable identity.
.PHONY: app
app: $(BIN)
	rm -rf "$(APP)"
	mkdir -p "$(APP)/Contents/MacOS"
	cp $(BIN) "$(APP)/Contents/MacOS/Monitor Speakers"
	cp Resources/Info.plist "$(APP)/Contents/Info.plist"
	codesign -s - -f "$(APP)"

.PHONY: clean
clean:
	rm -rf bin
