<?php

namespace App\Controller;

use App\Service\ShortlinkService;
use Psr\Log\LoggerInterface;
use Symfony\Bundle\FrameworkBundle\Controller\AbstractController;
use Symfony\Component\HttpFoundation\JsonResponse;
use Symfony\Component\HttpFoundation\RedirectResponse;
use Symfony\Component\HttpFoundation\Request;
use Symfony\Component\HttpFoundation\Response;
use Symfony\Component\HttpKernel\Exception\NotFoundHttpException;
use Symfony\Component\Routing\Attribute\Route;

final class ShortlinkController extends AbstractController
{
    public function __construct(
        private readonly ShortlinkService $shortlinkService,
        private readonly LoggerInterface $logger
    ) {
    }

    #[Route('/api/shortlink', name: 'api_shortlink_get_or_create', methods: ['GET'])]
    public function getOrCreate(Request $request): JsonResponse
    {
        $url = trim((string) $request->query->get('url', ''));

        if ($url === '') {
            return $this->json(
                [
                    'status' => 'error',
                    'message' => 'Параметр query `url` обязателен.',
                ],
                Response::HTTP_BAD_REQUEST
            );
        }

        if (!$this->isValidHttpUrl($url)) {
            return $this->json(
                [
                    'status' => 'error',
                    'message' => 'Параметр `url` должен быть валидным HTTP/HTTPS URL.',
                ],
                Response::HTTP_BAD_REQUEST
            );
        }

        try {
            $result = $this->shortlinkService->getOrCreate($url);
        } catch (\Throwable $exception) {
            $this->logger->critical('Shortlink API internal error.', [
                'exception' => $exception,
            ]);

            $payload = [
                'status' => 'error',
                'message' => 'Внутренняя ошибка сервиса.',
            ];

            if (filter_var($_SERVER['APP_DEBUG'] ?? false, FILTER_VALIDATE_BOOL)) {
                $payload['debug_error'] = sprintf(
                    '%s: %s',
                    $exception::class,
                    $exception->getMessage()
                );
            }

            return $this->json(
                $payload,
                Response::HTTP_INTERNAL_SERVER_ERROR
            );
        }

        $statusCode = $result->isReady() ? Response::HTTP_OK : Response::HTTP_ACCEPTED;

        return $this->json($result->toArray(), $statusCode);
    }

    #[Route('/r/{shortCode}', name: 'shortlink_redirect', methods: ['GET'])]
    public function redirectByShortCode(string $shortCode): RedirectResponse
    {
        $shortlink = $this->shortlinkService->findReadyByCode($shortCode);
        if ($shortlink === null) {
            throw new NotFoundHttpException('Короткая ссылка не найдена.');
        }

        return new RedirectResponse($shortlink->getOriginalUrl(), Response::HTTP_FOUND);
    }

    private function isValidHttpUrl(string $url): bool
    {
        if (filter_var($url, FILTER_VALIDATE_URL) === false) {
            return false;
        }

        $scheme = parse_url($url, PHP_URL_SCHEME);
        if (!is_string($scheme)) {
            return false;
        }

        return in_array(strtolower($scheme), ['http', 'https'], true);
    }
}
