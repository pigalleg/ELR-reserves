#!/bin/bash

# Energy Reserve Project Copy Script
# 
# This script creates a copy of the energy reserve project to a new location,
# excluding version control history and output files.
#
# Usage: ./copy_project.sh <destination_path>
#
# Example: ./copy_project.sh /path/to/new_project_copy

set -e  # Exit on error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to print colored messages
print_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

# Check if destination is provided
if [ $# -eq 0 ]; then
    print_error "No destination path provided"
    echo "Usage: $0 <destination_path>"
    echo "Example: $0 /path/to/new_project_copy"
    exit 1
fi

DEST_PATH="$1"
SOURCE_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Convert relative paths to absolute paths
if [[ "$DEST_PATH" != /* ]]; then
    # Special handling for . and ..
    if [ "$DEST_PATH" = "." ]; then
        DEST_PATH="$PWD"
    elif [ "$DEST_PATH" = ".." ]; then
        DEST_PATH="$(cd .. && pwd)"
    else
        # For other relative paths, resolve to absolute
        DEST_PATH="$(cd "$(dirname "$DEST_PATH")" 2>/dev/null && pwd)/$(basename "$DEST_PATH")" || DEST_PATH="$PWD/$DEST_PATH"
    fi
fi

print_info "Source project: $SOURCE_PATH"
print_info "Destination: $DEST_PATH"

# Validate destination path to prevent dangerous operations
if [ -z "$DEST_PATH" ] || [ "$DEST_PATH" = "/" ] || [ "$DEST_PATH" = "$HOME" ] || [ "$DEST_PATH" = "$PWD" ] || [ "$DEST_PATH" = "$SOURCE_PATH" ]; then
    print_error "Invalid destination path: '$DEST_PATH'"
    print_error "Cannot use empty, root, home, current, or source directory as destination"
    exit 1
fi

# Check if destination already exists
if [ -d "$DEST_PATH" ]; then
    print_error "Destination directory already exists: $DEST_PATH"
    
    # Check if it looks like a previous project copy (has main.jl and Project.toml)
    if [ -f "$DEST_PATH/main.jl" ] && [ -f "$DEST_PATH/Project.toml" ]; then
        print_warning "Directory appears to be a previous project copy"
    else
        print_warning "Directory does NOT appear to be a project copy"
    fi
    
    read -p "Are you sure you want to PERMANENTLY DELETE this directory? (yes/N): " -r
    echo
    if [[ ! $REPLY =~ ^[Yy][Ee][Ss]$ ]]; then
        print_info "Operation cancelled"
        exit 1
    fi
    
    print_warning "Removing existing directory..."
    rm -rf "$DEST_PATH"
fi

# Create destination directory
print_info "Creating destination directory..."
mkdir -p "$DEST_PATH"

# Copy project files excluding .git and output directories
print_info "Copying project files..."

# Use rsync for efficient copying with exclusions
if command -v rsync &> /dev/null; then
    rsync -av \
        --exclude='.git' \
        --exclude='output/*' \
        --exclude='*.swp' \
        --exclude='*.swo' \
        --exclude='*~' \
        --exclude='.DS_Store' \
        "$SOURCE_PATH/" "$DEST_PATH/"
else
    # Fallback to cp with manual exclusions
    print_warning "rsync not found, using cp (slower)"
    
    # Copy all files except excluded ones (matching rsync exclusions)
    # First copy everything except .git and output
    # Using -exec {} + for better performance and security
    find "$SOURCE_PATH" -mindepth 1 -maxdepth 1 ! -name '.git' ! -name 'output' -exec cp -r {} "$DEST_PATH/" +
    
    # Remove temporary editor files and OS-specific files
    find "$DEST_PATH" -type f \( -name '*.swp' -o -name '*.swo' -o -name '*~' -o -name '.DS_Store' \) -delete 2>/dev/null || true
fi

# Create empty output directory in destination
print_info "Creating empty output directory..."
mkdir -p "$DEST_PATH/output"

# Set permissions
print_info "Setting permissions..."
if [ -d "$DEST_PATH/scripts" ]; then
    # Using -exec {} + for better performance and security
    find "$DEST_PATH/scripts" -type f -name "*.sh" -exec chmod +x {} + 2>/dev/null || true
fi

# Verify copy
print_info "Verifying copy..."
if [ -f "$DEST_PATH/main.jl" ] && [ -f "$DEST_PATH/Project.toml" ]; then
    print_info "Copy completed successfully!"
    echo ""
    echo "Project copied to: $DEST_PATH"
    echo ""
    echo "To use the copied project:"
    echo "  1. cd $DEST_PATH"
    echo "  2. julia --project=."
    echo "  3. In Julia REPL: using Pkg; Pkg.instantiate()"
    echo "  4. include(\"main.jl\")"
    echo ""
    print_info "Note: You may need to reconfigure input/output paths in your scripts"
else
    print_error "Copy verification failed - essential files missing"
    exit 1
fi

exit 0
