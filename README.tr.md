# iz.nvim

[English](README.md) | **Türkçe**

AI agent'ının yazdığı kodu Neovim'den çıkmadan incele, satır satır yorum gönder ve iş bitene kadar cevaplarını kontrol et.

```
:Iz  →  incele, stage'le, yorum yaz  →  Claude Code'da /iz  →  agent düzeltir ve cevaplar  →  :Iz  →  … → :IzDone
```

- **Stage'lemek onay demek.** Beğendiğin Hunk'ı stage'le. Bir sonraki turda sadece henüz onaylamadıkların görünür; agent'ın onaylı kodun üstüne yaptığı değişiklikler de buna dahil.
- **Yorumlar satırıyla birlikte gider.** Agent, ilgilenmesi gereken her yorum için `dosya:satır` içeren kısa bir Brief (`.iz/brief.md`) alır, belirsiz bir paragraf değil.
- **Agent iddia eder, sen karar verirsin.** Agent `addressed`, `declined` ya da `question` diye cevaplar; bir yorumu çözülmüş saymak yalnızca sana kalır.
- **Her görev için bir Session.** Her Session açıldığı andaki bir anlık görüntüyle karşılaştırılır, böylece önceki görevin commit'lenmemiş işi araya karışmaz.

MCP sunucusu ya da arka planda çalışan bir süreç yok: Neovim ve agent yalnızca `.iz/` içindeki dosyalar üzerinden konuşur.

## Gereksinimler

- Neovim 0.10+ (karakter düzeyinde diff vurgusu için 0.12 önerilir)
- git
- İsteğe bağlı: yorumlara ekran görüntüsü yapıştırmak için `pngpaste` (macOS), `wl-paste` ya da `xclip` (Linux)

## Kurulum

