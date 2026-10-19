# Movento | Kentsel Mobilite ve Akıllı Lojistik

Movento, hızlı ticaret/kurye, IoT mikro-mobilite ve şehir içi yolculuk
hizmetlerini ortak operasyon, konum ve finans temeli altında birleştirir.
Marka adı proje için seçilmiştir; marka tescil uygunluğu araştırılmamıştır.

## Aşama 1 veritabanı temeli

İlk additive migration:

`supabase/migrations/20261018000000_stage1_platform_foundation.sql`

Migration PostgreSQL 15+ ve PostGIS 3 gerektirir. Supabase CLI uyumlu migration
dizininde tutulur; bu depoda henüz Supabase projesi, veritabanı bağlantısı veya
uygulama anahtarı yapılandırılmamıştır. Migration henüz bir veritabanına
uygulanmamıştır. Hedef veritabanı belirlendikten sonra önce yedekli geliştirme
ortamında deneyin. Doğrudan PostgreSQL kullanımında:

```sh
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 \
  -f supabase/migrations/20261018000000_stage1_platform_foundation.sql
```

Migration; tenant/rol izolasyonu ve RLS, sürümlü PostGIS servis bölgeleri,
servis tarafında üretilen H3 hücre indeksleri, filo/telemetri, gönderi, scooter
kiralama, sürücü-yolcu şehir yolculuğu ve güvenlik olayları, saha görevleri,
private medya referansları, idempotency ve çift taraflı ledger temelini tanımlar.
H3 hücre eşleştirmesi H3 kütüphanesinin sürümlenmiş servis katmanında üretilir;
kesin polygon ve sınır denetimi PostGIS tarafındadır.

### Güvenlik ve çalıştırma sınırları

- JWT `sub` değeri yalnızca doğrulanmış kimlik katmanından
  `request.jwt.claim.sub` (veya `request.jwt.claims`) bağlamıyla aktarılmalıdır.
  Doğrudan istemci veritabanı erişimine veya istemcinin bu bağlamı belirlemesine
  izin verilmemelidir.
- RLS etkinleştirilmiştir. Finansal işlem/fiyat, kilit açma, atama, teslimat
  durum geçişleri ve private medya erişimi doğrudan istemci yazımı olarak
  açılmaz; bunlar doğrulanan servis API'leri üzerinden uygulanmalıdır.
- Ledger işlemleri en az iki dengeli kayıt gerektirir; reversal, orijinal
  hesap hareketlerini ters işaretle birebir yansıtmalıdır. Para tutarları
  `bigint` minor unit, zaman damgaları `timestamptz` olarak saklanır.
- Telemetri, bölge sürümleri ve olaylar append-only'dir. Bu migration
  retention/partition zamanlayıcısı, servis API'leri, Auth, H3 hesaplama, IoT
  entegrasyonu ya da istemci arayüzlerini henüz oluşturmaz; bunlar sonraki
  adımlardır.

## Aşama 2 servis zamanı ve güvenilir API temeli

İkinci additive migration:

`supabase/migrations/20261018010000_stage2_service_runtime_foundation.sql`

Bu adım, güvenilir servis istemcilerini, görev kuyruğunu, retention politikalarını,
H3 runtime sürüm takibini ve IoT cihaz oturumlarını ekler. Amaç, Stage 1
veritabanı tabanının üzerinde güvenli, izlenebilir ve operasyona hazır bir
çalışma zamanı katmanı kurmaktır.

### Eklenen katmanlar

- `app.service_api_clients` ve `app.service_api_tokens`: hizmetler arası yetki
  ve token kayıtları
- `app.service_jobs` ve `app.retention_policies`: arka plan görevleri,
  retention ve bakım iş akışı
- `app.h3_library_versions`: H3 kitaplığı sürüm/pinned ayarı
- `app.iot_device_sessions`: cihaz ile sunucu arasındaki oturum ve görünüm
  durumu
- `app.service_event_logs`: servis tarafı olay izleme ve hata / izleme akışı

Bu migration, uygulama servisleri için kimlik doğrulama ve iş planlamasını
veritabanı katmanında tanımlar; doğrudan istemci erişimini açmaz, yalnızca
yetkili servis katmanları için RLS ve güvenli API sınırlarını oluşturur.
Servis istemcisi erişimi etkin istemcinin kendi tenant'ıyla sınırlandırılır;
servis tokenı ve cihaz oturumu foreign key'leri de tenant eşleşmesini zorunlu
kılar.

## Movento arayüz temeli

İlk web arayüzü Next.js App Router, TypeScript, Tailwind CSS ve Framer Motion
ile hazırlanmıştır. Sora ve Plus Jakarta Sans yazı tipleri `next/font` üzerinden
yüklenir. `src/app/globals.css` marka ve hizmet modu tokenlarını içerir;
Yemek/Kurye modu mercan, Yolculuk modu mor-indigo aksan kullanır. Ana sayfadaki
harita görünümü yalnızca tasarım maketidir ve canlı operasyon verisi göstermez.

```sh
npm install
npm run dev
```

Üretim derlemesi ve statik kalite kontrolleri:

```sh
npm run lint
npm run typecheck
npm run build
```

Cüzdan ve profil navigasyonu görsel iskelet olarak gösterilir, ilgili ürün
sayfaları henüz uygulanmamıştır. Gerçek sipariş, kurye, araç, harita ve kimlik
entegrasyonları bu arayüz temelinin kapsamı dışındadır.
