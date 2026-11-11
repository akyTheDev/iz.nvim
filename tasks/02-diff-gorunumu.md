# 02 · Diff görünümü ve review workspace'i

## Amaç

Task 01'in çekirdeğini görsel bir review ekranına bağlamak:
- Solda dosya listesi.
- Ortada Neovim'in yerleşik diff modu ile side-by-side diff.
- Sağda yorum paneli için ayrılmış bir alan (panelin kendisi task 03'te).

Diff iz tarafından çizilir, harici bir diff plugin'i kullanılmaz (ADR 0001).

## Bağımlılık

Task 01: Session, Base, hunk modeli, stage/unstage/discard.

## Aşamalar

### 1. Workspace düzeni (`lua/iz/ui/workspace.lua`)
- `:Iz` ayrı bir tabpage açar. Aktif Session yoksa task 01'in API'si ile yeni bir Session oluşturulur; kapatma akışı task 06'da.
- Pencere düzeni: dosya listesi (sabit genişlik) | sol diff | sağ diff | yorum paneli yeri.
- Tab kapanınca ya da `q` ile workspace kapanırken, iz'in açtığı scratch buffer'lar temizlenir. Gerçek dosya buffer'larına dokunulmaz.
- Workspace ikinci kez açılırsa yeni bir tab açılmaz, mevcut tab'a geçilir.

### 2. Dosya listesi (`lua/iz/ui/files.lua`)
- Her satırda şunlar bulunur:
  - Değişiklik tipi (A/M/D/R/?)
  - Dosya yolu
  - `+n -m`
  - Açık yorum sayısı. Task 03 gelene kadar 0.
  - Review durumu: hepsi staged / kısmen / hiçbiri. Durum her zaman hem bir simge hem bir kelimeyle gösterilir, sadece renkle gösterilmez.
- Dizine göre gruplama yapılır, uzun yollar kısaltılır.
- `<CR>` dosyayı diff'te açar, `j`/`k` ile gezilir. `s`, `u` ve `x` dosya seviyesinde stage, unstage ve discard yapar.
- Tüm dosyalar staged ise satır soluk gösterilir.

### 3. Side-by-side diff (`lua/iz/diff/`)
- `diff/backend.lua` arayüzü: `open(file, left_rev)`, `refresh()`, `hunk_at(lnum)`, `close()`. İlk ve tek implementasyon native diff modu.
- **Sol taraf:** salt okunur bir scratch buffer. İçeriği `git show <base>:<path>` ile alınır, filtre açıkken `git show :<path>` (index) ile. Silinen ya da yeni dosyalarda bu taraf boş olur. `filetype` gerçek dosyadan alınır, böylece syntax highlight çalışır.
- **Sağ taraf:** gerçek dosya buffer'ı, düzenlenebilir. Kullanıcının düzenlemeleri de Unstaged sayılır.
- İki pencerede `:diffthis` çalıştırılır. Karakter seviyesinde vurgu için `diffopt` önerileri (`linematch`, varsa `inline:char`) sadece bu pencerelere uygulanır, global ayar değiştirilmez.
- Satır hizalama ve scroll senkronu native diff modundan gelir.

### 4. Hunk durumunun gösterimi
- Staged hunk'lar soluk bir highlight grubu ile ve satır başında `✓ staged` virtual text'iyle gösterilir. Katlanmazlar.
- Kısmen onaylı hunk'larda (`new_vs_index`) index'e göre yeni olan satırlar ayrı bir highlight ile vurgulanır.
- Highlight grupları `IzStaged`, `IzNewSinceApproval` vb. ve hepsi `default = true` ile tanımlanır, böylece kullanıcı ezebilir.

### 5. Sadece bakılmamışlar filtresi
- Bir tuş (varsayılan `f`) sol tarafı Base ile index arasında değiştirir. Index'e geçince staged hunk'lar diff'ten kaybolur ve sadece Unstaged olanlar kalır.
- Dosya listesi de filtreye uyar: tamamı staged olan dosyalar gizlenir.
- Filtre durumu workspace'e özel tutulur ve bir statusline/winbar göstergesiyle belli edilir.

### 6. Hunk işlemleri ve gezinme
- `]h` / `[h` ile sonraki/önceki hunk'a gidilir, dosya sonunda bir sonraki dosyaya geçilir.
- `s`, `u` ve `x` imlecin altındaki hunk'ı stage, unstage ve discard eder. Görsel modda seçili aralıkla çakışan hunk'larda çalışır. `U` son discard'ı geri alır.
- Bütün tuşlar config'den değiştirilebilir ve sadece iz buffer'larında tanımlıdır.

### 7. Yenileme
- Şu olaylarda hunk'lar yeniden hesaplanır (debounce ile):
  - Gerçek dosyada `BufWritePost`
  - `FocusGained`
  - Index dosyasında değişiklik (`.git/index` üzerinde fs_event)
  - Stop sinyali (task 05)
- Yenileme sırasında imleç konumu ve açık dosya korunur.

## Kabul kriterleri
- 50+ dosyalık bir diff'te workspace bir saniyenin altında açılır ve git çağrıları UI'ı dondurmaz.
- Staged, Unstaged ve kısmen onaylı hunk'lar görsel olarak ayırt edilebilir. Bu, ekran görüntüsüyle kontrol edilir.
- Filtre açıkken stage edilen hunk ekrandan kaybolur, kapalıyken soluk görünür.
- Sağ tarafta yapılan bir düzenleme kaydedilince Unstaged hunk olarak görünür.
- `.iz/` dosya listesinde hiç görünmez.

## Notlar
- Inline görünüm MVP dışında, ama `diff/backend.lua` arayüzü inline modu da taşıyabilecek şekilde tasarlanır.
- Yorum panelinin yeri bu task'ta sadece ayrılır. Panel varsayılan olarak kapalıdır ve task 03'te dolar.

## Uygulamada değişenler
- **Diff penceresi tuşları `<leader>i` önekiyle geliyor** (`<leader>is` stage, `<leader>iu` unstage, `<leader>ix` discard, `<leader>iU` undo, `<leader>if` filtre, `<leader>iq` kapat). Sebep: sağ taraf gerçek ve düzenlenebilir bir dosya, `s`/`u`/`x` orada Vim'in kendi komutlarını ezerdi. Dosya listesi salt okunur olduğu için orada `s`, `u`, `x`, `U`, `f`, `R`, `q` ve `<CR>` kullanılıyor. `]h`/`[h` her iki yerde de aynı.
- **`diffopt` değiştirilmiyor.** Bu seçenek global, pencereye özel ayarlanamıyor. Karakter seviyesindeki vurgu kullanıcının `diffopt` ayarından geliyor; Neovim 0.12'nin varsayılanında `inline:char` ve `linematch` zaten açık.
- **Ölçüm:** 80 değişmiş dosyada view hesaplaması yaklaşık 60 ms sürüyor.
- **Kaydedilmemiş değişiklik varken hunk işlemleri reddediliyor.** Sağ taraftaki dosyada kaydedilmemiş bir değişiklik varsa iz "önce kaydet" der, çünkü git diskteki dosyayı görüyor.
- Görsel kontrol (ekran görüntüsü) henüz yapılmadı. Testler extmark'ları ve buffer içeriğini doğruluyor.
