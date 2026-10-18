SWIFTC := swiftc
SDK := $(shell xcrun --sdk macosx --show-sdk-path)
TARGET := arm64-apple-macosx14.0
APP := build/Lumos.app
MACOS := $(APP)/Contents/MacOS
RESOURCES := $(APP)/Contents/Resources
# Separate from MacOS/: `lumos` and `Lumos` collide on case-insensitive volumes.
HELPERS := $(APP)/Contents/Helpers
ENGINE_SRC := src/FileRecord.swift src/Formatters.swift src/Privacy.swift src/QueryParser.swift \
	src/IndexData.swift src/IndexSearch.swift src/NameTrigrams.swift src/IndexStore.swift src/IndexSnapshot.swift \
	src/DirectoryScanner.swift src/FileWatcher.swift src/IndexService.swift \
	src/QueryProtocol.swift src/QueryServer.swift
INDEXER_SRC := $(ENGINE_SRC) src/IndexerMain.swift
CLIENT_SRC := src/QueryProtocol.swift src/Formatters.swift src/ClientSupport.swift src/LumosMCP.swift src/LumosCLI.swift
APP_SRC := $(ENGINE_SRC) src/LumosApp.swift src/AppStore.swift src/ContentView.swift src/ResultsTableView.swift src/GlobalHotKey.swift
TEST_SRC := tests/TestHarness.swift tests/TestSupport.swift tests/QueryParserTests.swift tests/FormatterTests.swift \
	tests/PrivacyTests.swift tests/IndexDataTests.swift tests/SearchTests.swift tests/ScannerTests.swift \
	tests/SnapshotTests.swift tests/SpecialCharacterTests.swift tests/QueryTests.swift tests/TrigramTests.swift \
	tests/MCPTests.swift
# Client code the tests exercise without the CLI's @main.
TEST_CLIENT_SRC := src/ClientSupport.swift src/LumosMCP.swift
BINDIR := $(HOME)/.local/bin

.PHONY: all run app test clean icon cli install-cli

all: app

app: $(APP)/Contents/MacOS/Lumos $(HELPERS)/lumos $(HELPERS)/lumos-index $(APP)/Contents/Info.plist $(RESOURCES)/AppIcon.icns

build/lumos: $(CLIENT_SRC)
	mkdir -p build
	$(SWIFTC) -O -parse-as-library \
		-target $(TARGET) \
		-sdk $(SDK) \
		-framework Foundation \
		-o $@ \
		$(CLIENT_SRC)

$(HELPERS)/lumos: build/lumos
	mkdir -p $(HELPERS)
	cp build/lumos $@

$(HELPERS)/lumos-index: build/lumos-index
	mkdir -p $(HELPERS)
	cp build/lumos-index $@

build/lumos-index: $(INDEXER_SRC)
	mkdir -p build
	$(SWIFTC) -O -parse-as-library \
		-target $(TARGET) \
		-sdk $(SDK) \
		-framework Foundation \
		-framework CoreServices \
		-o $@ \
		$(INDEXER_SRC)

$(APP)/Contents/MacOS/Lumos: $(APP_SRC)
	mkdir -p $(MACOS) $(RESOURCES)
	$(SWIFTC) -O -parse-as-library \
		-target $(TARGET) \
		-sdk $(SDK) \
		-framework AppKit \
		-framework Carbon \
		-framework SwiftUI \
		-framework Foundation \
		-framework CoreServices \
		-o $@ \
		$(APP_SRC)

$(APP)/Contents/Info.plist: Info.plist
	mkdir -p $(APP)/Contents
	cp Info.plist $@

$(RESOURCES)/AppIcon.icns: build/icon_1024.png scripts/png_to_icns.py
	mkdir -p $(RESOURCES)
	python3 scripts/png_to_icns.py build/icon_1024.png $@

build/icon_1024.png: scripts/generate_icon.swift
	mkdir -p build
	$(SWIFTC) -O -target $(TARGET) -sdk $(SDK) -framework AppKit -o build/generate_icon scripts/generate_icon.swift
	./build/generate_icon build/icon_1024.png

icon: $(RESOURCES)/AppIcon.icns

run: app
	-killall Lumos
	open $(APP)

cli: build/lumos build/lumos-index

# Links the CLI from the built app so `lumos` keeps working after `make app`.
install-cli: app
	mkdir -p $(BINDIR)
	ln -sf "$(CURDIR)/$(HELPERS)/lumos" $(BINDIR)/lumos
	@echo "Installed $(BINDIR)/lumos"
	@case ":$$PATH:" in *":$(BINDIR):"*) ;; *) echo "Add $(BINDIR) to your PATH, e.g.: echo 'export PATH=\"$(BINDIR):\$$PATH\"' >> ~/.zshrc";; esac

test:
	mkdir -p build
	$(SWIFTC) -O -parse-as-library \
		-target $(TARGET) \
		-sdk $(SDK) \
		-framework Foundation \
		-framework CoreServices \
		-o build/lumos-tests \
		$(TEST_SRC) $(ENGINE_SRC) $(TEST_CLIENT_SRC)
	./build/lumos-tests

clean:
	rm -rf build
