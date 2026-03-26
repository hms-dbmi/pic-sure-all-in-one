#!/bin/bash

# Jenkins Build History Migration Script
# This script copies build history from old jenkins_home to new jenkins_home

set -e  # Exit on error

# Configuration
OLD_JENKINS_HOME="${1:-./old_jenkins_home}"
NEW_JENKINS_HOME="${2:-./jenkins_home}"
BACKUP_DIR="${3:-./jenkins_home_backup_$(date +%Y%m%d_%H%M%S)}"

echo "=== Jenkins Build History Migration ==="
echo "Old Jenkins Home: $OLD_JENKINS_HOME"
echo "New Jenkins Home: $NEW_JENKINS_HOME"
echo "Backup Directory: $BACKUP_DIR"
echo ""

# Validate directories
if [ ! -d "$OLD_JENKINS_HOME" ]; then
    echo "Error: Old Jenkins home directory does not exist: $OLD_JENKINS_HOME"
    exit 1
fi

if [ ! -d "$NEW_JENKINS_HOME" ]; then
    echo "Error: New Jenkins home directory does not exist: $NEW_JENKINS_HOME"
    exit 1
fi

# Create backup of current jenkins_home
echo "Creating backup of current jenkins_home..."
cp -r "$NEW_JENKINS_HOME" "$BACKUP_DIR"
echo "Backup created at: $BACKUP_DIR"
echo ""

# Process each job in old jenkins_home
echo "Migrating build histories..."
OLD_JOBS_DIR="$OLD_JENKINS_HOME/jobs"
NEW_JOBS_DIR="$NEW_JENKINS_HOME/jobs"

if [ ! -d "$OLD_JOBS_DIR" ]; then
    echo "Warning: No jobs directory found in old jenkins_home"
    exit 0
fi

migrated_count=0
skipped_count=0

# Loop through each job in old jenkins_home
for old_job_dir in "$OLD_JOBS_DIR"/*; do
    if [ ! -d "$old_job_dir" ]; then
        continue
    fi
    
    job_name=$(basename "$old_job_dir")
    new_job_dir="$NEW_JOBS_DIR/$job_name"
    old_builds_dir="$old_job_dir/builds"
    new_builds_dir="$new_job_dir/builds"
    
    # Check if this job exists in new jenkins_home
    if [ -d "$new_job_dir" ]; then
        # Check if builds directory exists in old job
        if [ -d "$old_builds_dir" ]; then
            echo "Migrating builds for job: $job_name"
            
            # Create builds directory in new job if it doesn't exist
            mkdir -p "$new_builds_dir"
            
            # Copy all build history
            cp -r "$old_builds_dir"/* "$new_builds_dir/" 2>/dev/null || true
            
            # Also copy nextBuildNumber if it exists to preserve build numbering
            if [ -f "$old_job_dir/nextBuildNumber" ]; then
                cp "$old_job_dir/nextBuildNumber" "$new_job_dir/"
            fi
            
            migrated_count=$((migrated_count + 1))
        else
            echo "Skipping job '$job_name': No builds directory in old job"
            skipped_count=$((skipped_count + 1))
        fi
    else
        echo "Skipping job '$job_name': Does not exist in new jenkins_home"
        skipped_count=$((skipped_count + 1))
    fi
done

echo ""
echo "=== Migration Complete ==="
echo "Jobs migrated: $migrated_count"
echo "Jobs skipped: $skipped_count"
echo "Backup location: $BACKUP_DIR"
echo ""
echo "Next steps:"
echo "1. Restart your Jenkins Docker container"
echo "2. Verify that build history appears correctly"
echo "3. If everything looks good, you can delete the backup: $BACKUP_DIR"