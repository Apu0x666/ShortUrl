<?php

namespace App\Service;

use App\Dto\ShortlinkLookupResult;
use App\Entity\Shortlink;
use App\Message\GenerateShortlinkMessage;
use App\Repository\ShortlinkRepository;
use Symfony\Component\Messenger\MessageBusInterface;

final class ShortlinkService
{
    public function __construct(
        private readonly ShortlinkRepository $shortlinkRepository,
        private readonly MessageBusInterface $messageBus,
        private readonly ShortUrlBuilder $shortUrlBuilder
    ) {
    }

    public function getOrCreate(string $originalUrl): ShortlinkLookupResult
    {
        $normalizedUrl = $this->normalizeUrl($originalUrl);
        $result = $this->shortlinkRepository->findOrCreatePending($normalizedUrl);
        $shortlink = $result->getShortlink();

        if ($shortlink->isReady()) {
            $shortCode = $shortlink->getShortCode();
            if ($shortCode === null) {
                throw new \RuntimeException('Shortlink имеет неконсистентное состояние.');
            }

            return ShortlinkLookupResult::ready(
                $shortlink->getOriginalUrl(),
                $shortCode,
                $this->shortUrlBuilder->build($shortCode)
            );
        }

        $shortlinkId = $shortlink->getId();
        if ($shortlink->isFailed() && $shortlinkId !== null) {
            $requeued = $this->shortlinkRepository->markPendingIfFailed($shortlinkId);
            if ($requeued) {
                $this->messageBus->dispatch(new GenerateShortlinkMessage($shortlinkId));
            }

            return ShortlinkLookupResult::pending($shortlink->getOriginalUrl());
        }

        if ($result->isCreated()) {
            if ($shortlinkId === null) {
                throw new \RuntimeException('Не удалось получить идентификатор shortlink после создания.');
            }

            $this->messageBus->dispatch(new GenerateShortlinkMessage($shortlinkId));
        }

        return ShortlinkLookupResult::pending($shortlink->getOriginalUrl());
    }

    public function findReadyByCode(string $shortCode): ?Shortlink
    {
        if (!preg_match('/^[A-Za-z0-9]{4,8}$/', $shortCode)) {
            return null;
        }

        $shortlink = $this->shortlinkRepository->findOneByShortCode($shortCode);
        if ($shortlink === null || !$shortlink->isReady()) {
            return null;
        }

        return $shortlink;
    }

    private function normalizeUrl(string $url): string
    {
        return trim($url);
    }
}
