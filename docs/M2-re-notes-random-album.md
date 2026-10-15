# M2 RE notes — random-album button: tap dispatch + play path

Static decodes of `usr/bin/hiby_player` (stock v1.6, 4.6 MB stripped MIPS32r2),
done without QEMU (test bed busy). Companion to the litegui touch decode in
`M1-bringup-log.md` v0.77 (touch poller 0x4728a0, event processor 0x472988,
pump 0x435600 → 0x47c9c0 → 0x47caa0, list handler 0x433f00 case-4/8 at
0x434314, jump table 0x75c2a0, hit-test 0x4326e0).

Method: `tools/vendors/mipsel-linux-musl-cross/bin/mipsel-linux-musl-objdump -d`
full disassembly + a lui/addiu-pair and gp-relative xref pass
(_gp = 0x8B8240, computed from the PIC prologue at 0x40bbec:
`lui gp,0x4b; addiu gp,gp,-14764; addu gp,gp,t9`). eh_frame FDEs only cover
the codec C++ parts, so function starts were derived from call targets
(jal + t9 lui/addiu pairs) — 6547 starts, good but approximate for
never-called functions.

## 1. litegui view/callback model

- Every widget is an `lg_view` (log tag strings "lg_view" 0x76992c,
  "lg_viewgroup" 0x761bd4, "lg_imageview" 0x75c038, "lg_textview" 0x75c100).
  Function-pointer fields on the view object; each setter logs its own name on
  NULL arg ("lg_view_set_radiu param error" 0x761b50, "…_bg_color…" 0x761b70,
  "…_background…" 0x761b94), which names the API family.
- Setters decoded (all in 0x456b00–0x456e00, each `sw a1,OFF(a0)` + error log):
  view+124 (get 0x456be0 / set 0x456bc0), +236 (0x456c60), +240 (0x456ca0),
  +244 + zeroing +280 (0x456ce0), +300 (0x456c20), +304/308/312
  (0x456d40/d60/d80), +96 char[16] strncpy 16 (0x456c00).
- **view+124 = page-controller backlink.** The hiby page code stores its ctrl
  there (`456bc0(view, ctrl)`) and fetches it with `456be0(view)`.

## 2. hglview (the list/grid engine) — tap-select dispatch

Constructor **0x432300** allocates the state (malloc 0x19418 B) and installs
default trampolines:

| state off | default | meaning |
|---|---|---|
| +656 | 0x4305c0 | `j 465c00; a0 = state->348` |
| +660 | 0x430540 | `j 465c20; a0 = state->348` |
| **+664** | **0x4305a0** | `j 465c00; a0 = state->352` — tap-confirmed |
| **+668** | **0x430520** | `j 465c20; a0 = state->352` — item selected |
| +672 | 0x430580 | `j 465c00; a0 = state->364` |
| +676/+680/+684 | 0x430500/560/4e0 | via state->356/364 |

`465c00/465c20 = virtual invokers` on the object stored at state+348/+352/+356/+364
(allocated in the ctor via 0x465bc0). Pages customize behavior by replacing
those objects (writers of +352: 0x4348e8/0x4349ac/0x434a70/0x434c04/0x435918),
NOT by overwriting +664/+668 (only overrides found: 0x432348 both=v1,
0x4451a8, 0x52a378, and two zero-stores 0x43ff74/0x6610d4).

**Touch-up select path — 0x4335c0(list, event, mode)** (extends the M1 decode):

```
mode 5  -> 0x433894 (scroll settle)
mode 6  (touch-up):
  abs(state->288 - state->324) == 0 else scroll-settle, no tap
  abs(state->284) < 5 else no tap            (5-px threshold, 0x4336b8)
  state->544 == 1 else no tap                (press-state gate, 0x4336c4)
  t9 = state->664; jalr t9(state)            (tap-confirmed, 0x4336d4)
  walk item chain: s1 = state->52; next = s1->0 (list head at +52, node->0)
    hit-test 0x4326e0(s1->8)                 (item rect vs event, 0x433718)
    on hit: item->193 = 0 (byte)
            push 4 words item->128,132,136,140 onto stack (sp+24..36)
            t9 = state->668; jalr t9(state)  (SELECT, record on stack, 0x433758)
            if item still set: 0x457140(s1->8, sp+24)
  state->548 / 572 / 564 follow-up (0x433778..): 456920(state->564, 1)
mode 100 -> state->548 gate, state->572->8 vs state->592 compare (0x43361c)
```

