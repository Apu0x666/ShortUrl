<?php

namespace App\MessageHandler;

use App\Message\GenerateShortlinkMessage;
use App\Repository\ShortlinkRepository;
use App\Service\ShortCodeGenerator;
use Symfony\Component\Messenger\Attribute\AsMessageHandler;

#[AsMessageHandler]
final class GenerateShortlinkHandler
{
    private const MAX_ATTEMPTS = 30;

    public function __construct(
        private readonly ShortlinkRepository $shortlinkRepository,
        private readonly ShortCodeGenerator $shortCodeGenerator
    ) {
    }

    public function __invoke(GenerateShortlinkMessage $message): void
    {
        $shortlink = $this->shortlinkRepository->find($message->getShortlinkId());
        if ($shortlink === null || $shortlink->isReady()) {
            return;
        }

        $shortlinkId = $shortlink->getId();
        if ($shortlinkId === null) {
            return;
        }

        for ($attempt = 1; $attempt <= self::MAX_ATTEMPTS; $attempt++) {
            $shortCode = $this->shortCodeGenerator->generate();
            $assigned = $this->shortlinkRepository->tryAssignShortCode($shortlinkId, $shortCode);

            if ($assigned) {
                return;
            }

            $actualState = $this->shortlinkRepository->find($shortlinkId);
            if ($actualState === null || !$actualState->isPending()) {
                return;
            }
        }

        $actualState = $this->shortlinkRepository->find($shortlinkId);
        if ($actualState !== null && $actualState->isPending()) {
            $this->shortlinkRepository->markFailed($shortlinkId);
        }
    }
}