[lazy.nvim](https://github.com/folke/lazy.nvim) ile:

```lua
{
  "akythedev/iz.nvim",
  version = "*", -- son sürüm; main'i takip etmek için kaldır
  cmd = { "Iz", "IzDone", "IzExport", "IzInstallClaude" },
  opts = {},
}
```

Ardından bir kez:

```vim
:IzInstallClaude
```

Bu komut `/iz`, `/iz-coreview` ve `/iz-summary` skill'lerini `~/.claude/skills/` altına yazar ve `~/.claude/settings.json` dosyasına bir Stop hook'u ekler; böylece iz, agent'ın turunu ne zaman bitirdiğini bilir. Hook, `.iz/` olmayan projelerde hiçbir şey yapmaz. `settings.json`'ın yanına bir yedek yazılır ve `:IzInstallClaude!` ikisini de geri kaldırır. Kurulumu `:checkhealth iz` ile kontrol edebilirsin.

## Döngü

1. Agent'a bir görev ver.
2. `:Iz` çalışma alanını açar: solda dosyalar, ortanın solunda Base, ortanın sağında çalışma ağacı, yorum varsa en sağda yorum paneli.
3. Onayladığını stage'le, onaylamadığına yorum yaz.
4. Claude Code'da `/iz` çalıştır. Brief'i okur, kodu düzeltir ve cevaplarını `.iz/inbox/` altına yazar.
5. iz cevapları ve değişiklikleri alır. Filtreyle (`<leader>if` / `f`) sadece henüz onaylamadıklarını görürsün.
6. Düzeltmesini kontrol ettiğin yorumları çözülmüş say ya da cevap yazıp geri gönder.
7. Görev bitince `:IzDone`, ardından bir sonrakine `:Iz` ile başla.

Başka bir agent mı kullanıyorsun? `:IzExport`, inbox talimatlarıyla birlikte Brief'i panoya kopyalar. Dosya yazabilen her agent cevap verebilir.

## Co-reviewer

Büyük işlerde ilk bakışı ikinci bir agent'a bırak. Agent işini bitirince Claude Code'da `/iz-coreview` çalıştır: co-reviewer temiz bir context'te başlar, commit'lenmemiş değişiklikleri okur ve bulgularını `.iz/coreview/` altına yazar. Koda dokunmaz, agent'la konuşmaz.

Komuttan sonra kendi review skill'ini ya da neye odaklanacağını yazarsan co-reviewer varsayılanı (hatalar, eksik durumlar ve riskler; stil yok) yerine onu izler:

```
/iz-coreview code-review
/iz-coreview check error handling in the new endpoints
```

`:Iz`'i aç: bulgular panelde "Suggested by the co-reviewer" başlığı altında ve diff'te satır içinde durur. Sen karar verene kadar hiçbiri agent'a gitmez:

- `s` öneriyi olduğu gibi gönderir (thread'e "sent to the agent" düşer).
- `a` kendi notunla gönderir.
- `i` yok sayar; `I` göndermediğin bütün önerileri yok sayar.

Kendi yorumlarını da ekle, sonra her zamanki gibi `/iz` çalıştır: agent gönderdiğin her şeyi tek Brief'te alır, her thread'de co-reviewer, sen ve agent bir arada görünür.

## Özetler

Diff neyin değiştiğini gösterir; nedenini sadece agent bilir. Büyük bir işten sonra aynı Claude Code konuşmasında `/iz-summary` çalıştır: agent en az 20 satırı değişen her dosya için bir ile üç cümlelik bir özeti `.iz/summaries/` altına yazar (`/iz-summary 50` eşiği yükseltir).

`:Iz`'de özeti olan dosyanın diff'inin iki tarafının üstünde "agent says" etiketli bir şerit çıkar. Bu agent'ın iddiasıdır, hüküm değil: kodu yine de oku. Özetten sonra dosya değişirse şerit "outdated" der. Özeti olmayan dosyada şerit çıkmaz. Hiç göstermemek için `summary_height = 0`.

## Tuşlar

| Nerede | Tuş | İşlem |
| --- | --- | --- |
| Dosya listesi | `<CR>` | dosyayı diff'te aç ve ilk hunk'ına git |
| | `s` / `u` / `x` | dosyayı stage'le / unstage'le / değişiklikleri at |
| | `U` | son atmayı geri al |
| | `c` | dosyaya yorum yaz |
| | `f` | "sadece unstaged" filtresini aç/kapat |
| | `p` | yorum paneline git (panelin içindeyken: kapat) |
| | `R` / `q` | yenile / kapat |
| Her yerde | `?` (diff'te: `<leader>i?`) | bu penceredeki tuşları listele |
| Diff | `]h` / `[h` | sonraki / önceki hunk (sonraki dosyaya geçer) |
| | `<leader>is` / `iu` / `ix` | hunk'ı stage'le / unstage'le / at (visual: aralıktaki tüm hunk'lar) |
| | `<leader>iU` | son atmayı geri al |
| | `<leader>ic` | satıra yorum yaz (visual: aralığa) |
| | `<leader>iC` | hunk'a yorum yaz |
| | `<leader>ik` | bu satırdaki yorumun thread'ini oku |
| | `<leader>il` | dosya listesine dön |
| | `<leader>if` / `ip` / `iq` | filtre / panele git / kapat |
| Panel | `<CR>` | thread'i (konuşmanın tamamı) aç ve kodunu göster |
| | `a` | cevap yaz |
| | `r` / `i` / `o` | çözüldü / yok say / yeniden aç |
| | `s` | co-reviewer önerisini agent'a olduğu gibi gönder |
| | `I` | gönderilmemiş bütün co-reviewer önerilerini yok say |
| | `m` | yorumu diff'teki imlecin olduğu satıra taşı |
| Thread | `a` / `r` / `i` / `o` | cevap yaz / çözüldü / yok say / yeniden aç |
| | `s` | gönder (co-reviewer önerileri) |
| | `q` / `<Esc>` | kapat |
| Yorum editörü | `<C-s>` ya da `:w` | kaydet |
| | `q` | vazgeç |
| | `<C-v>` (insert) | ekran görüntüsü yapıştır (görüntü yoksa normal `<C-v>`) |

Dosya listesinin başlığı ilerlemeyi gösterir: stage'lenen hunk sayısı / toplam ve açık yorumlar. Listede imleçle gezinirken her dosya diff'te görünür, sen listede kalırsın; `<CR>` dosyanın içine geçer. Kapatmak için `preview_on_move = false`.

Diff penceresindeki tuşlar `<leader>i` ile başlar, çünkü sağ taraf senin gerçek dosyandır ve düzenlenebilir kalır. Kendi düzenlemelerin de agent'ınkiler gibi Unstaged olarak görünür. `<leader>if`, `ip`, `il` ve `iq` dosya listesinde ve panelde de çalışır.

## Komutlar

| Komut | |
| --- | --- |
| `:Iz` | çalışma alanını açar, aktif Session yoksa yenisini başlatır |
| `:Iz comment` | Session'ın tamamına yorum yazar (ekran görüntüsü eklenebilir) |
| `:Iz history` | geçmiş Session'ları ve thread'lerini gösterir |
| `:IzDone` | Session'ı kapatır; açık yorumlar onayından sonra yok sayılır |
| `:IzExport` | Brief'i herhangi bir agent için kopyalar |
| `:IzInstallClaude[!]` | Claude Code skill'lerini ve hook'unu kurar (ya da kaldırır) |

## Ayarlar

Varsayılanlar, hepsi isteğe bağlı:

```lua
require("iz").setup({
  files_width = 42,
  panel_width = 56,
  summary_height = 5, -- diff'in üstündeki agent özetinin satır sayısı; 0 gizler
  preview_on_move = true, -- diff, dosya listesindeki imleci takip eder
  thread = { width = 0.6, height = 0.6 }, -- thread penceresi, ekranın oranı olarak
  keymaps = {
    paste_image = "<C-v>",
    files = { open = "<CR>", stage = "s", unstage = "u", discard = "x", undo_discard = "U",
              toggle_filter = "f", comment = "c", toggle_panel = "p", refresh = "R", close = "q",
              help = "?" },
    diff = { stage = "<leader>is", unstage = "<leader>iu", discard = "<leader>ix",
             undo_discard = "<leader>iU", toggle_filter = "<leader>if", comment = "<leader>ic",
             comment_hunk = "<leader>iC", open_thread = "<leader>ik",
             toggle_panel = "<leader>ip", focus_files = "<leader>il",
             next_hunk = "]h", prev_hunk = "[h", close = "<leader>iq", help = "<leader>i?" },
    panel = { jump = "<CR>", reply = "a", resolve = "r", ignore = "i", reopen = "o",
              send = "s", ignore_suggestions = "I", move = "m", close = "q", help = "?" },
  },
})
```

Bir tuşu kapatmak için `""` ver. Vurgu grupları (`IzStaged`, `IzNewSinceApproval`, `IzComment`, `IzClaim`, …) `default = true` ile tanımlıdır, yani renk temaların bunları ezebilir.

## Dosyalar

`.iz/` deponun kökünde durur ve `.git/info/exclude` dosyasına eklenir; `.gitignore` dosyana hiç dokunulmaz.

```
.iz/
├── brief.md        agent'ın okuduğu dosya (Neovim yazar)
├── inbox/          agent cevapları, her Brief için bir dosya (agent yazar)
├── coreview/       co-reviewer önerileri (co-reviewer yazar)
├── summaries/      dosya özetleri (agent yazar)
├── current         aktif Session'ın id'si
└── sessions/<id>/  session.json, atılan hunk'lar (trash/), ekran görüntüleri (assets/)
```

## Geliştirme

```sh
make test
```

Alan dili [CONTEXT.md](CONTEXT.md) dosyasında, katkı verenler ve agent'lar için kurallar [AGENTS.md](AGENTS.md) dosyasında (ikisi de İngilizce).
