#!/bin/bash

# Script to install AMD MITM certificates for Docker builds
# Creates custom base images with certificates pre-installed

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "🔧 Installing AMD certificates for Docker builds..."
echo ""

# Step 1: Install certificates in Colima VM
echo "📦 Installing AMD certificates in Colima VM..."
cat "$SCRIPT_DIR/certs/AMD_ROOT.crt" | colima ssh -- sudo tee /usr/local/share/ca-certificates/AMD_ROOT.crt >/dev/null
cat "$SCRIPT_DIR/certs/AMD_ISSUER.crt" | colima ssh -- sudo tee /usr/local/share/ca-certificates/AMD_ISSUER.crt >/dev/null  
cat "$SCRIPT_DIR/certs/AMD_COMBINED.crt" | colima ssh -- sudo tee /usr/local/share/ca-certificates/AMD_COMBINED.crt >/dev/null
colima ssh -- sudo update-ca-certificates --fresh >/dev/null 2>&1
echo "   ✅ VM certificates installed"
echo ""

# Step 2: Build custom base images with certificates
echo "🐳 Building custom base images with AMD certificates..."
mkdir -p "$SCRIPT_DIR/base-images"

# Python 3.13 base image
cat > "$SCRIPT_DIR/base-images/Dockerfile.python" <<'EOF'
FROM python:3.13
COPY certs/*.crt /usr/local/share/ca-certificates/
RUN update-ca-certificates && \
    chmod 644 /etc/ssl/certs/ca-certificates.crt
EOF

# Alpine base image  
cat > "$SCRIPT_DIR/base-images/Dockerfile.alpine" <<'EOF'
FROM alpine:3.21
COPY certs/*.crt /usr/local/share/ca-certificates/
RUN cat /usr/local/share/ca-certificates/*.crt >> /etc/ssl/certs/ca-certificates.crt
EOF

# Node Alpine base image
cat > "$SCRIPT_DIR/base-images/Dockerfile.node" <<'EOF'
FROM node:22-alpine
COPY certs/*.crt /usr/local/share/ca-certificates/
RUN cat /usr/local/share/ca-certificates/*.crt >> /etc/ssl/certs/ca-certificates.crt
EOF

echo "   Building python:3.13 with AMD certs..."
docker build -q -f "$SCRIPT_DIR/base-images/Dockerfile.python" -t python:3.13 "$SCRIPT_DIR" >/dev/null

echo "   Building alpine:3.21 with AMD certs..."
docker build -q -f "$SCRIPT_DIR/base-images/Dockerfile.alpine" -t alpine:3.21 "$SCRIPT_DIR" >/dev/null

echo "   Building node:22-alpine with AMD certs..."
docker build -q -f "$SCRIPT_DIR/base-images/Dockerfile.node" -t node:22-alpine "$SCRIPT_DIR" >/dev/null

# Also tag with SHA for ui.Dockerfile compatibility
docker tag node:22-alpine node:22-alpine@sha256:dbcedd8aeab47fbc0f4dd4bfga55b7c3c729a707875968d467aaaea42d6225af 2>/dev/null || true

echo "   ✅ Custom base images built"
echo ""
echo "✅ Done! Your Dockerfiles will now work with AMD MITM proxy."
echo ""
echo "ℹ️  Base images replaced: python:3.13, alpine:3.21, node:22-alpine"
echo "   Run this script again after Colima restarts."
