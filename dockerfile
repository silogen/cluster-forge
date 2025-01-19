# Use a minimal base image
FROM alpine:latest

# Create a directory in the image
WORKDIR /prepopulated

# Copy all files from the host's "data" directory into the image
COPY stacks/latest/ /prepopulated/

# Set default command to copy data to the mounted volume
ENTRYPOINT ["/bin/sh"]