The 4-word record (item+128..140) is the payload the page's select callback
consumes — contents per widget type; pin dynamically in Phase B by logging it.

## 3. The hiby page system (settings AND main_category share it)

- **Master layout loader 0x4961e0** (huge, ~0x4961e0–0x49a000): per .view file,
  strcmp-dispatch on view names; for `"hiby_main_category"` (0x77ce04):
  `0x503ee0(page, name)`, then `0x432820(page, "vg_main_category_hiby" 0x77cdec, n)`
  (create/find viewgroup by name), then `0x503d80(page, item)`.
- **Category page builder 0x503ee0** (also called from 0x4ee788, 0x4f12b8,
  0x500ebc, 0x535560 with the same name; 0x53aec4 passes "timeout" 0x798714):
  - ctrl = malloc 40 B: `ctrl->12 = page; ctrl->8 = malloc 356 B` (hglview
    descriptor), filled by 0x505980(name, desc).
  - `0x433220(page, 0x503a00, ctrl)` — registers the page-activate handler,
    returns page-instance → `ctrl->4`.
  - `0x456bc0(viewgroup_node, ctrl)` — backlink (view+124 = ctrl).
  - `0x456e40(node, 0x503b40)` and `0x456d80(node, 0x503b20)` — draw +
    event-forward callbacks.
  - `0x48f1a0(page->36, ctrl->8, 0)` → count; `0x434820(page, ctrl->8+260, 1)`
    and `0x434820(page, sp_desc, count)` — wire callback descriptors.
  - Cell loop: `n = vtable call +48 on view->252` (item count); per index
    `0x457b00(view, i)` → 144 B cell struct; inline-compares cell name against
    "lg_viewgroup" / "lg_imageview"; else `strstr(cell->32, 0x78c540)` and
    copies `cell->400/404` into `ctrl->32/36`.
- **0x434820(page, descriptor_array, count)** — the descriptor→widget wiring:
  for each 96 B descriptor {+0 name[64], +64..+92: 8 callback ptrs}:
  `485b40(page->36, name, "viewgroup")` → node; `node->216->320 = 0x430100`
  (second loop type-checks node->208 against 0x76bc80); copies descriptor
  +64→obj+352, +68→+356, +72→+360, +76→+364, +80→+368, +84→+372, +88→+376,
  +92→+380. **This is how a page's select callback reaches the hglview.**
- **Page-activate handler 0x503a00(ctrl, …)**: strncpy ctrl->4->0 (name 64 B),
  `s1 = ctrl->4->80` (hglview state), `432820(s1, "pull_down_menu_iv_spdif"
  0x78c144, ctrl->16)`, `4f9880(s1)`, `ctrl->12->556 = 1`, then
  0x47bc00/0x432180/0x431f80(s1, name) + 0x485a40(s1->36, name) — the same
  4-call sequence as the shared loader 0x4c64a0 — then hides ctrl->8 and
  tail-calls **0x4c64a0(ctrl->28)** if set.
- **Shared page-load routine 0x4c64a0(x)**: builds 64 B name from x->84 or
  x->4->0, then 0x47bc00(s1, name), 0x432180(s1, name), 0x431f80(s1, name),
  0x485a40(s1->36, name) (s1 = x->4->80), hides x->8; broadcast loop: for each
  node in x->4 chain call `node->16(node->12)` — registered per-node callbacks
  (same shape as the 0x498e00 loop in the loader).
- 0x503d80/0x503e20/0x503e80 = tiny per-event entry points that resolve
  `vg_main_category_hiby` (0x4865e0 lookup with type string "viewgroup" 0x769540),
  fetch ctrl via 0x456be0, then jump 0x4c6600 (`ctrl->4->56 = arg`) /
  0x4c64a0 / store arg to +24 (setter for the activate arg).
- Caveat: 0x505980/0x505ae0 (descriptor fill) are only partially decoded —
  0x505ae0 stores a pointer to static 0x89ac4c; the static tables at 0x89a820
  (3 × 356 B) and 0x89ac4c decode as small ints, not code pointers, so either
  the descriptor callbacks are filled elsewhere or the wiring count from
  0x48f1a0 is 0 for these pages and the category hglview runs on the DEFAULT
  trampolines with the object at state+352 set by 0x4349xx during events.
  Phase B (dynamic) should settle this by logging state+352/+668 on the
  category page.

## 3b. Category cell tap dispatch — RESOLVED (static)

