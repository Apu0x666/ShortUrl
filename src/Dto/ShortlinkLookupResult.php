<?php

namespace App\Dto;

final class ShortlinkLookupResult
{
    public function __construct(
        private readonly string $status,
        private readonly string $originalUrl,
        private readonly ?string $shortCode = null,
        private readonly ?string $shortUrl = null
    ) {
    }

    public static function ready(string $originalUrl, string $shortCode, string $shortUrl): self
    {
        return new self('ready', $originalUrl, $shortCode, $shortUrl);
    }

    public static function pending(string $originalUrl): self
    {
        return new self('pending', $originalUrl);
    }

    public function isReady(): bool
    {
        return $this->status === 'ready';
    }

    public function toArray(): array
    {
        $payload = [
            'status' => $this->status,
            'original_url' => $this->originalUrl,
        ];

        if ($this->shortCode !== null && $this->shortUrl !== null) {
            $payload['short_code'] = $this->shortCode;
            $payload['short_url'] = $this->shortUrl;
        } else {
            $payload['message'] = 'Ссылка генерируется';
        }

        return $payload;
    }
}
