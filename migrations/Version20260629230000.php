<?php

declare(strict_types=1);

namespace DoctrineMigrations;

use Doctrine\DBAL\Platforms\PostgreSQLPlatform;
use Doctrine\DBAL\Schema\Schema;
use Doctrine\Migrations\AbstractMigration;

final class Version20260629230000 extends AbstractMigration
{
    public function getDescription(): string
    {
        return 'Создает таблицу shortlinks с уникальностью original_url и short_code.';
    }

    public function up(Schema $schema): void
    {
        $this->abortIf(
            !($this->connection->getDatabasePlatform() instanceof PostgreSQLPlatform),
            'Эта миграция рассчитана на PostgreSQL.'
        );

        $this->addSql(
            <<<SQL
                CREATE TABLE shortlinks (
                    id BIGSERIAL NOT NULL,
                    original_url VARCHAR(2048) NOT NULL,
                    short_code VARCHAR(8) DEFAULT NULL,
                    status VARCHAR(16) NOT NULL,
                    created_at TIMESTAMP(0) WITHOUT TIME ZONE NOT NULL,
                    updated_at TIMESTAMP(0) WITHOUT TIME ZONE NOT NULL,
                    PRIMARY KEY(id)
                )
            SQL
        );
        $this->addSql('CREATE UNIQUE INDEX uniq_shortlinks_original_url ON shortlinks (original_url)');
        $this->addSql('CREATE UNIQUE INDEX uniq_shortlinks_short_code ON shortlinks (short_code)');
        $this->addSql('CREATE INDEX idx_shortlinks_status ON shortlinks (status)');
    }

    public function down(Schema $schema): void
    {
        $this->abortIf(
            !($this->connection->getDatabasePlatform() instanceof PostgreSQLPlatform),
            'Эта миграция рассчитана на PostgreSQL.'
        );

        $this->addSql('DROP TABLE shortlinks');
    }
}
