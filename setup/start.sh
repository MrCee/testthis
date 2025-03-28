#!/bin/sh

echo "🔄 Starting InvoicePlane container..."

######################################
# 🌍 Load Environment Variables
######################################
if [ -z "$IP_URL" ] || [ -z "$MYSQL_HOST" ]; then
    ENV_INTERNAL="/var/www/html/.env"
    ENV_EXAMPLE="/var/www/html/.env.example"

    if [ -f "$ENV_INTERNAL" ]; then
        echo "📄 Found .env in container: $ENV_INTERNAL"
        set -a
        . "$ENV_INTERNAL"
        set +a
    elif [ -f "$ENV_EXAMPLE" ]; then
        echo "📄 No .env found. Copying from .env.example..."
        cp "$ENV_EXAMPLE" "$ENV_INTERNAL"
        chmod 644 "$ENV_INTERNAL"
        echo "✅ .env created from .env.example"
        set -a
        . "$ENV_INTERNAL"
        set +a
    else
        echo "⚠️ Warning: No .env or .env.example found in container. Environment may be incomplete."
    fi
else
    echo "✅ Environment passed via Docker Compose / host .env — no need to load container-side .env"
fi

######################################
# 🛠️ Ensure ipconfig.php Exists Early
######################################
CONFIG_FILE="/var/www/html/ipconfig.php"
if [ ! -f "$CONFIG_FILE" ]; then
    echo "🛠️ Creating ipconfig.php from template..."
    cp /var/www/html/ipconfig.php.example "$CONFIG_FILE"
    chown www-data:nginx "$CONFIG_FILE"
    chmod 644 "$CONFIG_FILE"
    echo "✅ ipconfig.php created from template"
else
    echo "✅ ipconfig.php found"
fi

######################################
# 👤 Dynamic User Setup (Linux Only)
######################################
echo "🔍 Checking and configuring user:group abc:abc..."
PUID=${PUID:-911}
PGID=${PGID:-911}
HOST_OS=${HOST_OS:-linux}

if [ "$HOST_OS" != "macos" ]; then
    echo "⚙️ Setting up abc:abc with UID=$PUID and GID=$PGID"
    getent group abc >/dev/null || groupadd -g "$PGID" abc
    id abc >/dev/null 2>&1 || useradd -M -s /bin/false -u "$PUID" -g abc abc
    usermod -o -u "$PUID" abc
    groupmod -o -g "$PGID" abc
else
    echo "ℹ️ macOS detected, skipping user modification."
fi

######################################
# ♻️ Restore Application Directories
######################################
copy_directory_if_empty() {
    local source="$1"
    local target="$2"
    if [ ! -d "$target" ]; then
        echo "📁 Creating directory from $source → $target"
        cp -r "$source" "$target"
    elif [ -z "$(ls -A "$target")" ]; then
        echo "📁 Populating empty directory: $target"
        cp -r "$source"/* "$target"/
    else
        echo "✅ $target already populated"
    fi
}

copy_file_if_missing() {
    local source="$1"
    local target="$2"
    if [ ! -f "$target" ]; then
        cp "$source" "$target"
        echo "📄 Copied $(basename "$target")"
    fi
}

copy_language_directory_preserve_custom() {
    local source="/var/www/html_default/application/language/${IP_LANGUAGE}"
    local target="/var/www/html/application/language/${IP_LANGUAGE}"
    echo "🌐 Syncing language files from $source → $target"
    mkdir -p "$target"
    for file in "$source"/*; do
        base=$(basename "$file")
        if [ "$base" = "custom_lang.php" ] && [ -f "$target/$base" ]; then
            echo "⏩ Skipping $base"
        else
            copy_file_if_missing "$file" "$target/$base"
        fi
    done
}

copy_directory_if_empty "/var/www/html_default/uploads" "/var/www/html/uploads"
copy_directory_if_empty "/var/www/html_default/assets/core/css" "/var/www/html/assets/core/css"
copy_directory_if_empty "/var/www/html_default/application/views" "/var/www/html/application/views"
copy_language_directory_preserve_custom

######################################
# 🔐 Fix Permissions
######################################
echo "🔐 Adjusting ownership and permissions..."
OWN_DIRS="/var/www/html/uploads /var/www/html/assets/core/css /var/www/html/application/views /var/www/html/application/language/${IP_LANGUAGE}"

if [ "$HOST_OS" = "macos" ]; then
    echo "🔧 macOS detected: skipping chown"
else
    for dir in $OWN_DIRS; do
        if [ -d "$dir" ]; then
            chown -R abc:abc "$dir"
            chmod -R 775 "$dir"
            echo "🔧 Applied 775 and chown to $dir"
        fi
    done
fi

chmod -R 777 /var/www/html/application/logs
chmod -R 777 /var/www/html/application/cache

######################################
# 🧾 Update ipconfig.php from ENV
######################################
update_config() {
    local key="$1"
    local value="$2"
    if grep -q "^$key=" "$CONFIG_FILE"; then
        sed -i "s|^$key=.*|$key=$value|" "$CONFIG_FILE"
        echo "🔧 Updated $key=$value in ipconfig.php"
    else
        echo "⚠️ $key not found in ipconfig.php"
    fi
}

[ -n "$IP_URL" ] && update_config "IP_URL" "$IP_URL"
[ -n "$ENABLE_DEBUG" ] && update_config "ENABLE_DEBUG" "$ENABLE_DEBUG"
[ -n "$DISABLE_SETUP" ] && update_config "DISABLE_SETUP" "$DISABLE_SETUP"
[ -n "$REMOVE_INDEXPHP" ] && update_config "REMOVE_INDEXPHP" "$REMOVE_INDEXPHP"
[ -n "$MYSQL_HOST" ] && update_config "DB_HOSTNAME" "$MYSQL_HOST"
[ -n "$MYSQL_USER" ] && update_config "DB_USERNAME" "$MYSQL_USER"
[ -n "$MYSQL_PASSWORD" ] && update_config "DB_PASSWORD" "$MYSQL_PASSWORD"
[ -n "$MYSQL_DB" ] && update_config "DB_DATABASE" "$MYSQL_DB"
[ -n "$MYSQL_PORT" ] && update_config "DB_PORT" "$MYSQL_PORT"
[ -n "$SESS_EXPIRATION" ] && update_config "SESS_EXPIRATION" "$SESS_EXPIRATION"
[ -n "$SESS_MATCH_IP" ] && update_config "SESS_MATCH_IP" "$SESS_MATCH_IP"
[ -n "$ENABLE_INVOICE_DELETION" ] && update_config "ENABLE_INVOICE_DELETION" "$ENABLE_INVOICE_DELETION"
[ -n "$DISABLE_READ_ONLY" ] && update_config "DISABLE_READ_ONLY" "$DISABLE_READ_ONLY"

if [ -n "$SETUP_COMPLETED" ] && [ -n "$ENCRYPTION_KEY" ]; then
    echo "🔑 Finalizing setup config..."
    update_config "ENCRYPTION_KEY" "$ENCRYPTION_KEY"
    [ -n "$ENCRYPTION_CIPHER" ] && update_config "ENCRYPTION_CIPHER" "$ENCRYPTION_CIPHER"
    update_config "SETUP_COMPLETED" "$SETUP_COMPLETED"
fi

######################################
# ⏳ Wait for DB & Launch Services
######################################
echo "⏳ Waiting for the database to be available..."
/usr/local/bin/wait-for-db.sh

echo "🚀 Starting PHP-FPM..."
php-fpm --daemonize
sleep 2

echo "🌍 Starting Nginx..."
exec nginx -g "daemon off;"


