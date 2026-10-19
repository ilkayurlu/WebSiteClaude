"use client";

import { AnimatePresence, motion, MotionConfig } from "framer-motion";
import {
  ArrowDown,
  ArrowRight,
  ArrowUpRight,
  Bike,
  CarFront,
  CircleUserRound,
  Clock3,
  Compass,
  MapPin,
  Package,
  Wallet,
  Zap,
} from "lucide-react";
import { useState } from "react";

type Mode = "yemek" | "yolculuk";

const modeContent = {
  yemek: {
    label: "Yemek & kurye",
    eyebrow: "İHTİYACIN OLDUĞU ANDA",
    title: "Şehir, tek\nakışta.",
    description:
      "Günlük ihtiyaçların ve şehir içi gönderilerin, aynı kolay deneyimde buluşsun.",
    primaryAction: "Kurye deneyimini keşfet",
    Icon: Package,
    accent: "#ff4d4d",
    accentEnd: "#ff8a3d",
    accentContrast: "#ff8a3d",
    accentForeground: "#0a0a12",
    mapLabel: "Kurye ağı",
    cardTitle: "Şehir içi teslimat",
    cardDescription: "Gönderi ve teslimat deneyimi",
  },
  yolculuk: {
    label: "Yolculuk & hareket",
    eyebrow: "ŞEHRİN RİTMİNE UY",
    title: "Hareket,\nsana göre.",
    description:
      "Elektrikli mikro-mobiliteden şehir içi yolculuğa, şehrin içinde özgürce ilerle.",
    primaryAction: "Hareket deneyimini keşfet",
    Icon: Bike,
    accent: "#6d28d9",
    accentEnd: "#4338ca",
    accentContrast: "#c4b5fd",
    accentForeground: "#ffffff",
    mapLabel: "Hareket ağı",
    cardTitle: "Elektrikli hareket",
    cardDescription: "Mikro-mobilite ve yolculuk",
  },
} satisfies Record<
  Mode,
  {
    label: string;
    eyebrow: string;
    title: string;
    description: string;
    primaryAction: string;
    Icon: typeof Package;
    accent: string;
    accentEnd: string;
    accentContrast: string;
    accentForeground: string;
    mapLabel: string;
    cardTitle: string;
    cardDescription: string;
  }
>;

const navigationItems = [
  { label: "Keşfet", Icon: Compass, enabled: true },
  { label: "Yemek", Icon: Package, mode: "yemek" as const, enabled: true },
  { label: "Yolculuk", Icon: CarFront, mode: "yolculuk" as const, enabled: true },
  { label: "Cüzdan", Icon: Wallet, enabled: false },
  { label: "Profil", Icon: CircleUserRound, enabled: false },
];

function scrollToSection(
  id: string,
  block: ScrollLogicalPosition = "start",
) {
  const target = document.getElementById(id);
  const behavior = window.matchMedia("(prefers-reduced-motion: reduce)").matches
    ? "auto"
    : "smooth";

  target?.scrollIntoView({ behavior, block });
}

