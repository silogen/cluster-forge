# syntax=docker/dockerfile:1
FROM golang:1.23 AS gobuilder
WORKDIR /src
COPY . /src

# Download dependencies
RUN go mod download

# Build the project
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -a -tags netgo -ldflags '-extldflags "-static"' -o /forge /src/main.go

# Use a base Alpine image
FROM alpine:latest AS builder

# Install necessary tools (curl, git, bash)
RUN apk add --no-cache --no-check-certificate curl git bash

# Install kubectl
RUN set -e; \
    # Fetch the latest stable version tag from kubernetes
    KUBECTL_VERSION=$(curl -k -L -s https://dl.k8s.io/release/stable.txt); \
    echo "Latest kubectl version: ${KUBECTL_VERSION}"; \
    # Download kubectl binary from the correct URL
    curl -kLO "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl"; \
    # Check if kubectl is not empty or corrupted
    if [ ! -s kubectl ]; then \
        echo "Download failed: kubectl binary is empty or corrupted."; exit 1; \
    fi; \
    # Make it executable and move it to a system path
    chmod +x kubectl; \
    mv kubectl /usr/local/bin/kubectl;

RUN set -e; \
    # Fetch the latest stable version tag from Helm
    HELM_VERSION=$(curl -s https://api.github.com/repos/helm/helm/releases/latest | grep tag_name | cut -d '"' -f 4); \
    echo "Latest Helm version: ${HELM_VERSION}"; \
    # Download Helm binary from the correct URL
    curl -kLO "https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz"; \
    # Extract the Helm binary
    tar -zxvf helm-${HELM_VERSION}-linux-amd64.tar.gz; \
    # Move the Helm binary to a system path
    mv linux-amd64/helm /usr/local/bin/helm; \
    # Clean up
    rm -rf helm-${HELM_VERSION}-linux-amd64.tar.gz linux-amd64;

# Copy the built binary from the gobuilder stage
FROM alpine:latest
COPY --from=builder /usr/local/bin/kubectl /usr/local/bin/kubectl
COPY --from=builder /usr/local/bin/helm /usr/local/bin/helm
COPY --from=gobuilder /forge /usr/local/bin/forge

# Copy the entry script
COPY entry.sh /entry.sh

# Ensure the entry script and binaries are executable
RUN chmod +x /entry.sh /usr/local/bin/forge /usr/local/bin/kubectl /usr/local/bin/helm

# Set ENTRYPOINT to the entry script
ENTRYPOINT ["/entry.sh"]

