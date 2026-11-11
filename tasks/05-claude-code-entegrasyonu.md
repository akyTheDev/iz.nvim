# 05 · Claude Code entegrasyonu

## Amaç

Claude Code tarafını kurmak:
- `/iz` skill'i
- Stop hook ile "Claude bitirdi" bildirimi
- Bunları tek komutla kuran `:IzInstallClaude`
- Diğer agent'lar için `:IzExport`

MCP kullanılmaz.

## Bağımlılık

Task 04: Brief ve inbox.

## Aşamalar

### 1. Skill şablonu (`lua/iz/claude/skill.lua`)
- Skill içeriği plugin'in içinde sürümlü bir şablon olarak tutulur:
  ```markdown
  ---
  description: iz.nvim review'ındaki açık yorumları ele al
  allowed-tools: Bash(cat:*), Read, Edit, Write
  ---

  Aktif code review:

  !`cat .iz/brief.md`

  Kurallar:
  - Her yorumu belirtilen dosya:satır'da ele al, ilgisiz koda dokunma.
  - Görsel yolu verilmişse önce görseli aç ve incele.
  - Bitirince Brief'in sonundaki inbox dosyasına tek bir Write ile
    yorum başına bir JSON satırı yaz: {"id", "claim", "note"}
    (claim: addressed | declined | question).
  - .iz/ altındaki başka hiçbir dosyayı düzenleme.

  $ARGUMENTS
  ```
- Şablon, iz sürümünü içeren bir yorum satırı taşır. Böylece eski bir kurulum tespit edilebilir.
- Agent'ın git kullanımı hakkında kural yazılmaz (ADR 0002).

### 2. `:IzInstallClaude`
- Skill'i `~/.claude/skills/iz/SKILL.md` dosyasına yazar.
  - Dosya varsa ve kullanıcı tarafından değiştirilmişse, yani şablonun hiçbir sürümüyle eşleşmiyorsa, onay istenir ve eski dosya `.bak` olarak saklanır.
- Stop hook'u `~/.claude/settings.json`'a ekler:
  - JSON okunur, `hooks.Stop` dizisine iz'in girdisi eklenir. Girdi zaten varsa tekrar eklenmez.
  - Dosyanın diğer alanlarına dokunulmaz. Yazmadan önce bir `.bak` alınır.
  - Hook komutu `.iz/` olmayan projelerde hiçbir şey yapmaz:
    ```sh
    [ -d "$CLAUDE_PROJECT_DIR/.iz" ] && date +%s > "$CLAUDE_PROJECT_DIR/.iz/stop" || true
    ```
  - Hook komutu her durumda 0 ile çıkmalı ki Claude'un akışını bozmasın.
- Sonunda neyin nereye yazıldığı tek bir mesajla özetlenir.
- `:IzInstallClaude!` mevcut kurulumu kaldırır: skill dizinini ve hook girdisini siler.
- Uygulamadan önce, Claude Code'un o anki hook şeması ve `$CLAUDE_PROJECT_DIR` değişkeni güncel dokümantasyondan doğrulanır.

### 3. Stop sinyali
- Task 04'teki izleyici `.iz/stop` dosyasını da izler.
- Sinyal geldiğinde sırasıyla:
  1. Hunk'lar yeniden hesaplanır.
  2. Inbox işlenir.
  3. "Claude bitirdi · 4 Unstaged hunk · 2 cevap" bildirimi gösterilir.
- Bildirimden bir tuşla (ya da `:Iz`) workspace açılır.
- Workspace zaten açıksa sadece yenilenir.
- Sinyal dosyası işlendikten sonra silinir.

### 4. `:IzExport`
- Brief'i olduğu gibi, inbox talimatıyla birlikte, `+` register'ına kopyalar.
- Clipboard yoksa `"` register'ına kopyalar ve kullanıcıya söyler.
- Bekleyen yorum yoksa kopyalamaz, bildirir.

### 5. Sağlık kontrolü
- `:checkhealth iz` şunları kontrol eder:
  - Neovim sürümü
  - git
  - Skill kurulumu ve sürümü
  - Stop hook girdisi
  - Görsel araçları (`pngpaste` / `wl-paste` / `xclip`)
  - snacks.nvim (opsiyonel)

## Kabul kriterleri
- Temiz bir makinede `:IzInstallClaude` iki dosyayı da doğru yazar. İkinci çalıştırmada hiçbir şey değişmez.
- Mevcut bir `settings.json` içindeki diğer hook'lar ve ayarlar korunur. Bu, testle doğrulanır.
- Uçtan uca manuel test, gerçek Claude Code ile:
  1. İki yorum yaz.
  2. `/iz` çalıştır.
  3. Claude'un tek Write ile inbox dosyası oluşturduğunu, Neovim'in cevapları thread'e eklediğini ve Stop bildiriminin geldiğini doğrula.
- `.iz/` olmayan bir projede Claude durduğunda hiçbir dosya oluşmaz.
- `:IzExport` ile kopyalanan Brief başka bir agent'a verildiğinde, o agent inbox'a yazarsa cevaplar aynı şekilde içe alınır.

## Notlar
- Codex ve OpenCode için ayrı installer'lar yol haritasında. Bu task sadece Claude Code'u ve genel export'u kapsar.

## Uygulamada değişenler
- **Formatlar Claude Code'un güncel dokümantasyonundan doğrulandı** ([skills](https://code.claude.com/docs/en/skills.md), [hooks](https://code.claude.com/docs/en/hooks.md)):
  - `/iz` dizin adından otomatik geliyor.
  - `!` ile komut gömme ve `$ARGUMENTS` skill'lerde destekleniyor.
  - Stop hook'u matcher almıyor, `$CLAUDE_PROJECT_DIR` hook'a export ediliyor.
  - 0 ile ve çıktısız biten bir hook Claude'u etkilemiyor.
  - Bu yüzden `allowed-tools` belgelenmiş biçimde: `Bash(cat *) Read Edit Write`. Pratikte bu iznin `cat .iz/brief.md`'yi kapsadığı henüz denenmedi.
- **Stop her turda tetikleniyor**, sadece `/iz` turlarında değil. iz bu yüzden her turda yenileniyor; bu zararsız.
- **Sinyal workspace kapalıyken de dinleniyor** (`lua/iz/signal.lua`, `VimEnter` ve `DirChanged` ile başlıyor). Workspace kapalıysa "agent finished · run :Iz to review" bildirimi çıkıyor. Bildirimden tek tuşla açma yok, `:Iz` kullanılıyor.
- **`settings.json` yeniden yazılırken anahtar sırası ve biçim korunmuyor.** İçerik korunuyor ve önce `.bak` alınıyor. Geçersiz JSON'a hiç dokunulmuyor.
- **`:IzExport`, `.iz/brief.md` dosyasını olduğu gibi kopyalıyor.** Brief'i workspace güncel tutuyor.
- **Testlerin ortaya çıkardığı hata düzeltildi (racy git).** Geçici index kopyası yeni bir mtime alıyordu. Bu yüzden git, son index yazımıyla aynı saniyede yapılan ve boyutu değiştirmeyen düzenlemeleri görmüyordu. Artık kopya orijinal index'in zaman damgalarını taşıyor ve bunu bir regresyon testi koruyor.
- **Gerçek Claude Code ile uçtan uca manuel test henüz yapılmadı.** Hook komutu, installer ve inbox yolu otomatik testlerle doğrulandı.
