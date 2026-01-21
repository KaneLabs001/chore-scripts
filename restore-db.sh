#!/bin/bash
set -o allexport


SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &>/dev/null && pwd )"
source "${SCRIPT_DIR}/.env"

set +o allexport

# Prompt user to select a backup file
echo "Available backup files in current directory:"
ls -1 *.sql 2>/dev/null | nl
echo

read -p "Enter the number corresponding to the backup file you want to restore: " FILE_NUMBER
BACKUP_FILE=$(ls -1 *.sql 2>/dev/null | sed -n "${FILE_NUMBER}p" | xargs)

if [ -z "$BACKUP_FILE" ]; then
  echo "Error: Invalid file selection."
  exit 1
fi

echo
echo "You selected backup file: $BACKUP_FILE"
echo

# Prompt user to select restore target
echo "Select restore target:"
echo "1) Local (Docker container)"
echo "2) Dev server"
echo

read -p "Enter your choice (1 or 2): " TARGET_CHOICE

if [ "$TARGET_CHOICE" == "1" ]; then
  # LOCAL RESTORE
  echo
  echo "Fetching list of running Docker containers..."
  CONTAINER_LIST=$(docker ps --format '{{.Names}}')
  echo "$CONTAINER_LIST" | nl
  echo

  read -p "Enter the number corresponding to the Docker container you want to use: " CONTAINER_NUMBER
  SELECTED_CONTAINER=$(echo "$CONTAINER_LIST" | sed -n "${CONTAINER_NUMBER}p" | xargs)

  if [ -z "$SELECTED_CONTAINER" ]; then
    echo "Error: Invalid container selection."
    exit 1
  fi

  echo
  echo "You selected container: $SELECTED_CONTAINER"
  echo

  read -p "Enter the database name to restore to: " SELECTED_DB

  if [ -z "$SELECTED_DB" ]; then
    echo "Error: Database name cannot be empty."
    exit 1
  fi

  echo
  echo "Restoring to LOCAL database: $SELECTED_DB in container: $SELECTED_CONTAINER"
  echo

  # Drop and create database
  docker exec -e PGPASSWORD=$LOCAL_PASSWORD $SELECTED_CONTAINER psql -U $LOCAL_USER -d postgres -c "DROP DATABASE IF EXISTS $SELECTED_DB;"
  if [ $? -ne 0 ]; then
    echo "Error: Failed to drop the old database $SELECTED_DB in Docker container."
    exit 1
  fi

  echo "Creating new database $SELECTED_DB in Docker container..."
  docker exec -e PGPASSWORD=$LOCAL_PASSWORD $SELECTED_CONTAINER psql -U $LOCAL_USER -d postgres -c "CREATE DATABASE $SELECTED_DB;"
  if [ $? -ne 0 ]; then
    echo "Error: Failed to create the new database $SELECTED_DB in Docker container."
    exit 1
  fi

  # Copy backup file into container
  echo "Copying backup file into Docker container..."
  docker cp $BACKUP_FILE $SELECTED_CONTAINER:/tmp/$BACKUP_FILE
  if [ $? -ne 0 ]; then
    echo "Error: Failed to copy backup file into Docker container."
    exit 1
  fi

  # Restore database
  echo "Restoring database $SELECTED_DB in Docker container..."
  docker exec -e PGPASSWORD=$LOCAL_PASSWORD $SELECTED_CONTAINER psql -U $LOCAL_USER -d $SELECTED_DB -f /tmp/$BACKUP_FILE
  if [ $? -ne 0 ]; then
    echo "Error: Failed to restore database $SELECTED_DB in Docker container."
    exit 1
  fi

  # Cleanup
  echo "Cleaning up backup file in container..."
  docker exec $SELECTED_CONTAINER rm -f /tmp/$BACKUP_FILE

  echo
  echo "Database $SELECTED_DB restored to LOCAL (Docker) successfully!"

elif [ "$TARGET_CHOICE" == "2" ]; then
  # DEV SERVER RESTORE
  echo
  read -p "Enter the database name to restore to on DEV server: " SELECTED_DB

  if [ -z "$SELECTED_DB" ]; then
    echo "Error: Database name cannot be empty."
    exit 1
  fi

  echo
  echo "Restoring to DEV database: $SELECTED_DB at $DEVELOP_HOST:$DEVELOP_PORT"
  echo

  # Drop and create database on dev server using Docker container
  echo "Dropping old database $SELECTED_DB on dev server..."
  docker run --rm \
    -e PGPASSWORD=$DEVELOP_PASSWORD \
    --network host \
    postgis/postgis:15-3.3 \
    psql -h $DEVELOP_HOST -p $DEVELOP_PORT -U $DEVELOP_USER -d postgres -c "DROP DATABASE IF EXISTS $SELECTED_DB;"
  if [ $? -ne 0 ]; then
    echo "Error: Failed to drop the old database $SELECTED_DB on dev server."
    exit 1
  fi

  echo "Creating new database $SELECTED_DB on dev server..."
  docker run --rm \
    -e PGPASSWORD=$DEVELOP_PASSWORD \
    --network host \
    postgis/postgis:15-3.3 \
    psql -h $DEVELOP_HOST -p $DEVELOP_PORT -U $DEVELOP_USER -d postgres -c "CREATE DATABASE $SELECTED_DB;"
  if [ $? -ne 0 ]; then
    echo "Error: Failed to create the new database $SELECTED_DB on dev server."
    exit 1
  fi

  # Restore database on dev server using Docker container
  echo "Restoring database $SELECTED_DB on dev server..."
  docker run --rm \
    -e PGPASSWORD=$DEVELOP_PASSWORD \
    --network host \
    -v "$(pwd)/$BACKUP_FILE:/tmp/$BACKUP_FILE" \
    postgis/postgis:15-3.3 \
    psql -h $DEVELOP_HOST -p $DEVELOP_PORT -U $DEVELOP_USER -d $SELECTED_DB -f /tmp/$BACKUP_FILE
  if [ $? -ne 0 ]; then
    echo "Error: Failed to restore database $SELECTED_DB on dev server."
    exit 1
  fi

  echo
  echo "Database $SELECTED_DB restored to DEV server successfully!"

else
  echo "Error: Invalid choice. Please select 1 or 2."
  exit 1
fi
