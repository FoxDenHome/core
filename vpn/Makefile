PREFIX ?= /usr/local
BIN := bin
APP := $(BIN)/FoxDen VPN.app

.PHONY: all test linux install-linux macos install-macos clean

all:
	go build -o $(BIN)/ ./cmd/...

test:
	go vet ./...
	go test ./...

# Linux: kernel WireGuard when available, wireguard-go otherwise.
install-linux: all
	install -Dm755 $(BIN)/foxden-vpnd $(BIN)/foxden-vpn-tray -t $(PREFIX)/bin/
	install -Dm644 packaging/linux/foxden-vpnd.service /etc/systemd/system/foxden-vpnd.service
	install -Dm644 packaging/linux/foxden-vpn-tray.desktop /etc/xdg/autostart/foxden-vpn-tray.desktop
	systemctl daemon-reload
	systemctl enable foxden-vpnd
	# Restart even if running: a new daemon build makes running trays update too.
	systemctl restart foxden-vpnd

# macOS: build on a Mac (the tray needs cgo against AppKit). Universal binaries.
macos:
	mkdir -p "$(APP)/Contents/MacOS"
	for arch in arm64 amd64; do \
		GOARCH=$$arch CGO_ENABLED=1 go build -o $(BIN)/foxden-vpnd-$$arch ./cmd/foxden-vpnd && \
		GOARCH=$$arch CGO_ENABLED=1 go build -o $(BIN)/foxden-vpn-tray-$$arch ./cmd/foxden-vpn-tray || exit 1; \
	done
	lipo -create -output $(BIN)/foxden-vpnd $(BIN)/foxden-vpnd-arm64 $(BIN)/foxden-vpnd-amd64
	lipo -create -output "$(APP)/Contents/MacOS/foxden-vpn-tray" $(BIN)/foxden-vpn-tray-arm64 $(BIN)/foxden-vpn-tray-amd64
	cp packaging/macos/Info.plist "$(APP)/Contents/Info.plist"

install-macos: macos
	install -d $(PREFIX)/bin
	install -m755 $(BIN)/foxden-vpnd $(PREFIX)/bin/
	rm -rf "/Applications/FoxDen VPN.app" && cp -R "$(APP)" /Applications/
	install -m644 packaging/macos/network.foxden.vpnd.plist /Library/LaunchDaemons/
	install -m644 packaging/macos/network.foxden.vpn-tray.plist /Library/LaunchAgents/
	launchctl bootstrap system /Library/LaunchDaemons/network.foxden.vpnd.plist || launchctl kickstart -k system/network.foxden.vpnd

clean:
	rm -rf $(BIN)
