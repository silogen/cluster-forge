FROM golang:1.24 AS builder
WORKDIR /app

COPY go.mod go.sum ./
COPY grpc-authz-adapter.go .

RUN GOARCH=amd64 go build -o /authz-adapter grpc-authz-adapter.go

FROM gcr.io/distroless/base-debian12
COPY --from=builder /authz-adapter /authz-adapter
CMD ["/authz-adapter"]
