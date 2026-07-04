<?php

namespace App\Service;

final class ShortUrlBuilder
{
    public function __construct(
        private readonly string $shortUrlBase
    ) {
    }

    public function build(string $shortCode): string
    {
        return sprintf('%s/%s', rtrim($this->shortUrlBase, '/'), $shortCode);
    }
}
