<?php

namespace App\Tests\Functional;

use Symfony\Bundle\FrameworkBundle\Test\WebTestCase;

final class ShortlinkControllerTest extends WebTestCase
{
    public function testReturnsBadRequestIfUrlParameterIsMissing(): void
    {
        $client = static::createClient();
        $client->request('GET', '/api/shortlink');

        self::assertResponseStatusCodeSame(400);
        self::assertResponseFormatSame('json');

        $payload = json_decode((string) $client->getResponse()->getContent(), true, 512, JSON_THROW_ON_ERROR);
        self::assertSame('error', $payload['status'] ?? null);
    }

    public function testReturnsBadRequestIfUrlParameterIsInvalid(): void
    {
        $client = static::createClient();
        $client->request('GET', '/api/shortlink?url=not-a-valid-url');

        self::assertResponseStatusCodeSame(400);

        $payload = json_decode((string) $client->getResponse()->getContent(), true, 512, JSON_THROW_ON_ERROR);
        self::assertSame('error', $payload['status'] ?? null);
    }
}
