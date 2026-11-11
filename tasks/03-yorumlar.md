# 03 · Yorumlar, thread'ler ve Anchor

## Amaç

Line, hunk, file ve session kapsamlarında yorum yazmak, thread olarak cevaplamak ve kapatmak. Bunlara ek olarak:
- Kod değiştikçe yorumların yerini (Anchor) korumak.
- Session yorumlarına screenshot eklemek.

## Bağımlılık

Task 01 (`session.json`) ve task 02 (workspace, diff buffer'ları).

## Aşamalar

### 1. Veri modeli (`lua/iz/session/comments.lua`)
- `session.json` içindeki `comments[]` için şema şu alanları içerir:
  - `id`, `scope` (`line` | `hunk` | `file` | `session`)
  - `file`, `side` (`new` | `old`), `line`, `end_line`
  - `anchor` = { `snippet`, `context_before`, `state` (`found` | `lost`) }
  - `status` (`open` | `resolved` | `ignored`)
  - `attachments[]`
  - `thread[]` = { `author` (`user` | `agent`), `body`, `claim`?, `ts` }
- Claim saklanmaz, hesaplanır: `claim(comment)` son mesaj agent'ınsa onun claim'ini, değilse `nil` döner.
- İki türetilmiş küme tanımlanır:
  - `awaiting_agent(comment)`: Status `open` ve son mesaj kullanıcının.
  - `awaiting_user(comment)`: Status `open` ve son mesaj agent'ın.
- Id üretimi kısa ve Session içinde benzersiz olmalı (`c_` + 4 hex).
- Her değişiklik task 01'in atomic yazımıyla diske gider.

### 2. Yorum yazma
- Tuşlar:
  - Diff'te `c` imlecin olduğu satıra ya da görsel seçime line yorumu açar.
  - `C` hunk yorumu açar.
  - Dosya listesinde `c` file yorumu açar.
  - `:Iz comment` session yorumu açar.
- Old side'daki (silinen) bir satıra yazılan yorumda `side = "old"` olur ve satır numarası Base'e göre tutulur.
- Editör floating bir buffer'dır (`filetype=markdown`). `<C-s>` ya da `:w` kaydeder, `q` ya da `<Esc><Esc>` iptal eder. Boş bir gövde kaydedilmez.
- Aynı editör mevcut bir thread'e Reply yazmak için de kullanılır. Reply yazınca Claim düşer ve yorum tekrar `awaiting_agent` olur.

### 3. Gösterim
- **Diff'te:** satırın altında, extmark `virt_lines` ile yazar, kısaltılmış gövde ve Claim rozeti (`addressed` / `declined` / `question`) gösterilir. Old side yorumları sol buffer'da gösterilir.
- **Yorum paneli (`lua/iz/ui/panel.lua`):**
  - Session'daki yorumlar dosya ve satır sırasıyla, thread'leriyle birlikte listelenir.
  - Gruplar: önce sana dönenler (`awaiting_user`), sonra Claude'a gidecekler, en sonda kapalılar (katlanmış).
  - `<CR>` yorumun yerine gider.
- **Panelin görünürlüğü:** Session'da en az bir yorum varsa açık, yoksa kapalıdır. Bir tuş (`gc`) her durumda açıp kapatır.
- **Dosya listesi:** açık yorum sayısı burada da güncellenir (task 02'deki 0 değeri dolar).

### 4. Status işlemleri
- Panelde ve diff'te:
  - `r` resolve eder.
  - `i` ignore eder.
  - `o` yeniden açar (kapalı bir yorumu tekrar `open` yapar).
- Agent hiçbir durumda Status değiştiremez. Bu kural kod seviyesinde tek bir `set_status` fonksiyonunda tutulur.

### 5. Anchor yakalama ve relocation (`lua/iz/session/anchor.lua`)
- **Yakalama:** yorum yazılırken şunlar kaydedilir:
  - `snippet`: yorumlanan satır(lar), sağ ve sol boşlukları kırpılmış.
  - `context_before`: önceki 1–2 boş olmayan satır.
- **Relocation**, dosya değişince ve Brief üretilmeden önce çalışır:
  1. Kayıtlı satırda snippet aynen duruyorsa Anchor yerinde.
  2. Durmuyorsa dosyada snippet'in tam eşleşmeleri aranır, `context_before` ile doğrulanır ve eski konuma en yakın olan seçilir.
  3. Doğrulanan bir eşleşme yoksa `anchor.state = "lost"` olur. Status değişmez.
- Fuzzy eşleştirme yapılmaz.
- `side = "old"` yorumları Base'e bağlıdır ve relocation'a girmez.
- Lost bir yorum diff'te dosyanın başında, panelde ise "yeri bulunamadı" etiketiyle gösterilir. Kullanıcı yorumu bir tuşla imlecin olduğu satıra taşıyabilir (`m`).
- **Extmark:** buffer açıkken yorumlar extmark'la takip edilir. Kayıtta satır numarası extmark'tan güncellenir. Relocation sadece buffer dışındaki değişikliklerde (agent'ın yazdığı dosya) devreye girer.

### 6. Screenshot ekleri
- Yorum editöründe `<C-v>` şöyle çalışır:
  1. Clipboard'da görsel var mı kontrol edilir: macOS'ta `pngpaste`, Linux'ta `wl-paste --list-types` ya da `xclip -t TARGETS`.
  2. Varsa görsel `sessions/<id>/assets/<timestamp>.png` olarak kaydedilir, buffer'a `![](<göreli yol>)` eklenir ve `attachments[]` güncellenir.
  3. Yoksa Vim'in normal `<C-v>` davranışı çalışır.
- Tuş config ile değiştirilebilir. Gerekli araç yoksa kullanıcıya bir kez bilgi verilir.
- snacks.nvim kuruluysa ve terminal destekliyorsa (Kitty, WezTerm, Ghostty) görsel `snacks.image` ile önizlenir. Değilse sadece yol gösterilir.

## Kabul kriterleri
- Dört kapsamda da yorum yazılabiliyor, thread'e Reply eklenebiliyor ve resolve/ignore/reopen çalışıyor.
- Bir Reply sonrasında Claim'in düştüğü ve yorumun `awaiting_agent` kümesine geçtiği testle doğrulanır.
- Relocation testleri:
  - Üstüne satır eklenince yorum doğru satıra kayar.
  - Snippet iki yerde varsa `context_before` doğru olanı seçer.
  - Satır silinince Anchor lost olur ve Status `open` kalır.
  - Old side yorumları değişmez.
- Görsel yapıştırma macOS'ta çalışır. Clipboard'da görsel yokken `<C-v>` normal davranır.
- Panel yorum yokken kapalı açılır, ilk yorumla birlikte açılır.

## Notlar
- Bir yorumun "Claude'a gidecek" kümesine girmesi Brief'i etkiler. Brief'in üretimi task 04'te; bu task sadece `awaiting_agent` kümesini hazır eder.

## Uygulamada değişenler
- **Tuşlar:** diff penceresinde `<leader>ic` satır yorumu (görsel modda aralık), `<leader>iC` hunk yorumu, `<leader>ip` panel aç/kapa. Dosya listesinde `c` dosya yorumu, `p` panel. Spec'teki `gc` kullanılmadı, çünkü Neovim 0.10+'da yorum satırı operatörü. Panelde reply tuşu `a`.
- **Relocation kuralı sıkılaştırıldı.** Kayıtlı satırda snippet hâlâ duruyor ama bağlam tutmuyorsa ve bağlamı tutan başka bir aday varsa, yorum o adaya taşınıyor. Aday yoksa yerinde kalıyor; bu, üstteki satır düzenlendiğinde yorumun yerinde kalmasını sağlıyor.
- **Açık buffer'da extmark takibi yapılmadı.** Relocation her kayıtta (`BufWritePost` → refresh) diskteki dosya üzerinde çalışıyor; bu, kullanıcının düzenlemelerini de kapsıyor. Kaydedilmemiş düzenlemeler sırasında yorumlar eski satırında görünür.
- **snacks.image önizlemesi yapılmadı.** Görselin yolu buffer'da markdown linki olarak duruyor. Önizleme MVP sonrasına kaldı.
- **macOS'ta `pngpaste` zorunlu değil.** Kurulu değilse AppleScript ile panodan PNG okunuyor. Görsel yokken yol 84 ms'de `false` dönüyor ve normal `<C-v>` çalışıyor. Gerçek bir görselin yapıştırılması elle test edilmedi.
