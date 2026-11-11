# 04 · Brief ve inbox

## Amaç

Agent ile iz arasındaki iki yönlü kanalı kurmak:
- Neovim, Claude'dan cevap bekleyen yorumları token açısından ekonomik bir **Brief**'e (`.iz/brief.md`) derler.
- Agent cevaplarını Brief başına açılan bir inbox dosyasına tek bir Write ile yazar.
- Neovim bu cevapları Reply olarak `session.json`'a alır.

## Bağımlılık

Task 03: yorum modeli, `awaiting_agent`, Anchor relocation.

## Aşamalar

### 1. Brief formatı (`lua/iz/brief.lua`)
- Brief'e sadece `awaiting_agent` yorumlar girer.
- Brief id'si `b_` + 4 hex olur. Her üretimde yeni bir id alınır. Son id `session.json`'da tutulur, böylece hangi inbox dosyasının hangi Brief'e cevap olduğu bilinir.
- Yapı:
  ```markdown
  # iz brief b_0193 · 2 yorum

  ## Session
  c_91de: <gövde>. Görsel: <yol>

  ## src/services/auth.ts
  c_7f2a L42: <kök mesaj>
    claude: <Claude'un son notu>
    sen: <senin son cevabın>

  Cevaplarını .iz/inbox/b_0193.jsonl dosyasına tek bir Write ile yaz.
  ```
- Kurallar:
  - Önce session yorumları gelir, sonra dosyalar yol sırasıyla. Dosya yolu her dosya için bir kez yazılır.
  - Satır numarası relocation sonrası güncel numaradır. Aralıklar `L42-48` şeklinde yazılır. Hunk yorumunda hunk'ın aralığı, file yorumunda satır yerine `dosya` yazılır.
  - Thread'den sadece kök mesaj, Claude'un son notu (varsa) ve senin son mesajın gider. Aradaki mesajlar atlanır.
  - Kod snippet'i sadece iki durumda eklenir: Anchor lost ise (son bilinen satır ve snippet ile birlikte "yeri bulunamadı" notu) ve `side = "old"` ise (silinen satırların içeriği Base'den alınır).
  - Görsel ekleri repo köküne göre yol olarak verilir.
  - Bekleyen yorum yoksa Brief tek satırdır: `Bekleyen yorum yok.` (inbox satırı olmadan).
- Brief'teki metinler ayrıca kısaltılmaz. Gövdeyi kullanıcı yazdığı için olduğu gibi gider.

### 2. Brief'in güncel tutulması
- `awaiting_agent` kümesini ya da Anchor'ları etkileyen her değişiklikten sonra Brief yeniden üretilir: yorum yazma, Reply, Status değişimi, relocation.
- Yazma atomiktir (tmp + rename) ve debounce edilir.
- İçerik değişmediyse dosya yeniden yazılmaz ve Brief id'si değişmez.

### 3. Inbox izleyicisi (`lua/iz/watcher.lua`)
- `.iz/inbox/` dizini `vim.uv.new_fs_event` ile izlenir. Dosya değil dizin izlenir, çünkü Write aracı dosyayı baştan yazar.
- Olaylar debounce edilir. Dosya okunmadan önce boyutunun sabitlendiği kontrol edilir.
- Neovim açılırken inbox'ta kalmış dosyalar da işlenir.

### 4. Cevapları içe alma
- Her satır JSON olarak parse edilir: `{"id","claim","note"}`.
- Doğrulama kuralları:
  - Bilinmeyen bir yorum id'si atlanır ve kullanıcıya bildirilir.
  - `claim` değeri `addressed`, `declined` veya `question` dışındaysa satır reddedilir.
  - Son satır yarım kalmışsa (sonunda newline yok ve parse edilemiyor) dosya henüz işlenmez, bir sonraki olay beklenir.
- Geçerli her satır, zaman damgasını Neovim'in eklediği bir `{author="agent", claim, body=note, ts}` Reply'ı olarak thread'e eklenir.
- Aynı yorum için birden fazla satır gelirse hepsi sırayla eklenir. Claim son satırdan türer.
- Bütün satırlar işlenince dosya silinir. Hatalı satır varsa dosya `inbox/failed/` altına taşınır ve kullanıcıya bildirilir.
- Bir yorum agent cevap yazmadan önce kullanıcı tarafından resolve ya da ignore edildiyse Reply yine thread'e eklenir, Status değişmez.

### 5. Bildirim
- İçe alma sonrasında şu bildirim gösterilir: "Claude 3 yoruma cevap verdi · 1 soru".
- Panel ve diff'teki rozetler güncellenir.

## Kabul kriterleri
- Brief testleri:
  - Örnekteki formatta, dosyaya göre gruplu üretim.
  - Lost Anchor ve old side için snippet ekleme.
  - Bekleyen yorum yokken tek satır çıktı.
  - İçerik değişmezse id'nin korunması.
- Inbox testleri:
  - Geçerli dosyanın içe alınması ve silinmesi.
  - Bilinmeyen id.
  - Geçersiz claim.
  - Yarım satır.
  - Neovim kapalıyken gelen dosyanın açılışta işlenmesi.
- 20 yorumluk bir Session'da Brief, yorum başına ortalama tek satırda kalır (thread'i olmayan yorumlar için).

## Notlar
- Agent'ın `session.json`'a ya da Brief'e yazması beklenmez. Tek yazar kuralı: agent sadece inbox'a, Neovim sadece kendi dosyalarına yazar.

## Uygulamada değişenler
- **Brief İngilizce ve agent'tan bağımsız.** Etiketler `agent:` ve `reviewer:`; dokümandaki örnekte `claude:` ve `sen:` vardı. Agent'ın gözünden "sen" belirsiz kalıyordu. Görseller ayrı bir `image:` satırında.
- **Brief id'si içeriğin hash'ine bağlı.** `session.json`'da Brief'in metni değil, `{id, hash}` tutuluyor. Dosya sadece içerik değiştiğinde yeniden yazılıyor.
- **Sonunda newline olmayan son satır kabul ediliyor.** Write aracı sondaki newline'ı atlayabiliyor. Son satır parse edilemiyor ve sonunda newline yoksa dosya "henüz yazılıyor" sayılıp bir sonraki olayda tekrar deneniyor. Ayrı bir boyut-sabitlenme kontrolü yok; bunun yerine 150 ms'lik debounce var.
- **Inbox ayrı bir modülde.** `lua/iz/inbox.lua` (parse, ingest, summary) workspace'ten bağımsız. İzleme işi workspace'teki `watch_dir` ile yapılıyor; ayrı bir `watcher.lua` yok.
- **Salt okunur bir Neovim inbox'ı işlemiyor ve Brief yazmıyor** (tek yazar).
- Brief formatı Claude'a özgü değildir. `:IzExport` (task 05) aynı Brief'i diğer agent'lara verir.
