import {
  Apple,
  ArrowUpRight,
  AudioLines,
  BookOpen,
  Captions,
  Check,
  CircleDollarSign,
  Code2,
  Download,
  ExternalLink,
  Files,
  FileText,
  Gauge,
  HardDrive,
  History,
  LockKeyhole,
  MessageSquareText,
  Monitor,
  ShieldCheck,
  Sparkles,
} from 'lucide-react';
import Image from 'next/image';

import { buttonVariants } from '@/components/ui/button';
import { cn } from '@/lib/utils';

const repositoryUrl = 'https://github.com/kotlyar/ai-call-assistant';
const releaseUrl = `${repositoryUrl}/releases/latest`;
const macDownloadUrl = `${releaseUrl}/download/Callya.dmg`;
const macZipUrl = `${releaseUrl}/download/Callya.zip`;
const windowsDownloadUrl = `${releaseUrl}/download/Callya-Windows-win-x64.zip`;
const windowsChecksumUrl = `${releaseUrl}/download/Callya-Windows-win-x64.zip.sha256`;

const steps = [
  {
    number: '01',
    title: 'Подготовьте контекст',
    description:
      'Добавьте роль, факты, сценарий и документы. На старте Callya фиксирует выбранный набор — ответы не потеряют нить разговора.',
  },
  {
    number: '02',
    title: 'Начните звонок',
    description:
      'Выберите микрофон и звук собеседника. Две независимые дорожки превращаются в аккуратный живой диалог.',
  },
  {
    number: '03',
    title: 'Получайте ответы',
    description:
      'Когда собеседник задаёт вопрос, плавающая панель показывает готовую формулировку, совет и историю подсказок.',
  },
];

const features = [
  {
    icon: AudioLines,
    title: 'Слышит обе стороны',
    description:
      'Системный звук или выбранное приложение — отдельно от вашего микрофона.',
    className: 'feature-card feature-card-wide feature-card-blue',
  },
  {
    icon: Captions,
    title: 'Live-транскрипт',
    description:
      'Независимое распознавание реплик с русским и английским языками.',
    className: 'feature-card',
  },
  {
    icon: MessageSquareText,
    title: 'Ответ на каждый вопрос',
    description:
      'Краткая или подробная формулировка с учётом полного диалога и выбранных материалов.',
    className: 'feature-card feature-card-tall feature-card-violet',
  },
  {
    icon: Files,
    title: 'Контексты и файлы',
    description:
      'PDF, Word, презентации, таблицы, Markdown, исходный код и другие текстовые форматы.',
    className: 'feature-card',
  },
  {
    icon: History,
    title: 'После звонка всё на месте',
    description:
      'Аудио, канонический транскрипт, итоговые Q&A, поиск, воспроизведение и экспорт.',
    className: 'feature-card feature-card-wide feature-card-green',
  },
];

const faqs = [
  {
    question: 'Нужна подписка ChatGPT?',
    answer:
      'Нет. Нужен отдельный OpenAI Platform API key с настроенным биллингом. Подписка ChatGPT или Codex не покрывает API-расходы Callya.',
  },
  {
    question: 'Callya записывает экран?',
    answer:
      'Нет, приложение захватывает звук, а не изображение экрана. На macOS для этого используется разрешение System Audio Recording. Если выбран браузер целиком, в запись могут попасть другие слышимые вкладки.',
  },
  {
    question: 'Можно скрыть панель при демонстрации экрана?',
    answer:
      'На обеих платформах есть best-effort защита от захвата, но современные или нестандартные способы записи могут её игнорировать. Проверяйте конкретное приложение и режим шаринга до важного звонка.',
  },
  {
    question: 'Что произойдёт без API key?',
    answer:
      'Локальная запись продолжит работать. Транскрипция, подсказки и постобработка дождутся ключа — неудавшиеся этапы можно перезапустить позже.',
  },
];

