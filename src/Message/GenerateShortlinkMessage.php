<?php

namespace App\Message;

final class GenerateShortlinkMessage
{
    public function __construct(
        private readonly int $shortlinkId
    ) {
    }

    public function getShortlinkId(): int
    {
        return $this->shortlinkId;
    }
}
