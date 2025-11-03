# ============================================
# Dockerfile - {{DOMAIN}}
# Template for PHP-FPM container
# ============================================

FROM php:8.2-fpm-alpine AS builder

RUN apk add --no-cache --virtual .build-deps \
    autoconf gcc g++ make libpng-dev libjpeg-turbo-dev \
    libwebp-dev libzip-dev icu-dev linux-headers

RUN docker-php-ext-configure gd --with-jpeg --with-webp && \
    docker-php-ext-install -j$(nproc) gd mysqli opcache intl zip calendar exif bcmath

RUN pecl install redis && docker-php-ext-enable redis

FROM php:8.2-fpm-alpine

LABEL maintainer="{{DOMAIN}}"
LABEL description="WordPress PHP-FPM container for {{DOMAIN}}"

RUN apk add --no-cache libpng libjpeg-turbo libwebp libzip icu tzdata

COPY --from=builder /usr/local/lib/php/extensions /usr/local/lib/php/extensions
COPY --from=builder /usr/local/etc/php/conf.d/docker-php-ext-*.ini /usr/local/etc/php/conf.d/

COPY php.ini /usr/local/etc/php/conf.d/custom.ini
COPY www.conf /usr/local/etc/php-fpm.d/www.conf

RUN mkdir -p /var/log/php-fpm && chown -R www-data:www-data /var/log/php-fpm

WORKDIR /var/www/html

USER www-data

EXPOSE 9000
CMD ["php-fpm", "-F"]
