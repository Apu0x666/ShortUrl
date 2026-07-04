<?php

namespace App\Tests\Unit;

use App\Dto\FindOrCreateShortlinkResult;
use App\Entity\Shortlink;
use App\Message\GenerateShortlinkMessage;
use App\Repository\ShortlinkRepository;
use App\Service\ShortUrlBuilder;
use App\Service\ShortlinkService;
use PHPUnit\Framework\TestCase;
use Symfony\Component\Messenger\Envelope;
use Symfony\Component\Messenger\MessageBusInterface;

final class ShortlinkServiceTest extends TestCase
{
    public function testReturnsReadyResponseForExistingReadyShortlink(): void
    {
        $repository = $this->createMock(ShortlinkRepository::class);
        $messageBus = $this->createMock(MessageBusInterface::class);
        $service = new ShortlinkService($repository, $messageBus, new ShortUrlBuilder('http://localhost:8080/r'));

        $shortlink = new Shortlink('https://example.com');
        $shortlink->markReady('Ab12');

        $repository->method('findOrCreatePending')->willReturn(new FindOrCreateShortlinkResult($shortlink, false));
        $messageBus->expects(self::never())->method('dispatch');

        $result = $service->getOrCreate('https://example.com');

        self::assertSame(
            [
                'status' => 'ready',
                'original_url' => 'https://example.com',
                'short_code' => 'Ab12',
                'short_url' => 'http://localhost:8080/r/Ab12',
            ],
            $result->toArray()
        );
    }

    public function testDispatchesMessageForNewPendingShortlink(): void
    {
        $repository = $this->createMock(ShortlinkRepository::class);
        $messageBus = $this->createMock(MessageBusInterface::class);
        $service = new ShortlinkService($repository, $messageBus, new ShortUrlBuilder('http://localhost:8080/r'));

        $shortlink = new Shortlink('https://example.com/new');
        $this->setEntityId($shortlink, 10);

        $repository->method('findOrCreatePending')->willReturn(new FindOrCreateShortlinkResult($shortlink, true));

        $messageBus
            ->expects(self::once())
            ->method('dispatch')
            ->with(self::callback(static function (GenerateShortlinkMessage $message): bool {
                return $message->getShortlinkId() === 10;
            }))
            ->willReturn(new Envelope(new \stdClass()));

        $result = $service->getOrCreate('https://example.com/new');

        self::assertSame(
            [
                'status' => 'pending',
                'original_url' => 'https://example.com/new',
                'message' => 'Ссылка генерируется',
            ],
            $result->toArray()
        );
    }

    public function testDoesNotDispatchSecondMessageForConcurrentPendingShortlink(): void
    {
        $repository = $this->createMock(ShortlinkRepository::class);
        $messageBus = $this->createMock(MessageBusInterface::class);
        $service = new ShortlinkService($repository, $messageBus, new ShortUrlBuilder('http://localhost:8080/r'));

        $shortlink = new Shortlink('https://example.com/pending');
        $this->setEntityId($shortlink, 15);

        $repository->method('findOrCreatePending')->willReturn(new FindOrCreateShortlinkResult($shortlink, false));
        $messageBus->expects(self::never())->method('dispatch');

        $result = $service->getOrCreate('https://example.com/pending');

        self::assertSame('pending', $result->toArray()['status']);
    }

    public function testRequeuesFailedShortlink(): void
    {
        $repository = $this->createMock(ShortlinkRepository::class);
        $messageBus = $this->createMock(MessageBusInterface::class);
        $service = new ShortlinkService($repository, $messageBus, new ShortUrlBuilder('http://localhost:8080/r'));

        $shortlink = new Shortlink('https://example.com/failed');
        $this->setEntityId($shortlink, 21);
        $shortlink->markFailed();

        $repository->method('findOrCreatePending')->willReturn(new FindOrCreateShortlinkResult($shortlink, false));
        $repository
            ->expects(self::once())
            ->method('markPendingIfFailed')
            ->with(21)
            ->willReturn(true);

        $messageBus
            ->expects(self::once())
            ->method('dispatch')
            ->with(self::isInstanceOf(GenerateShortlinkMessage::class))
            ->willReturn(new Envelope(new \stdClass()));

        $result = $service->getOrCreate('https://example.com/failed');

        self::assertSame('pending', $result->toArray()['status']);
    }

    private function setEntityId(Shortlink $shortlink, int $id): void
    {
        $reflectionProperty = new \ReflectionProperty($shortlink, 'id');
        $reflectionProperty->setAccessible(true);
        $reflectionProperty->setValue($shortlink, $id);
    }
}
