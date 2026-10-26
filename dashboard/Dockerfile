FROM --platform=${BUILDPLATFORM:-linux/amd64} git.foxden.network/mirror/oci-images/golang:1-alpine AS builder

ARG TARGETOS
ARG TARGETARCH

ENV CGO_ENABLED=0
ENV GOOS=${TARGETOS}
ENV GOARCH=${TARGETARCH}

WORKDIR /src
COPY go.mod go.sum /src/
RUN go mod download

COPY . /src
RUN go build -ldflags="-s -w" -trimpath -o /foxden-dashboard ./cmd/foxden-dashboard

FROM scratch AS default
EXPOSE 8080
ENV CONFIG_FILE=/config/config.json
COPY --from=builder /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
COPY --from=builder /foxden-dashboard /foxden-dashboard
ENTRYPOINT [ "/foxden-dashboard" ]
