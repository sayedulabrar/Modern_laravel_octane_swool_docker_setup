# =============================================================================
# PHP 8.3 + Swoole + Laravel Octane Development Image
# =============================================================================
FROM php:8.3-cli-alpine

# System libraries
RUN apk add --no-cache \
        bash \
        curl \
        git \
        libpng-dev \
        libjpeg-turbo-dev \
        libwebp-dev \
        freetype-dev \
        libzip-dev \
        oniguruma-dev \
        icu-dev \
        linux-headers \
        supervisor \
        mysql-client

# PHP extensions
RUN docker-php-ext-configure gd \
        --with-freetype \
        --with-jpeg \
        --with-webp \
    && docker-php-ext-install -j"$(nproc)" \
        bcmath \
        gd \
        intl \
        mbstring \
        opcache \
        pcntl \
        pdo_mysql \
        zip \
        sockets

# Install Swoole + Redis (with all required build deps)
RUN apk add --no-cache --virtual .build-deps \
        autoconf \
        gcc \
        g++ \
        make \
        pkgconf \
        linux-headers \
        openssl-dev \
    && pecl install swoole redis \
    && docker-php-ext-enable swoole redis \
    && echo "swoole.use_shortname='Off'" > /usr/local/etc/php/conf.d/swoole.ini \
    && apk del .build-deps

# Composer
COPY --from=composer:2.7 /usr/bin/composer /usr/bin/composer

# PHP configuration
COPY docker/php/php.ini        /usr/local/etc/php/conf.d/99-custom.ini
COPY docker/php/opcache.ini    /usr/local/etc/php/conf.d/99-opcache.ini

# Application directory
WORKDIR /var/www/html

# Supervisor config
COPY docker/supervisor/supervisord.conf /etc/supervisord.conf

# Entrypoint
COPY docker/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# Non-root user
RUN addgroup -g 1000 www \
    && adduser -u 1000 -G www -s /bin/bash -D www \
    && chown -R www:www /var/www/html

USER www

EXPOSE 8000

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["/usr/bin/supervisord", "-n", "-c", "/etc/supervisord.conf"]