export function DesignPreview() {
  const [mode, setMode] = useState<Mode>("yemek");
  const content = modeContent[mode];

  return (
    <MotionConfig reducedMotion="user" transition={{ duration: 0.22, ease: "easeOut" }}>
      <main className="app-shell" data-mode={mode}>
        <header className="site-header">
          <a className="brand" href="#ana-icerik" aria-label="Movento ana sayfa">
            <span className="brand-mark" aria-hidden="true">
              <Zap size={20} strokeWidth={2.8} />
            </span>
            <span className="brand-name">movento</span>
          </a>

          <nav className="desktop-nav" aria-label="Ana menü">
            {navigationItems.map(({ label, Icon, enabled, mode: itemMode }) => {
              const active = itemMode === mode;
              const className = [
                "nav-item",
                active ? "is-active" : "",
                enabled ? "" : "is-upcoming",
              ]
                .filter(Boolean)
                .join(" ");

              if (!enabled) {
                return (
                  <span
                    aria-disabled="true"
                    className={className}
                    key={label}
                    title="Bu bölüm sonraki geliştirme aşamasında açılacak"
                  >
                    <Icon size={17} aria-hidden="true" />
                    {label}
                  </span>
                );
              }

              return (
                <button
                  aria-pressed={itemMode ? active : undefined}
                  className={className}
                  key={label}
                  onClick={() => {
                    if (itemMode) {
                      setMode(itemMode);
                      return;
                    }
                    scrollToSection("ana-icerik");
                  }}
                  type="button"
                >
                  <Icon size={17} aria-hidden="true" />
                  {label}
                </button>
              );
            })}
          </nav>

          <span className="header-note">
            <span className="status-dot" />
            Tasarım önizlemesi
          </span>
        </header>

        <div className="preview-banner" role="status">
          <span>ÜRÜN TASARIMI</span>
          <span>
            Bu önizlemede gerçek araç, kurye veya sipariş verisi gösterilmez.
          </span>
        </div>

        <section className="hero" id="ana-icerik" aria-labelledby="hero-title">
          <div className="hero-copy">
            <motion.div
              animate={{ color: content.accentContrast }}
              className="eyebrow"
              key={`${mode}-eyebrow`}
            >
              <span className="eyebrow-line" />
              {content.eyebrow}
            </motion.div>

            <AnimatePresence mode="wait" initial={false}>
              <motion.div
                animate={{ opacity: 1, y: 0 }}
                className="hero-copy-content"
                exit={{ opacity: 0, y: 10 }}
                initial={{ opacity: 0, y: 10 }}
                key={mode}
                transition={{ duration: 0.25, ease: "easeOut" }}
              >
                <h1 id="hero-title">{content.title}</h1>
                <p className="hero-description">{content.description}</p>

                <button
                  className="primary-action"
                  onClick={() => scrollToSection("hizmet-onizlemesi", "center")}
                  type="button"
                >
                  {content.primaryAction}
                  <ArrowUpRight size={18} aria-hidden="true" />
                </button>
              </motion.div>
            </AnimatePresence>

            <div className="mode-picker" aria-label="Deneyim modunu seç">
              <span className="mode-picker-label">ÖNİZLEME MODU</span>
              <div className="mode-toggle" role="group" aria-label="Mod seçimi">
                {(["yemek", "yolculuk"] as const).map((item) => {
                  const selected = mode === item;
                  const ItemIcon =
                    item === "yemek" ? Package : Bike;
                  const label = modeContent[item].label;

                  return (
                    <button
                      aria-pressed={selected}
                      className={`mode-option${selected ? " is-selected" : ""}`}
                      key={item}
                      onClick={() => setMode(item)}
                      type="button"
                    >
                      <ItemIcon size={17} aria-hidden="true" />
                      {label}
                    </button>
                  );
                })}
              </div>
            </div>
          </div>

          <div className="hero-visual" aria-label={`${content.label} arayüz örneği`}>
            <motion.div
              animate={{ backgroundColor: content.accent, opacity: 0.12 }}
              className="visual-glow"
              transition={{ duration: 0.5 }}
            />
            <div className="visual-topline">
              <span className="visual-window-dots" aria-hidden="true">
                <i />
                <i />
                <i />
              </span>
              <span className="visual-caption">MOVENTO / CITY VIEW</span>
              <span className="visual-live-label">DEMO</span>
            </div>

            <div className="map-preview">
              <div className="map-grid" aria-hidden="true" />
              <svg
                aria-hidden="true"
                className="route-art"
                fill="none"
                preserveAspectRatio="none"
                viewBox="0 0 520 380"
              >
                <path
                  className="route-shadow"
                  d="M-20 278 C 50 278, 50 170, 142 170 S 218 302, 292 258 S 349 96, 422 142 S 473 219, 544 92"
                />
                <motion.path
                  animate={{ pathLength: 1, stroke: content.accent }}
                  d="M-20 278 C 50 278, 50 170, 142 170 S 218 302, 292 258 S 349 96, 422 142 S 473 219, 544 92"
                  initial={{ pathLength: 0 }}
                  transition={{ duration: 0.8, ease: "easeInOut" }}
                />
              </svg>

              <div className="map-street street-one" aria-hidden="true" />
              <div className="map-street street-two" aria-hidden="true" />
              <div className="map-street street-three" aria-hidden="true" />
              <div className="map-street street-four" aria-hidden="true" />

              <div className="map-label map-label-one">KARAKÖY</div>
              <div className="map-label map-label-two">GALATA</div>
              <div className="map-label map-label-three">ŞİŞHANE</div>

              <motion.div
                animate={{ backgroundColor: content.accent }}
                className="map-origin"
                transition={{ duration: 0.5 }}
                title="Başlangıç noktası örneği"
              >
                <span />
              </motion.div>
              <motion.div
                animate={{ backgroundColor: content.accentEnd }}
                className="map-destination"
                transition={{ duration: 0.5 }}
                title="Varış noktası örneği"
              >
                <MapPin size={18} fill="currentColor" />
              </motion.div>

              <div className="map-mode-card">
                <div className="map-mode-icon">
                  <content.Icon size={18} aria-hidden="true" />
                </div>
                <div>
                  <span>{content.mapLabel}</span>
                  <strong>{content.cardTitle}</strong>
                </div>
                <ArrowRight size={17} aria-hidden="true" />
              </div>

              <div className="map-scale">
                <span />
                <span />
                <span />
              </div>
            </div>

            <div className="visual-footer">
              <span>
                <Clock3 size={15} aria-hidden="true" />
                Canlı veri bağlı değil
              </span>
              <span>ARAYÜZ KONSEPTİ</span>
            </div>
          </div>

          <a className="scroll-cue" href="#hizmet-onizlemesi">
            Tasarım sistemini keşfet
            <ArrowDown size={15} aria-hidden="true" />
          </a>
        </section>

        <section
          className="service-preview"
          id="hizmet-onizlemesi"
          aria-labelledby="services-title"
        >
          <div className="section-heading">
            <div>
              <span className="section-kicker">TEK ŞEHİR, ÇOK İHTİYAÇ</span>
              <h2 id="services-title">Bir ağın parçası.</h2>
            </div>
            <p>
              Ürün sayfalarının ve içeriklerin kapsamı sonraki adımda birlikte
              netleştirilecek.
            </p>
          </div>

          <div className="service-cards">
            <ServiceCard
              accent="delivery"
              description="Yerel teslimat ve ekspres kurye deneyimi için tasarım alanı."
              Icon={Package}
              label="01 / TESLİMAT"
              title="İhtiyacın, yola çıksın."
            />
            <ServiceCard
              accent="mobility"
              description="Elektrikli scooter, e-bisiklet ve filo keşfi için tasarım alanı."
              Icon={Bike}
              label="02 / MİKRO-MOBİLİTE"
              title="Şehir senin rotan."
            />
            <ServiceCard
              accent="journey"
              description="Şehir içi yolculuk deneyimi için tasarım alanı."
              Icon={CarFront}
              label="03 / YOLCULUK"
              title="Daha rahat ilerle."
            />
          </div>
        </section>

        <footer className="site-footer">
          <a className="brand footer-brand" href="#ana-icerik">
            <span className="brand-mark" aria-hidden="true">
              <Zap size={17} strokeWidth={2.8} />
            </span>
            <span className="brand-name">movento</span>
          </a>
          <span>Şehir, tek akışta.</span>
          <span>Ürün tasarım önizlemesi · 2026</span>
        </footer>

        <nav className="mobile-nav" aria-label="Mobil menü">
          {navigationItems.map(({ label, Icon, enabled, mode: itemMode }) => {
            const active = itemMode === mode;
            const className = [
              "mobile-nav-item",
              active ? "is-active" : "",
              enabled ? "" : "is-upcoming",
            ]
              .filter(Boolean)
              .join(" ");

            if (!enabled) {
              return (
                <span
                  aria-disabled="true"
                  className={className}
                  key={label}
                  title="Sonraki aşamada"
                >
                  <Icon size={19} aria-hidden="true" />
                  <span>{label}</span>
                </span>
              );
            }

            return (
              <button
                aria-pressed={itemMode ? active : undefined}
                className={className}
                key={label}
                onClick={() => {
                  if (itemMode) {
                    setMode(itemMode);
                    return;
                  }
                  scrollToSection("ana-icerik");
                }}
                type="button"
              >
                <Icon size={19} aria-hidden="true" />
                <span>{label}</span>
              </button>
            );
          })}
        </nav>
      </main>
    </MotionConfig>
  );
}

function ServiceCard({
  accent,
  description,
  Icon,
  label,
  title,
}: {
  accent: "delivery" | "mobility" | "journey";
  description: string;
  Icon: typeof Package;
  label: string;
  title: string;
}) {
  return (
    <article className={`service-card ${accent}`}>
      <div className="service-card-top">
        <span className="service-icon">
          <Icon size={19} aria-hidden="true" />
        </span>
        <span className="service-card-label">{label}</span>
      </div>
      <div>
        <h3>{title}</h3>
        <p>{description}</p>
      </div>
      <span className="service-card-arrow" aria-hidden="true">
        <ArrowUpRight size={18} />
      </span>
    </article>
  );
}
