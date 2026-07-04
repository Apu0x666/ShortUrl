<?php

namespace App\Repository;

use App\Dto\FindOrCreateShortlinkResult;
use App\Entity\Shortlink;
use Doctrine\Bundle\DoctrineBundle\Repository\ServiceEntityRepository;
use Doctrine\Persistence\ManagerRegistry;

/**
 * @extends ServiceEntityRepository<Shortlink>
 */
class ShortlinkRepository extends ServiceEntityRepository
{
    public function __construct(ManagerRegistry $registry)
    {
        parent::__construct($registry, Shortlink::class);
    }

    public function findOneByOriginalUrl(string $originalUrl): ?Shortlink
    {
        return $this->findOneBy(['originalUrl' => $originalUrl]);
    }

    public function findOneByShortCode(string $shortCode): ?Shortlink
    {
        return $this->findOneBy(['shortCode' => $shortCode]);
    }

    public function findOrCreatePending(string $originalUrl): FindOrCreateShortlinkResult
    {
        $connection = $this->getEntityManager()->getConnection();

        $insertedId = $connection->fetchOne(
            <<<SQL
                INSERT INTO shortlinks (original_url, short_code, status, created_at, updated_at)
                VALUES (:original_url, NULL, :status, NOW(), NOW())
                ON CONFLICT (original_url) DO NOTHING
                RETURNING id
            SQL,
            [
                'original_url' => $originalUrl,
                'status' => Shortlink::STATUS_PENDING,
            ]
        );

        if ($insertedId !== false) {
            $shortlink = $this->find((int) $insertedId);

            if ($shortlink === null) {
                throw new \RuntimeException('Созданная запись shortlink не найдена.');
            }

            return new FindOrCreateShortlinkResult($shortlink, true);
        }

        $shortlink = $this->findOneByOriginalUrl($originalUrl);

        if ($shortlink === null) {
            throw new \RuntimeException('Не удалось получить существующую запись shortlink.');
        }

        return new FindOrCreateShortlinkResult($shortlink, false);
    }

    public function tryAssignShortCode(int $shortlinkId, string $shortCode): bool
    {
        $connection = $this->getEntityManager()->getConnection();

        try {
            $updatedRows = $connection->executeStatement(
                <<<SQL
                    UPDATE shortlinks
                    SET short_code = :short_code,
                        status = :ready_status,
                        updated_at = NOW()
                    WHERE id = :id
                      AND status = :pending_status
                SQL,
                [
                    'short_code' => $shortCode,
                    'ready_status' => Shortlink::STATUS_READY,
                    'pending_status' => Shortlink::STATUS_PENDING,
                    'id' => $shortlinkId,
                ]
            );
        } catch (\Doctrine\DBAL\Exception\UniqueConstraintViolationException) {
            $this->getEntityManager()->clear();
            return false;
        }

        $this->getEntityManager()->clear();

        return $updatedRows > 0;
    }

    public function markFailed(int $shortlinkId): void
    {
        $this->getEntityManager()->getConnection()->executeStatement(
            <<<SQL
                UPDATE shortlinks
                SET status = :status,
                    updated_at = NOW()
                WHERE id = :id
            SQL,
            [
                'status' => Shortlink::STATUS_FAILED,
                'id' => $shortlinkId,
            ]
        );

        $this->getEntityManager()->clear();
    }

    public function markPendingIfFailed(int $shortlinkId): bool
    {
        $updatedRows = $this->getEntityManager()->getConnection()->executeStatement(
            <<<SQL
                UPDATE shortlinks
                SET status = :pending_status,
                    updated_at = NOW()
                WHERE id = :id
                  AND status = :failed_status
            SQL,
            [
                'pending_status' => Shortlink::STATUS_PENDING,
                'failed_status' => Shortlink::STATUS_FAILED,
                'id' => $shortlinkId,
            ]
        );

        if ($updatedRows > 0) {
            $this->getEntityManager()->clear();
            return true;
        }

        return false;
    }
}