The per-cell tap→action mapping is a static descriptor table in .rodata,
looked up BY NAME:

- **0x87a820**: three 356-byte page-template records
  {name[260]: `hiby_main_category.view` / `hiby_wireless.view` /
  `hiby_set.view`, config} — this is what 0x505980 matches page names
  against (earlier confusion resolved: the +260 config copy comes from here).
- **0x87ac4c + n·0x60**: 96-byte per-cell records {name[72], 6 ptrs}:

  | name @ | +72 | +76 | +88 | +92 |
  |---|---|---|---|---|
  | `main_category_vg_all` 0x87ac4c | … | … | 0x505440 | 0x5055c0 |
  | `main_category_vg_explorer` 0x87acac | 0x504f40-ish set | | 0x505440 | 0x5055c0 |
  | **`main_category_vg_album` 0x87ad0c** | **0x504ee0** | 0x5052a0 | 0x505440 | 0x5055c0 |
  | `main_category_vg_artist` 0x87ad6c | … | … | 0x505440 | 0x5055c0 |
  | `main_category_vg_genre` 0x87adcc | … | … | 0x505440 | 0x5055c0 |
  | `main_category_vg_format` 0x87ae2c | … | … | 0x505440 | 0x5055c0 |
  | `wireless_vg_bt/wifi/via/hibylink/dlna/airplay` 0x87ae8c+ | | | | |
  | `main_category_vg_album_artist` 0x87b0cc | … | … | 0x505440 | 0x5055c0 |
  | `main_category_vg_song_list` 0x87b12c | … | … | 0x505440 | 0x5055c0 |
  | `main_category_vg_set` 0x87b18c | … | … | 0x505440 | 0x5055c0 |

  (note the table contains `main_category_vg_format`, `…_song_list`,
  `…_set`, `sys_set_vg`, `audio_set_vg` — cells the code adds at runtime on
  the scroll-range's outer pages; they are NOT in the .view files. Collision
  risk for a static cell placed on those pages is real — prefer verifying
  placement on screen.)
- **`main_category_vg_album` record decoded word-exact**:
  +72 = 0x504ee0 (tap → open album list), +76 = 0x5052a0 (per-cell
  focus/refresh), +88/+92 = 0x505440/0x5055c0 (shared by every record).
- **0x504ee0(page, evt) = "open the album list"**: `s0 = evt->80` (the
  hglview state), `70e380(s0->40)`, `504a60(s0)`, then the master loader
  **0x4961e0(s0, "vg_listview_album" 0x77bbc8, cfg)** — the album list is
  loaded in-place into the same page (no activity switch). Sibling handlers
  load `vg_listview_artist` (0x504f40) etc.
- Wiring path: 0x434820 resolves the cell name (485b40), then copies the
  record's ptrs into the widget's node->216 object (+352..380); the record's
  +72 lands at obj+360, +76 at obj+364. Which obj slot the hglview select
  (+668 → 465c20(state->352)) ultimately reaches is the one remaining
  dynamic question — Phase B's RSEL log plus a gdbstub session on the
  category page settles it in minutes.

**Phase D hook design (updated):** descriptor lookup is by cell name, so the
clean wiring is: append a new 96-byte record `main_category_vg_random` to the
table (any free .rodata space — e.g. the tail after 0x87b5xx records or the
cave used by the PoC patch, with the lookup adjusted) → handler = cave
function that picks a random album and calls the album-play path. No stock
cell or stock code is touched for the tap dispatch itself.

## 4. Album DB + play path (music_db.c, `../src/music_db.c` 0x7d04c0)

- Schema: `ALBUM_TABLE(id, album, ...)` (CREATE at 0x7d5d00; ctime/mtime/mqa/
  pinyin added by ALTERs). Browse query `SELECT * FROM ALBUM_TABLE limit ?
  offset ?` 0x7d539c, used in fn 0x6d9f00 (offset/limit args — **usable for
  random pick: limit 1 at random offset**).
- **Play queue = per-browse "list_tb_%d" tables** ("list_tb_" 0x7d0440,
  "list_tb_%d" 0x7d15dc): `INSERT INTO list_tb_<N> SELECT … FROM MEDIA_TABLE
  WHERE album = ? ORDER BY path,dis_id,ck_id,cue_id,name COLLATE pinyin`
  (0x7d3284), album+genre (0x7d27cc), album+artist (0x7d2a84), album_artist
  (0x7d2d1c), artist (0x7d2e98/0x7d3128), plus `SELECT %s FROM MEDIA_TABLE…`
  column variant (0x7d33f8).