export default function Home() {
  return (
    <main className="min-h-screen overflow-hidden bg-background text-foreground">
      <header className="sticky top-0 z-50 border-b border-white/8 bg-background/78 backdrop-blur-xl">
        <div className="site-container flex h-18 items-center justify-between">
          <a
            className="flex items-center gap-3"
            href="#top"
            aria-label="Callya — наверх"
          >
            <Image
              src="/callya-icon.png"
              alt=""
              width={36}
              height={36}
              className="size-9 rounded-[10px] ring-1 ring-white/12"
            />
            <span className="text-[17px] font-semibold tracking-[-0.02em]">
              Callya
            </span>
          </a>

          <nav
            className="hidden items-center gap-7 md:flex"
            aria-label="Основная навигация"
          >
            <a className="nav-link" href="#features">
              Возможности
            </a>
            <a className="nav-link" href="#price">
              Стоимость
            </a>
            <a className="nav-link" href="#privacy">
              Данные
            </a>
            <a className="nav-link" href="#open-source">
              Open source
            </a>
          </nav>

          <div className="flex items-center gap-2">
            <a
              href={repositoryUrl}
              target="_blank"
              rel="noreferrer"
              aria-label="Открыть Callya на GitHub"
              className={cn(
                buttonVariants({ variant: 'ghost', size: 'icon-lg' }),
                'text-white/68 hover:bg-white/7 hover:text-white sm:hidden',
              )}
            >
              <Code2 />
            </a>
            <a
              href={repositoryUrl}
              target="_blank"
              rel="noreferrer"
              className={cn(
                buttonVariants({ variant: 'ghost', size: 'lg' }),
                'hidden text-white/68 hover:bg-white/7 hover:text-white sm:inline-flex',
              )}
            >
              <Code2 data-icon="inline-start" />
              GitHub
            </a>
            <a
              href="#download"
              className={cn(
                buttonVariants({ size: 'lg' }),
                'h-10 rounded-full bg-white px-5 text-[#111113] hover:bg-white/86',
              )}
            >
              Скачать
              <Download data-icon="inline-end" />
            </a>
          </div>
        </div>
        <nav
          className="site-container flex h-10 items-center gap-5 overflow-x-auto border-t border-white/6 text-xs whitespace-nowrap [scrollbar-width:none] md:hidden [&::-webkit-scrollbar]:hidden"
          aria-label="Мобильная навигация"
        >
          <a className="nav-link" href="#features">
            Возможности
          </a>
          <a className="nav-link" href="#price">
            Стоимость
          </a>
          <a className="nav-link" href="#privacy">
            Данные
          </a>
          <a className="nav-link" href="#open-source">
            Open source
          </a>
        </nav>
      </header>

      <section id="top" className="relative isolate pt-18 sm:pt-24">
        <div className="hero-glow" aria-hidden="true" />
        <div className="site-container relative z-10">
          <div className="mx-auto max-w-4xl text-center">
            <div className="eyebrow mx-auto mb-7">
              <Sparkles className="size-3.5" aria-hidden="true" />
              Open source · macOS + Windows
            </div>
            <h1 className="balance text-[clamp(3.25rem,8vw,7.35rem)] font-semibold leading-[0.88] tracking-[-0.068em]">
              Слышит звонок.
              <span className="gradient-text block">Подсказывает ответ.</span>
            </h1>
            <p className="balance mx-auto mt-8 max-w-2xl text-lg leading-8 text-white/58 sm:text-xl">
              Нативный AI-копилот для живых разговоров. Callya расшифровывает
              обе стороны, учитывает ваши материалы и формулирует точный ответ
              прямо во время звонка.
            </p>
            <div className="mt-9 flex flex-col items-center justify-center gap-3 sm:flex-row">
              <a
                href={macDownloadUrl}
                className={cn(
                  buttonVariants({ size: 'lg' }),
                  'download-button h-13 w-full rounded-full px-6 sm:w-auto',
                )}
              >
                <Apple data-icon="inline-start" />
                Скачать для macOS
                <span className="button-meta">14.2+</span>
              </a>
              <a
                href={windowsDownloadUrl}
                className={cn(
                  buttonVariants({ variant: 'outline', size: 'lg' }),
                  'download-button h-13 w-full rounded-full border-white/13 bg-white/6 px-6 text-white hover:bg-white/11 sm:w-auto',
                )}
              >
                <Monitor data-icon="inline-start" />
                Скачать для Windows
                <span className="button-meta text-white/42">11 · x64</span>
              </a>
            </div>
            <p className="mt-4 text-xs text-white/35">
              Версия 0.2.2 · приложение бесплатно · потребуется собственный
              OpenAI API key
            </p>
          </div>

          <div className="product-stage mx-auto mt-14 max-w-6xl sm:mt-20">
            <Image
              src="/product/live-assistant.jpg"
              alt="Callya распознаёт вопрос собеседника и предлагает ответ в реальном времени"
              width={2400}
              height={1600}
              priority
              unoptimized
              className="product-shot"
            />
          </div>

          <div className="trust-row">
            <span>
              <Check />
              Нативные приложения
            </span>
            <span>
              <Check />
              Две аудиодорожки
            </span>
            <span>
              <Check />
              Локальная библиотека
            </span>
            <span>
              <Check />
              Открытый исходный код
            </span>
          </div>
        </div>
      </section>

      <section id="features" className="paper-section scroll-mt-18">
        <div className="site-container py-24 sm:py-32">
          <div className="section-heading-grid">
            <p className="section-kicker text-[#6858d6]">Как это работает</p>
            <div>
              <h2 className="section-title max-w-3xl text-[#141417]">
                В разговоре остаётесь вы. Callya держит остальное.
              </h2>
              <p className="mt-6 max-w-2xl text-lg leading-8 text-[#5c5b61]">
                Никаких ботов в конференции и облачной панели управления —
                только нативное приложение, которое работает рядом с Meet, Zoom,
                Teams и любым другим источником звука.
              </p>
            </div>
          </div>

          <div className="steps-grid mt-18">
            {steps.map((step) => (
              <article key={step.number} className="step-item">
                <span className="step-number">{step.number}</span>
                <h3>{step.title}</h3>
                <p>{step.description}</p>
              </article>
            ))}
          </div>

          <div className="setup-stage mt-18">
            <Image
              src="/product/call-setup.png"
              alt="Актуальный экран нового звонка в Callya: микрофон, системный звук, live-анализ и контексты"
              width={1800}
              height={1600}
              unoptimized
              className="block h-auto w-full"
            />
          </div>

          <div className="mt-24 sm:mt-32">
            <div className="mb-10 flex flex-col justify-between gap-5 sm:flex-row sm:items-end">
              <div>
                <p className="section-kicker text-[#6858d6]">Возможности</p>
                <h2 className="section-title mt-3 max-w-2xl text-[#141417]">
                  От первого слова до итогов разговора.
                </h2>
              </div>
              <p className="max-w-sm text-sm leading-6 text-[#6b6a70]">
                Архитектура с раздельными дорожками сохраняет исходный материал,
                даже если сетевой этап временно недоступен.
              </p>
            </div>

            <div className="features-grid">
              {features.map(({ icon: Icon, title, description, className }) => (
                <article key={title} className={className}>
                  <span className="feature-icon">
                    <Icon aria-hidden="true" />
                  </span>
                  <div>
                    <h3>{title}</h3>
                    <p>{description}</p>
                  </div>
                </article>
              ))}
            </div>
          </div>
        </div>
      </section>

      <section id="price" className="night-section scroll-mt-18">
        <div className="site-container grid gap-12 py-24 lg:grid-cols-[0.78fr_1.22fr] lg:items-center sm:py-32">
          <div>
            <p className="section-kicker text-[#9c8cff]">Стоимость OpenAI</p>
            <h2 className="section-title mt-3 text-white">
              Один час — примерно как чашка кофе.
            </h2>
            <p className="mt-6 max-w-xl text-lg leading-8 text-white/55">
              Callya бесплатна. Вы оплачиваете только API напрямую OpenAI и
              можете задать жёсткий лимит расходов на каждый звонок.
            </p>
            <div className="mt-8 flex flex-wrap gap-x-6 gap-y-3 text-sm text-white/45">
              <span className="inline-flex items-center gap-2">
                <Gauge className="size-4" />
                Лимит на звонок
              </span>
              <span className="inline-flex items-center gap-2">
                <LockKeyhole className="size-4" />
                Ваш API key
              </span>
              <span className="inline-flex items-center gap-2">
                <FileText className="size-4" />
                Локальный журнал затрат
              </span>
            </div>
          </div>

          <article className="price-card">
            <div className="flex items-center justify-between gap-4">
              <span className="price-label">
                <CircleDollarSign />
                Ориентир
              </span>
              <span className="text-xs text-white/34">
                цены OpenAI на 2 сентября · курс ЦБ на 3 сентября
              </span>
            </div>
            <div className="mt-8 flex flex-wrap items-end gap-x-4 gap-y-2">
              <strong className="price-value">≈245–290 ₽</strong>
              <span className="pb-2 text-lg text-white/45">за 1 час</span>
            </div>
            <p className="mt-3 max-w-2xl text-sm leading-6 text-white/48">
              Типичный звонок: две полные дорожки, постобработка, 12–20 вопросов
              и умеренный объём контекста. Фактическая сумма зависит от числа
              вопросов, длины диалога и материалов.
            </p>

            <div className="price-breakdown mt-8">
              <a
                href="https://developers.openai.com/api/docs/models/gpt-live-transcribe"
                target="_blank"
                rel="noreferrer"
              >
                <span>Live-распознавание двух дорожек</span>
                <strong>≈180 ₽</strong>
              </a>
              <a
                href="https://developers.openai.com/api/docs/models/gpt-transcribe"
                target="_blank"
                rel="noreferrer"
              >
                <span>Постобработка двух дорожек</span>
                <strong>≈47 ₽</strong>
              </a>
              <a
                href="https://developers.openai.com/api/docs/models/gpt-5.6-terra"
                target="_blank"
                rel="noreferrer"
              >
                <span>Подсказки и итоговый разбор</span>
                <strong>≈17–61 ₽</strong>
              </a>
            </div>
            <p className="mt-5 text-xs leading-5 text-white/30">
              Расчёт в рублях — по курсу ЦБ 87 ₽/$; OpenAI списывает API в
              долларах, поэтому итог в рублях зависит от курса банка. Для полного
              часового цикла разумно установить лимит не ниже ≈305 ₽.
            </p>
          </article>
        </div>
      </section>

      <section id="privacy" className="paper-section scroll-mt-18">
        <div className="site-container grid gap-14 py-24 lg:grid-cols-[1fr_1fr] lg:items-start sm:py-32">
          <div>
            <p className="section-kicker text-[#23845a]">
              Данные и приватность
            </p>
            <h2 className="section-title mt-3 max-w-xl text-[#141417]">
              Без маркетингового тумана.
            </h2>
            <p className="mt-6 max-w-xl text-lg leading-8 text-[#5c5b61]">
              Записи, контексты и история звонков хранятся на вашем компьютере.
              Для распознавания и ответов выбранные данные отправляются в OpenAI
              Platform по вашему API key.
            </p>
          </div>

          <div className="data-list">
            <div>
              <span className="data-icon">
                <HardDrive />
              </span>
              <div>
                <h3>На устройстве</h3>
                <p>
                  Исходные аудиодорожки, смешанная запись, транскрипты,
                  контексты, Q&A и журнал расходов.
                </p>
              </div>
            </div>
            <div>
              <span className="data-icon">
                <Sparkles />
              </span>
              <div>
                <h3>В OpenAI API</h3>
                <p>
                  Аудио для распознавания, полный доступный диалог и выбранные
                  контексты для подсказок и анализа.
                </p>
              </div>
            </div>
            <div>
              <span className="data-icon">
                <ShieldCheck />
              </span>
              <div>
                <h3>Под вашим контролем</h3>
                <p>
                  Вы выбираете источники, контексты, модели, формат ответа и
                  максимальный бюджет звонка.
                </p>
              </div>
            </div>
          </div>
        </div>
      </section>

      <section id="download" className="download-section scroll-mt-18">
        <div className="site-container py-24 sm:py-32">
          <div className="mx-auto max-w-3xl text-center">
            <p className="section-kicker text-[#9c8cff]">
              Скачать Callya 0.2.2
            </p>
            <h2 className="section-title mt-3 text-white">
              Готова к следующему звонку.
            </h2>
            <p className="mt-5 text-lg leading-8 text-white/52">
              Бесплатно, без аккаунта Callya. Исходники и сборки опубликованы на
              GitHub.
            </p>
          </div>

          <div className="download-grid mt-14">
            <article className="platform-card">
              <div className="platform-topline">
                <Apple />
                <span>macOS</span>
              </div>
              <h3>Universal build</h3>
              <p>macOS 14.2+ · Apple Silicon и Intel · DMG 6.8 MB</p>
              <a
                href={macDownloadUrl}
                className={cn(
                  buttonVariants({ size: 'lg' }),
                  'mt-8 h-12 w-full rounded-full bg-white text-[#111113] hover:bg-white/86',
                )}
              >
                <Download /> Скачать DMG
              </a>
              <div className="mt-4 flex items-center justify-between text-xs text-white/38">
                <a href={macZipUrl} className="hover:text-white">
                  ZIP-архив
                </a>
                <span>ad-hoc signed</span>
              </div>
              <p className="platform-note">
                Сборка пока не notarized — при первом запуске может понадобиться
                «Privacy & Security → Open Anyway».
              </p>
            </article>

            <article className="platform-card platform-card-accent">
              <div className="platform-topline">
                <Monitor />
                <span>Windows</span>
              </div>
              <h3>Self-contained x64</h3>
              <p>Windows 11 · всё необходимое внутри · ZIP 78.9 MB</p>
              <a
                href={windowsDownloadUrl}
                className={cn(
                  buttonVariants({ size: 'lg' }),
                  'mt-8 h-12 w-full rounded-full bg-[#9c8cff] text-white hover:bg-[#ad9fff]',
                )}
              >
                <Download /> Скачать ZIP
              </a>
              <div className="mt-4 flex items-center justify-between text-xs text-white/38">
                <a href={windowsChecksumUrl} className="hover:text-white">
                  SHA-256
                </a>
                <span>portable</span>
              </div>
              <p className="platform-note">
                Кодовая подпись пока отсутствует — Windows SmartScreen может
                показать предупреждение неизвестного издателя.
              </p>
            </article>
          </div>

          <a
            className="release-link"
            href={releaseUrl}
            target="_blank"
            rel="noreferrer"
          >
            Все версии и release notes <ExternalLink />
          </a>
        </div>
      </section>

      <section id="open-source" className="paper-section scroll-mt-18">
        <div className="site-container py-24 sm:py-32">
          <div className="source-panel">
            <div className="source-copy">
              <p className="section-kicker text-[#6858d6]">MIT License</p>
              <h2 className="section-title mt-3 text-[#141417]">
                Открыта целиком — не только лендинг.
              </h2>
              <p className="mt-6 max-w-2xl text-lg leading-8 text-[#5c5b61]">
                SwiftUI и Core Audio на macOS, WPF и WASAPI на Windows. Изучайте
                архитектуру, собирайте из исходников, открывайте issue и
                присылайте pull request.
              </p>
              <div className="mt-8 flex flex-col gap-3 sm:flex-row">
                <a
                  href={repositoryUrl}
                  target="_blank"
                  rel="noreferrer"
                  className={cn(
                    buttonVariants({ size: 'lg' }),
                    'h-12 rounded-full bg-[#18181b] px-6 text-white hover:bg-[#2a2a2f]',
                  )}
                >
                  <Code2 /> Открыть GitHub <ArrowUpRight />
                </a>
                <a
                  href={`${repositoryUrl}#build-from-source-macos`}
                  target="_blank"
                  rel="noreferrer"
                  className={cn(
                    buttonVariants({ variant: 'outline', size: 'lg' }),
                    'h-12 rounded-full border-black/12 bg-white px-6 text-[#222126] hover:bg-black/5',
                  )}
                >
                  <BookOpen /> Собрать из исходников
                </a>
              </div>
            </div>
            <div className="source-stack" aria-label="Технологии проекта">
              <span>
                <strong>macOS</strong>Swift 5.9 · SwiftUI · Core Audio
              </span>
              <span>
                <strong>Windows</strong>.NET 10 · WPF · WASAPI
              </span>
              <span>
                <strong>AI</strong>OpenAI Realtime + Responses API
              </span>
            </div>
          </div>
        </div>
      </section>

      <section className="faq-section">
        <div className="site-container grid gap-12 py-24 lg:grid-cols-[0.7fr_1.3fr] sm:py-32">
          <div>
            <p className="section-kicker text-[#9c8cff]">Вопросы</p>
            <h2 className="section-title mt-3 text-white">
              Перед первым звонком.
            </h2>
          </div>
          <div className="faq-list">
            {faqs.map((item) => (
              <details key={item.question}>
                <summary>
                  {item.question}
                  <span aria-hidden="true">+</span>
                </summary>
                <p>{item.answer}</p>
              </details>
            ))}
          </div>
        </div>
      </section>

      <footer className="border-t border-white/8 bg-[#0b0b0e]">
        <div className="site-container flex flex-col gap-6 py-8 text-sm text-white/38 sm:flex-row sm:items-center sm:justify-between">
          <div className="flex items-center gap-3">
            <Image
              src="/callya-icon.png"
              alt=""
              width={32}
              height={32}
              className="size-8 rounded-[9px]"
            />
            <span>© 2026 Callya · MIT License</span>
          </div>
          <div className="flex flex-wrap gap-x-6 gap-y-2">
            <a href={repositoryUrl} className="hover:text-white">
              GitHub
            </a>
            <a href={`${repositoryUrl}/issues`} className="hover:text-white">
              Issues
            </a>
            <a
              href={`${repositoryUrl}/blob/main/SECURITY.md`}
              className="hover:text-white"
            >
              Security
            </a>
          </div>
        </div>
      </footer>
    </main>
  );
}
