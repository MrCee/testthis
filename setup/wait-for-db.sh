#!/bin/sh
set -e

echo "⏳ Waiting for MariaDB to be ready. Timeout set to 3 minutes."
TIMEOUT=180  # Timeout in seconds
START_TIME=$(date +%s)

echo "🔍 Trying to connect to MariaDB at ${MYSQL_HOST}:${MYSQL_PORT} with user ${MYSQL_USER}"

# Check if required environment variables are set
if [ -z "$MYSQL_HOST" ] || [ -z "$MYSQL_USER" ] || [ -z "$MYSQL_PASSWORD" ]; then
    echo "❌ ERROR: Missing required environment variables (MYSQL_HOST, MYSQL_USER, MYSQL_PASSWORD)."
    exit 1
fi

# Keep checking until MariaDB responds or timeout occurs
while ! /usr/bin/mariadb --host="${MYSQL_HOST}" --port="${MYSQL_PORT}" --user="${MYSQL_USER}" --password="${MYSQL_PASSWORD}" --protocol=TCP --ssl=0 --silent -e "SELECT 1;" >/dev/null 2>&1; do
    sleep 2
    echo "🔄 Waiting for database connection..."

    CURRENT_TIME=$(date +%s)
    ELAPSED=$(( CURRENT_TIME - START_TIME ))
    if [ "$ELAPSED" -ge "$TIMEOUT" ]; then
        echo "❌ ERROR: Timed out waiting for MariaDB after ${TIMEOUT} seconds."
        echo "⚠️ Please check your database connection settings and ensure MariaDB is running."
        exit 1
    fi
done

echo "✅ MariaDB is ready. Starting InvoicePlane..."
echo "🚀 SETUP COMPLETE..."
echo "========================================================================"
echo "📜 Setup logs will now print to stdout below."
echo "ℹ️ Press CONTROL + C to stop log output after nginx has started."
echo "You can now login to InvoicePlane-DockerX here: ${IP_URL}" 
echo "========================================================================"

exec "$@"
