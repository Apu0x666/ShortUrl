<?php

namespace App\Service;

final class ShortCodeGenerator
{
    private const ALPHABET = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';

    public function generate(int $minLength = 4, int $maxLength = 8): string
    {
        if ($minLength < 1 || $minLength > $maxLength) {
            throw new \InvalidArgumentException('Некорректный диапазон длины short code.');
        }

        $length = random_int($minLength, $maxLength);
        $lastIndex = strlen(self::ALPHABET) - 1;
        $code = '';

        for ($index = 0; $index < $length; $index++) {
            $code .= self::ALPHABET[random_int(0, $lastIndex)];
        }

        return $code;
    }
}
