<?php

namespace App\Entity;

use App\Repository\ShortlinkRepository;
use Doctrine\ORM\Mapping as ORM;

#[ORM\Entity(repositoryClass: ShortlinkRepository::class)]
#[ORM\Table(name: 'shortlinks')]
#[ORM\UniqueConstraint(name: 'uniq_shortlinks_original_url', columns: ['original_url'])]
#[ORM\UniqueConstraint(name: 'uniq_shortlinks_short_code', columns: ['short_code'])]
#[ORM\Index(name: 'idx_shortlinks_status', columns: ['status'])]
class Shortlink
{
    public const STATUS_PENDING = 'pending';
    public const STATUS_READY = 'ready';
    public const STATUS_FAILED = 'failed';

    #[ORM\Id]
    #[ORM\GeneratedValue]
    #[ORM\Column]
    private ?int $id = null;

    #[ORM\Column(length: 2048)]
    private string $originalUrl;

    #[ORM\Column(length: 8, nullable: true)]
    private ?string $shortCode = null;

    #[ORM\Column(length: 16)]
    private string $status = self::STATUS_PENDING;

    #[ORM\Column]
    private \DateTimeImmutable $createdAt;

    #[ORM\Column]
    private \DateTimeImmutable $updatedAt;

    public function __construct(string $originalUrl)
    {
        $now = new \DateTimeImmutable();
        $this->originalUrl = $originalUrl;
        $this->createdAt = $now;
        $this->updatedAt = $now;
    }

    public function getId(): ?int
    {
        return $this->id;
    }

    public function getOriginalUrl(): string
    {
        return $this->originalUrl;
    }

    public function getShortCode(): ?string
    {
        return $this->shortCode;
    }

    public function getStatus(): string
    {
        return $this->status;
    }

    public function getCreatedAt(): \DateTimeImmutable
    {
        return $this->createdAt;
    }

    public function getUpdatedAt(): \DateTimeImmutable
    {
        return $this->updatedAt;
    }

    public function isPending(): bool
    {
        return $this->status === self::STATUS_PENDING;
    }

    public function isReady(): bool
    {
        return $this->status === self::STATUS_READY && $this->shortCode !== null;
    }

    public function isFailed(): bool
    {
        return $this->status === self::STATUS_FAILED;
    }

    public function markReady(string $shortCode): void
    {
        $this->shortCode = $shortCode;
        $this->status = self::STATUS_READY;
        $this->updatedAt = new \DateTimeImmutable();
    }

    public function markFailed(): void
    {
        $this->status = self::STATUS_FAILED;
        $this->updatedAt = new \DateTimeImmutable();
    }
}
