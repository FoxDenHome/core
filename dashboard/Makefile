.PHONY: all build test run clean

all: build

build:
	CGO_ENABLED=0 go build -ldflags="-s -w" -trimpath -o bin/foxden-dashboard ./cmd/foxden-dashboard

test:
	go vet ./...
	go test ./...

run: build
	./bin/foxden-dashboard -config config.json

clean:
	rm -rf bin
