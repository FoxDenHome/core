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
# The tray is `foxden-vpnd tray`; foxden-vpn-tray is a link for older
# autostart entries, and for trays from before that, which restart into it.
install-linux: all
	install -Dm755 $(BIN)/foxden-vpnd -t $(PREFIX)/bin/
	ln -sfn foxden-vpnd $(PREFIX)/bin/foxden-vpn-tray
	install -Dm644 packaging/linux/foxden-vpnd.service /etc/systemd/system/foxden-vpnd.service
	install -Dm644 packaging/linux/foxden-vpn-tray.desktop /etc/xdg/autostart/foxden-vpn-tray.desktop
	systemctl daemon-reload
	systemctl enable foxden-vpnd
	# Restart even if running: trays follow the daemon's build.
	systemctl restart foxden-vpnd

# macOS: build on a Mac (the tray needs cgo against AppKit). One universal
# binary, inside the app bundle: the tray must run from there to stay out of
# the Dock, and daemon and tray are the same binary.
macos:
	mkdir -p "$(APP)/Contents/MacOS"
	for arch in arm64 amd64; do \
		GOARCH=$$arch CGO_ENABLED=1 go build -o $(BIN)/foxden-vpnd-$$arch ./cmd/foxden-vpnd || exit 1; \
	done
	lipo -create -output "$(APP)/Contents/MacOS/foxden-vpnd" $(BIN)/foxden-vpnd-arm64 $(BIN)/foxden-vpnd-amd64
	cp packaging/macos/Info.plist "$(APP)/Contents/Info.plist"

install-macos: macos
	install -d $(PREFIX)/bin
	rm -rf "/Applications/FoxDen VPN.app" && cp -R "$(APP)" /Applications/
	ln -sfn "/Applications/FoxDen VPN.app/Contents/MacOS/foxden-vpnd" $(PREFIX)/bin/foxden-vpnd
	install -m644 packaging/macos/network.foxden.vpnd.plist /Library/LaunchDaemons/
	install -m644 packaging/macos/network.foxden.vpn-tray.plist /Library/LaunchAgents/
	launchctl bootstrap system /Library/LaunchDaemons/network.foxden.vpnd.plist || launchctl kickstart -k system/network.foxden.vpnd

clean:
	rm -rf $(BIN)