- **Queue builder 0x6d82a0** (0x6d82a0–0x6d90c0, music_db.c): sprintf(list_tb
  SQL, "list_tb_", id) → sqlite exec; callers:
  - 0x4b47c0 / 0x4b4b00 / 0x4b4ca0 / 0x4b4fa0 / 0x4b5254 — local API wrappers
    (log "Wrong album!" 0x78a5xx-region strings) = the `hl_media_list_*` API
    (init fail strings "hl_media_list init fail" 0x75ca2c at 0x444fc8;
    `hl_media_list_get_playlist` 0x75cd58 used at 0x4442a4;
    `hl_media_list_get_songlist` 0x75cd74 at 0x443fe4 — API module ≈
    0x43f000–0x44a000).
  - 0x548100 / 0x548360 / 0x548580 / 0x5489a0 — Qobuz variants
    ("lg_qobuz_item_listview" 0x77d0xx).
  - 0x6d90c0 — internal (bookmark/book_collect/book_recent table inserts).
- **Engine/play state singleton** around 0x8b0000 (log tag "lg_music_player"
  0x759c6c used across 0x41e000–0x425000; "lg_music_player_notify_proc"
  0x75a05c registered at 0x41f8ac; state fields seen at 0x8b1658 (+5720),
  0x8b1610 (+5648 play-state counter), 0x8b0bfc (+3068), 0x8b0c00/0x8b0c08,
  0x8b34bc (+13500)).
- **Not yet pinned (open):** the exact "play list_tb_N now" engine entry and
  the category-cell-tap → action switch (cell index → open album list). Best
  leads: (a) QEMU gdbstub — tap an album on the albums page, watch the +668
  select callback and the notify proc; (b) trace `list_tb` INSERT call sites
  (0x4b4xxx wrappers) upward to the album list page select; (c) the play-mode
  config keys "play_mode"/"single"/"random"/"loop" (0x75d3dc..0x75d400) show
  the engine already randomizes WITHIN a queue — random-album only needs a
  random ALBUM_TABLE row + the existing album-play entry.

## 5. Phase B patch-site candidates (static)

1. **Universal select log (easiest):** at 0x433720 (`beqz v0, 433708` —
   hit-test hit), insert `jal log_stub` in the fall-through before
   0x433728 (`lw v1,204(v0)`). Stub saves ra/a0-a3, logs the view state and
   the 4-word record (item+128..140), restores, returns. Fires for every
   hglview select app-wide — enough for the PoC and for pinning the category
   record shape.
2. **Category-only:** once the category page's state+352 object is identified
   (Phase B log of +668/+352), patch that object's virtual target instead.
3. **Code cave:** alignment padding between functions (objdump `...` runs of
   zeros) — plenty of small caves in 0x43xxxx–0x45xxxx; verify each cave is
   not covered by an eh_frame FDE before use (FDE list via readelf frames).
   New logic must fit MIPS o32 calling convention; use `jal` from patched
   site only if ra is dead there, else save/restore in the stub.

## 6. Phase D sketch (random album play)

1. Count/fetch: `SELECT * FROM ALBUM_TABLE limit ? offset ?` via fn 0x6d9f00
   (limit 1, offset = rand() % count — count from `SELECT count(id) FROM
   ALBUM_TABLE`-equivalent or decrement-on-empty retry).
2. Build/reuse a list_tb for that album (0x6d82a0 family with album name).
3. Trigger the album-play entry (unpinned — see §4 open item; the existing
   album-row select path already does steps 2–3, so the cleanest Phase D is a
   stub that synthesizes the same select-record/args an album row tap produces
   and calls the found album-play function directly).

## 7. Tooling notes for the next session

- Disassembly: `mipsel-linux-musl-objdump -d` (vendored toolchain). System
  objdump has no MIPS support; capstone 5.0.7 is available for scripted passes.
- Work artifacts (reusable): `/tmp/kilo/r1-re/` — hiby_player.dis (846k lines),
  strings_ro.txt (addressed .rodata strings), xrefs.txt (lui/addiu + gp xrefs,
  _gp=0x8B8240), fnstarts.txt (6547 call-derived function starts), fdes.txt
  (eh_frame FDE ranges, codec-only coverage).
- Branch targets inside the loader show as `<_ftext@@Base+0x…>` because the
  binary is stripped; fnstarts.txt resolves them.
