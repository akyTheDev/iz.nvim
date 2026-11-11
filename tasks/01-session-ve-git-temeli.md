# 01 · Session ve git temeli

## Amaç

UI olmadan çalışan, test edilebilir bir çekirdek kurmak. Bu çekirdek:
- `.iz/` dizinini kurar.
- Session oluşturur ve yükler.
- Base snapshot'ını alır.
- Hunk'ları hesaplar.
- Stage, unstage, discard ve undo işlemlerini yapar.

Sonraki bütün task'lar bu modüllerin üstüne kurulur.

Terimler için `CONTEXT.md`, kararlar için `docs/adr/0002-staging-is-the-approval-record.md`.

## Bağımlılık

Yok. İlk task.

## Aşamalar

### 1. Plugin iskeleti
- Dizin yapısı:
  - `lua/iz/init.lua`, `lua/iz/config.lua`
  - `lua/iz/git/`, `lua/iz/session/`, `lua/iz/storage/`
  - `plugin/iz.lua` (sadece komut kayıtları)
- `require("iz").setup(opts)` ile varsayılan config birleştirilir. Neovim 0.10+ kontrolü yapılır, eski sürümde açık bir hata verilir.
- Test altyapısı:
  - Headless Neovim ile çalışan bir test harness'ı (plenary.busted ya da mini.test, biri seçilir).
  - `make test` hedefi.
  - Her testin kendi geçici git reposunu kurduğu bir yardımcı.
- CI: GitHub Actions'ta Neovim stable ve nightly üzerinde testler.

### 2. Async git katmanı (`lua/iz/git/`)
- `vim.system` üzerine tek bir `git.run(args, opts, cb)` sarmalayıcısı yazılır. Sarmalayıcının özellikleri:
  - Repo kökünü bulur (`git rev-parse --show-toplevel`).
  - `stdin` desteği vardır; `git apply` için gerekiyor.
  - Hataları stderr ile birlikte döndürür.
- Testlerde ve komut zincirlerinde kullanmak için coroutine tabanlı bir `await` yardımcısı eklenir.
- Ana event loop hiçbir durumda bloklanmaz. Senkron çağrı sadece testlerde serbesttir.

### 3. `.iz/` dizini ve depolama (`lua/iz/storage/`)
- İlk kullanımda `.iz/` oluşturulur ve `.git/info/exclude`'a `/.iz/` satırı eklenir. Satır zaten varsa tekrar eklenmez. Kullanıcının `.gitignore` dosyasına hiç dokunulmaz.
- Atomic JSON yazımı: önce `session.json.tmp` yazılır, sonra `vim.uv.fs_rename` ile asıl dosyanın yerine konur.
- `session.json` şeması:
  - `schema_version`, `id`, `created_at`, `state` (`active` | `completed`)
  - `base` (commit hash)
  - `comments: []`: yorum alanları task 03'te dolacak.
- Okurken şema versiyonu kontrol edilir. Bilinmeyen bir versiyonda veri ezilmez, açık bir hata verilir.
- `.iz/current` dosyası aktif Session'ın id'sini tutar.

### 4. Lock
- `.iz/lock` dosyası Neovim'in PID'ini ve başlama zamanını tutar.
- Lock alma kuralı:
  - Dosya yoksa ya da içindeki PID artık yaşamıyorsa (`vim.uv.kill(pid, 0)`) lock alınır.
  - Aksi halde Session salt okunur açılır. Okuma modunun UI tarafı task 06'da.
- `VimLeavePre`'de lock bırakılır.

### 5. Base snapshot
- Session açılırken index'in bir snapshot'ı alınır:
  1. Mevcut index geçici bir dosyaya kopyalanır (`GIT_INDEX_FILE`).
  2. O anda var olan untracked dosyalar bu geçici index'e eklenir (`git add -A` + `.iz/` hariç). Böylece session başlamadan önce var olan untracked dosyalar "agent'ın yeni dosyası" gibi görünmez.
  3. `git write-tree` ile tree alınır.
  4. `git commit-tree` ile tree bir commit'e sarılır.
  5. Commit `refs/iz/sessions/<id>` ref'ine yazılır. Ref olmazsa `git gc` bu nesneyi zamanla silebilir.
- Index'te unmerged (conflict) girdiler varsa Session açılmaz ve sebebi söylenir.
- Base commit hash'i `session.json`'a yazılır.

### 6. Hunk modeli (`lua/iz/git/hunks.lua`)
- **Session hunk'ları:** `git diff --no-color -U0 <base> -- <path>`, yani Base ile working tree arasındaki fark. Untracked dosyalar için `git ls-files --others --exclude-standard` kullanılır; bu dosyalar "tamamı eklenmiş" tek bir hunk olarak modellenir.
- **Unstaged parçalar:** `git diff --no-color -U0 -- <path>`, yani index ile working tree arasındaki fark.
- **Sınıflandırma:**
  - Bir Session hunk'ının new-side aralığına düşen bir Unstaged parça yoksa hunk **Staged** sayılır.
  - Varsa **Unstaged** sayılır ve o parçaların satırları "index'e göre yeni" olarak işaretlenir. Bu bilgi task 02'de vurgu için kullanılacak.
