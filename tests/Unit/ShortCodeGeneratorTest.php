<?php

namespace App\Tests\Unit;

use App\Service\ShortCodeGenerator;
use PHPUnit\Framework\TestCase;

final class ShortCodeGeneratorTest extends TestCase
{
    public function testGeneratedCodeHasExpectedLengthAndAlphabet(): void
    {
        $generator = new ShortCodeGenerator();

        for ($index = 0; $index < 200; $index++) {
            $code = $generator->generate();

            self::assertMatchesRegularExpression('/^[A-Za-z0-9]{4,8}$/', $code);
        }
    }

    public function testGeneratorThrowsExceptionForInvalidLengthRange(): void
    {
        $generator = new ShortCodeGenerator();

        $this->expectException(\InvalidArgumentException::class);
        $generator->generate(9, 4);
    }
}
