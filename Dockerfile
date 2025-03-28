# --------------------------------------------
# Stage 0: Base Setup for Runtime Environment
# --------------------------------------------
ARG PHP_VERSION=8.4
FROM php:${PHP_VERSION}-fpm-alpine AS base

# Build arguments
ARG IP_VERSION
ARG IP_SOURCE
ARG IP_LANGUAGE
ARG IP_IMAGE
ARG PUID
ARG PGID
ARG BUILD_DATE

# Set ENV for later stages (if needed)
ENV PHP_VERSION=${PHP_VERSION} \
    IP_VERSION=${IP_VERSION} \
    IP_SOURCE=${IP_SOURCE} \
    IP_LANGUAGE=${IP_LANGUAGE} \
    IP_IMAGE=${IP_IMAGE} \
    PUID=${PUID} \
    PGID=${PGID} \
    TMPDIR=/var/tmp \
    BUILD_DATE=${BUILD_DATE}

# OCI Labels
LABEL org.opencontainers.image.authors="MrCee" \
      org.opencontainers.image.title="InvoicePlane DockerX" \
      org.opencontainers.image.description="Dockerized, production-ready, multi-arch InvoicePlane (patched for PHP ${PHP_VERSION})" \
      org.opencontainers.image.url="https://github.com/MrCee/InvoicePlane-DockerX" \
      org.opencontainers.image.source="https://github.com/MrCee/InvoicePlane-DockerX" \
      org.opencontainers.image.documentation="https://github.com/MrCee/InvoicePlane-DockerX/blob/main/README.md" \
      org.opencontainers.image.version="${IP_VERSION}" \
      org.opencontainers.image.created="${BUILD_DATE}" \
      org.opencontainers.image.ref.name="${IP_IMAGE}:${IP_VERSION}" \
      org.opencontainers.image.licenses="MIT"

# Install runtime dependencies
RUN apk add --no-cache \
      patch \
      nginx \
      mariadb-client \
      shadow \
      vim \
      libwebp \
      libpng \
      freetype \
      libjpeg-turbo \
      icu-libs \
      oniguruma \
      libxml2 \
      libxslt \
      libxpm

# Install build dependencies for PHP extensions
RUN apk add --no-cache --virtual .build-deps \
      unzip build-base linux-headers autoconf file g++ gcc libc-dev make \
      pkgconf re2c binutils zlib-dev libtool automake \
      freetype-dev libjpeg-turbo-dev libwebp-dev libpng-dev \
      icu-dev oniguruma-dev libxml2-dev libxslt-dev libxpm-dev \
  && docker-php-ext-configure gd \
        --enable-gd --with-freetype --with-jpeg --with-webp --with-xpm --enable-gd-jis-conv \
  && docker-php-ext-install -j$(nproc) gd intl bcmath dom mysqli \
  && apk del .build-deps \
  && rm -rf /var/cache/apk/* /tmp/* /usr/src/php*

RUN mkdir -p /var/tmp && chmod 1777 /var/tmp


# --------------------------------------------
# Stage 1: Composer Dependencies
# --------------------------------------------
FROM base AS composer-builder

COPY composer.json composer.lock /build/
RUN curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer \
  && cd /build && composer install --no-dev --optimize-autoloader


# --------------------------------------------
# Stage 2: Final Runtime Image
# --------------------------------------------
FROM base

# Setup configurations
COPY setup/php.ini /usr/local/etc/php/php.ini
COPY setup/php-fpm.conf /usr/local/etc/php-fpm.d/www.conf
COPY setup/nginx.conf /etc/nginx/nginx.conf
COPY setup/default.conf /etc/nginx/http.d/default.conf
COPY setup/start.sh /usr/local/bin/start.sh
COPY setup/wait-for-db.sh /usr/local/bin/wait-for-db.sh
RUN chmod +x /usr/local/bin/start.sh /usr/local/bin/wait-for-db.sh

# Disable default docker PHP FPM config
RUN mv /usr/local/etc/php-fpm.d/zz-docker.conf /usr/local/etc/php-fpm.d/zz-docker.disabled || true \
  && mkdir -p /run/php && chown -R www-data:nginx /run/php && chmod 770 /run/php

# Download & extract InvoicePlane
RUN mkdir -p /var/www/html /var/www/html_default && \
    VERSION=$(echo ${IP_VERSION} | grep -q '^v' && echo ${IP_VERSION} || echo "v${IP_VERSION}") && \
    curl -L ${IP_SOURCE}/${VERSION}/${VERSION}.zip -o /tmp/app.zip && \
    unzip /tmp/app.zip -d /tmp && \
    cp -a /tmp/ip/. /var/www/html && \
    cp -a /tmp/ip/. /var/www/html_default && \
    rm -rf /tmp/app.zip /tmp/ip

# Copy in Composer vendor dependencies from builder
COPY --from=composer-builder /build/vendor /var/www/html/vendor

# Apply patches
COPY patches /tmp/patches
RUN if [ -d /tmp/patches ] && [ "$(ls -A /tmp/patches)" ]; then \
      echo "🩹 Applying patches from /tmp/patches..."; \
      cd /var/www/html && \
      for patch in /tmp/patches/*.patch; do \
        echo "🔧 Applying $patch..."; \
        patch -p1 --batch --forward < "$patch" || echo "⚠️ Failed to apply $patch (might be already applied or file missing)"; \
      done; \
    fi && rm -rf /tmp/patches

# Copy fallback .env (used if user doesn't mount one)
COPY .env.example /var/www/html/.env.example

EXPOSE 80

ENTRYPOINT ["/usr/local/bin/start.sh"]
CMD ["nginx", "-g", "daemon off;"]