- Hunk nesnesinde şu alanlar olur: `file`, `old_start`, `old_count`, `new_start`, `new_count`, `lines`, `state` (`staged` | `unstaged`), `new_vs_index` (satır aralıkları).
- Dosya özetinde şunlar tutulur: değişiklik tipi (A/M/D/R/?), +/- sayıları ve Staged ile Unstaged hunk sayıları.
- `.iz/` her durumda listeden çıkarılır.

### 7. Stage, unstage, discard
- **Stage (hunk):** Hunk'ın aralığıyla çakışan index ↔ working tree parçalarından sıfır bağlamlı bir patch üretilir. Patch `git apply --cached --unidiff-zero -` ile index'e uygulanır.
- **Unstage (hunk):** Base ↔ index farkındaki (`git diff --cached <base>`) çakışan parçalar ters olarak index'e uygulanır (`git apply --cached -R --unidiff-zero -`).
- **Discard (hunk):** Index ↔ working tree farkındaki çakışan parçalar working tree'ye ters uygulanır. Yani discard index'e kadar geri alır, onaylanmış kısım korunur.
- **Dosya seviyesi:**
  - Stage: `git add -- <path>`.
  - Unstage: `git restore --staged --source=<base> -- <path>`.
  - Discard: dosyanın working tree'deki hali index'e döner. Untracked bir dosya silinir, ama önce trash'e kopyalanır.
- Her yıkıcı işlemden önce patch `git apply --check` ile doğrulanır. Diff stale olmuşsa, yani dosya hesaplamadan sonra değişmişse, işlem yapılmaz, hunk'lar yeniden hesaplanır ve kullanıcıya söylenir.

### 8. Trash ve undo
- Discard edilen patch ya da dosya `sessions/<id>/trash/<timestamp>-<n>.patch` altına yazılır.
- Session başına son discard'ların bir yığını tutulur. `undo_discard()` en son patch'i working tree'ye geri uygular. Patch artık uygulanamıyorsa, kullanıcıya trash'teki dosyanın yolu gösterilir.
- Trash Session kapandığında silinmez.

## Kabul kriterleri
- Testler aşağıdaki senaryoları kapsar:
  - Boş repoda Session açma.
  - Staged ama commit edilmemiş değişiklik varken Session açma: bu değişiklikler diff'te görünmez.
  - Önceden var olan untracked dosya: diff'te görünmez.
  - Yeni dosya, silinen dosya, rename.
  - Hunk stage, unstage ve discard, ardından undo.
  - Stage edilmiş bir hunk'ın üstüne yeni değişiklik gelince hunk'ın Unstaged olması ve `new_vs_index` aralıkları.
  - Stale diff'te işlemin reddedilmesi.
- `git gc --prune=now` çalıştıktan sonra bile Base okunabilir.
- `.iz/` hiçbir listede görünmez ve `git status`'ta da çıkmaz.

## Notlar
- Agent'ın `git add` ya da commit yapması engellenmez veya tespit edilmez (ADR 0002).

## Uygulamada değişenler
- **Untracked dosyalar Base'e dahil değil ve her zaman "yeni" olarak görünüyor.** Planda, Session açılırken var olan untracked dosyalar Base'e dahil edilip gizlenecekti. Task 06'daki görsel provada bunun ana akışı bozduğu ortaya çıktı. Kullanıcı genelde `:Iz`'i agent çalıştıktan sonra açıyor, bu yüzden agent'ın oluşturduğu yeni dosyalar gizleniyordu. Karar geri alındı: davranış artık diğer git araçlarındaki gibi. Gürültü yapan dosyalar `.gitignore` ya da `.git/info/exclude` ile gizlenir.
- **Diff'ler tree'ler arasında hesaplanıyor.** Index ve working tree, geçici bir index (`GIT_INDEX_FILE`) üzerinden tree'ye çevriliyor, sonra `git diff-tree` ile karşılaştırılıyor. Kullanıcının gerçek index'ine sadece stage ve unstage işlemlerinde dokunuluyor.
- **Rename tespiti MVP'de yok** (`--no-renames`). Rename, bir silme ve bir ekleme olarak görünüyor; dosya listesindeki `R` tipi sonraya kaldı.
- **`git apply` her durumda atomik.** Ayrıca bir `--check` adımı yok: uygulama başarısız olursa hiçbir dosya değişmiyor ve "stale" hatası dönüyor.
