.PHONY: all build test clean

all: build

build:
	CGO_ENABLED=0 go build -ldflags="-s -w" -trimpath -o bin/ ./cmd/...

# Set SHARKD to Wireshark's sharkd to include the end-to-end session test
test:
	go vet ./...
	go test ./...

clean:
	rm -rf bin
