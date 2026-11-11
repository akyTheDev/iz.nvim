# 06 · Session yaşam döngüsü ve son dokunuşlar

## Amaç

Task'lar arası geçişi tamamlamak ve MVP'yi kullanılabilir hale getirmek:
- `:IzDone` ile Session kapatma
- `:Iz` ile yeni Session
- Salt okunur mod
- "Session bitti gibi" önerisi
- Dokümantasyon

## Bağımlılık

Task 01–05.

## Aşamalar

### 1. `:Iz`
- Aktif Session varsa workspace onunla açılır. Yoksa yeni bir Session oluşturulur: Base snapshot, `.iz/current` ve boş bir Brief.
- Değişiklik yoksa Session yine açılır, ama ekranda "Base'den bu yana değişiklik yok" mesajı gösterilir.
- Komutlar MVP için dört tanedir: `:Iz`, `:IzDone`, `:IzExport`, `:IzInstallClaude`. Session yorumu gibi alt işlemler `:Iz comment` şeklinde alt komutlarla verilir.

### 2. `:IzDone`
- Açık yorum yoksa:
  - Session `completed` olur.
  - `.iz/current` temizlenir ve Brief "Bekleyen yorum yok." haline gelir.
- Açık yorum varsa tek bir seçim sunulur (`vim.ui.select`):
  - "N açık yorumu ignored olarak kapat ve bitir"
  - "Vazgeç"
- Carry over yok.
- Kapatma sonrası şu bildirim gösterilir: "Session kapandı. Claude Code'da `/clear` önerilir."
- `refs/iz/sessions/<id>` ref'i silinmez, history için kalır.

### 3. "Session bitti gibi" önerisi
- Şu iki koşul birlikte sağlandığında iz bunu bir kez bildirir: "Session bitti gibi, `:IzDone`?"
  - Unstaged hunk sayısı 0'a indi.
  - `awaiting_user` yorum yok.
- Bildirim Session başına bir kez gösterilir. Durum bozulup tekrar oluşursa yeniden gösterilir.

### 4. Salt okunur mod
- Lock başka bir canlı Neovim'deyse (task 01) workspace salt okunur açılır. Bu modda:
  - Stage, discard ve yorum işlemleri devre dışıdır.
  - Winbar'da "salt okunur: başka bir Neovim bu Session'ı düzenliyor" yazar.
- Lock serbest kalınca, bir sonraki odaklanmada yazma moduna geçmek önerilir.

### 5. History
- `:Iz history` kapanmış Session'ları tarih ve yorum sayısıyla listeler. Seçilen Session salt okunur açılır: diff Base ile o Session'ın son durumu arasında değil, sadece yorumlar ve thread'ler gösterilir.
- Bu adım MVP için opsiyonel. Zaman kalmazsa yol haritasına taşınır.

### 6. Dokümantasyon
- `README.md`:
  - Kurulum (lazy.nvim örneği)
  - `:IzInstallClaude`
  - Temel akış (diyagramdaki 7 adım)
  - Varsayılan tuşlar tablosu
  - Config örneği
- `doc/iz.txt`: Vim help dosyası. `:help iz` ile komutlar, tuşlar, highlight grupları ve config.
- README'de terimler `CONTEXT.md`'ye bağlanır, mimari kararlar için ADR'lere link verilir.

### 7. Uçtan uca prova
- Gerçek bir projede iki ardışık task ile tam döngü çalıştırılır:
  1. Task ver, review et, yorum yaz.
  2. `/iz` çalıştır, cevapları kontrol et, Reply ile itiraz et.
  3. Tekrar `/iz` çalıştır, resolve et, stage et.
  4. `:IzDone`, ardından yeni task için `:Iz`.
- Bulunan sorunlar issue olarak açılır.

## Uygulamada değişenler
- **Salt okunur moddan yazmaya geçiş otomatik.** Önerilmiyor, doğrudan yapılıyor: odak geri geldiğinde (`FocusGained`) lock alınabiliyorsa Neovim Session'ı devralıyor ve bunu bildiriyor.
- **`:Iz history` hafif tutuldu.** Seçilen Session'ın yorumları ve thread'leri salt okunur bir sekmede gösteriliyor; diff gösterilmiyor.
- **`:IzDone` workspace açık değilken de çalışıyor.** Lock'u alıp aktif Session'ı kapatıyor.
- **Uçtan uca prova tmux içinde gerçek bir Neovim ile yapıldı.** Agent, inbox ve Stop hook taklit edildi; gerçek Claude Code ile prova henüz yapılmadı. Prova testlerin kaçırdığı dört sorunu buldu, hepsi düzeltildi ve regresyon testiyle korunuyor:
  1. Agent'ın Session'dan önce oluşturduğu dosyalar gizleniyordu (task 01 notuna bakın).
  2. Hiç onaylanmamış hunk'ların her satırı "onaydan sonra yeni" diye işaretleniyordu.
  3. Sol taraftaki değişmemiş bir satıra yazılan yorum "silinmiş satır" sayılıyordu; artık sağ taraftaki karşılığına bağlanıyor.
  4. `.iz/` Neovim açıldıktan sonra oluşunca Stop sinyali dinlenmiyordu, ve agent'ın değiştirdiği açık dosya ekranda yenilenmiyordu.

## Kabul kriterleri
- İki ardışık Session'da, ilk task'ın commit edilmemiş ama staged değişiklikleri ikinci Session'ın diff'inde görünmez.
- `:IzDone` açık yorumla çalıştırıldığında hiçbir yorum sessizce kaybolmaz: ya ignored olur ya da işlem iptal edilir.
- Aynı repo iki Neovim'de açıldığında ikincisi salt okunur açılır ve `session.json` bozulmaz.
- README'deki kurulum adımları temiz bir Neovim config'inde baştan sona çalışır.
