<?php

namespace App\Dto;

use App\Entity\Shortlink;

final class FindOrCreateShortlinkResult
{
    public function __construct(
        private readonly Shortlink $shortlink,
        private readonly bool $created
    ) {
    }

    public function getShortlink(): Shortlink
    {
        return $this->shortlink;
    }

    public function isCreated(): bool
    {
        return $this->created;
    }
}
