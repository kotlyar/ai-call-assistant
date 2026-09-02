import type { Metadata } from 'next';
import './globals.css';

export const metadata: Metadata = {
  title: 'Callya — AI-помощник для звонков',
  description:
    'Опенсорсный AI-копилот для звонков на macOS и Windows: транскрипция, подсказки в реальном времени и разбор разговора.',
  icons: {
    icon: [{ url: '/callya-icon.png', type: 'image/png' }],
    apple: '/callya-icon.png',
  },
  openGraph: {
    type: 'website',
    locale: 'ru_RU',
    title: 'Callya — AI-помощник для звонков',
    description:
      'Слышит обе стороны звонка, учитывает ваши материалы и подсказывает ответ в реальном времени.',
    images: [
      {
        url: 'https://raw.githubusercontent.com/kotlyar/ai-call-assistant/main/website/public/og.png',
        width: 1200,
        height: 630,
        alt: 'Callya — AI-помощник для звонков',
      },
    ],
  },
  twitter: {
    card: 'summary_large_image',
    title: 'Callya — AI-помощник для звонков',
    description: 'Опенсорсный нативный AI-копилот для macOS и Windows.',
    images: [
      'https://raw.githubusercontent.com/kotlyar/ai-call-assistant/main/website/public/og.png',
    ],
  },
};

export default function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode;
}>) {
  return (
    <html lang="ru">
      <body>{children}</body>
    </html>
  );
}
