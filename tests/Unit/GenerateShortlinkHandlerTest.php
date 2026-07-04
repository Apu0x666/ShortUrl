<?php

namespace App\Tests\Unit;

use App\Entity\Shortlink;
use App\Message\GenerateShortlinkMessage;
use App\MessageHandler\GenerateShortlinkHandler;
use App\Repository\ShortlinkRepository;
use App\Service\ShortCodeGenerator;
use PHPUnit\Framework\TestCase;

final class GenerateShortlinkHandlerTest extends TestCase
{
    public function testStopsWhenShortlinkDoesNotExist(): void
    {
        $repository = $this->createMock(ShortlinkRepository::class);
        $generator = new ShortCodeGenerator();
        $handler = new GenerateShortlinkHandler($repository, $generator);

        $repository->expects(self::once())->method('find')->with(999)->willReturn(null);
        $repository->expects(self::never())->method('tryAssignShortCode');

        $handler(new GenerateShortlinkMessage(999));
    }

    public function testRetriesUntilCodeAssigned(): void
    {
        $repository = $this->createMock(ShortlinkRepository::class);
        $generator = new ShortCodeGenerator();
        $handler = new GenerateShortlinkHandler($repository, $generator);

        $shortlink = new Shortlink('https://example.com/retry');
        $this->setEntityId($shortlink, 10);

        $repository
            ->expects(self::exactly(2))
            ->method('find')
            ->with(10)
            ->willReturn($shortlink);
        $repository
            ->expects(self::exactly(2))
            ->method('tryAssignShortCode')
            ->willReturnOnConsecutiveCalls(false, true);

        $repository->expects(self::never())->method('markFailed');

        $handler(new GenerateShortlinkMessage(10));
    }

    public function testMarksFailedWhenNoUniqueCodeFound(): void
    {
        $repository = $this->createMock(ShortlinkRepository::class);
        $generator = new ShortCodeGenerator();
        $handler = new GenerateShortlinkHandler($repository, $generator);

        $shortlink = new Shortlink('https://example.com/fail');
        $this->setEntityId($shortlink, 24);

        $repository
            ->expects(self::exactly(32))
            ->method('find')
            ->with(24)
            ->willReturn($shortlink);
        $repository->expects(self::exactly(30))->method('tryAssignShortCode')->with(24, self::isType('string'))->willReturn(false);
        $repository->expects(self::once())->method('markFailed')->with(24);

        $handler(new GenerateShortlinkMessage(24));
    }

    private function setEntityId(Shortlink $shortlink, int $id): void
    {
        $reflectionProperty = new \ReflectionProperty($shortlink, 'id');
        $reflectionProperty->setAccessible(true);
        $reflectionProperty->setValue($shortlink, $id);
    }
}
