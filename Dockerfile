FROM php:8.2-fpm-alpine

RUN apk add --no-cache \
        $PHPIZE_DEPS \
        bash \
        curl \
        icu-dev \
        libxml2-dev \
        linux-headers \
        postgresql-dev \
        rabbitmq-c-dev \
        unzip \
        git \
    && docker-php-ext-install pdo pdo_pgsql intl xml \
    && pecl install amqp \
    && docker-php-ext-enable amqp \
    && php -r "copy('https://getcomposer.org/installer', 'composer-setup.php');" \
    && php composer-setup.php --install-dir=/usr/local/bin --filename=composer \
    && rm composer-setup.php

WORKDIR /var/www/app

CMD ["php-fpm"]
