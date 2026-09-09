---
status: active
id: kb-verification
kind: canonical
scope: repository
read_when: changing runtime code, running a local build or UX acceptance, parser output, cache behavior, FFI contracts, or this knowledge tree
last_verified: 2026-09-08
sources: [".github/workflows/ci.yml", "Makefile", "Package.swift", "scripts/bundle.sh", "Sources/TokenBar/ClientTray.swift", "Sources/TokenBar/StatusItemController.swift", "Sources/TokenBar/MenuBarTextColor.swift", "Sources/TokenBar/Views/AgentIconView.swift", "Sources/TokenBar/Views/SettingsPanel.swift", "Sources/TokenBar/SelfTest.swift", "Sources/TokenBar/ClaudeExtraRoots.swift", "crates/tb_core_ffi/src/agent_account_scope.rs", "crates/tb_core_ffi/src/agent_quota_history.rs", "crates/tb_core_ffi/src/agent_storage_windows.rs", "crates/tb_core_ffi/src/agent_kiro.rs", "crates/tb_core_ffi/src/kiro_integrations.rs", "crates/tb_core_ffi/src/extra_scan_paths.rs", "docs/knowledge/plans/provider-quota-pace.md", "docs/knowledge/plans/codex-historical-pace-v2.md", "public TokenBar-Windows PR #7", "public TokenBar PR #114", "public TokenBar-Windows PR #12", "AGENTS.md", "memory-derived hermetic verification practice", "memory-derived local build indexing incident"]
---

# Verification contract

## 文件目的

這份文件把 TokenBar 的驗證分成 deterministic fixture、跨語言契約、runtime smoke、cache invalidation 與 repository hygiene。目標不是堆命令，而是讓每個修正都證明「舊行為會失敗、新行為正確、常見資料不回歸」。

## 目錄

- [Evidence model](#evidence-model)
- [Hermetic fixtures](#hermetic-fixtures)
- [Runtime and FFI gates](#runtime-and-ffi-gates)
- [Local build and UX acceptance](#local-build-and-ux-acceptance)
- [Cache and sibling checks](#cache-and-sibling-checks)
- [Cross-language invariants](#cross-language-invariants)
- [Documentation checks](#documentation-checks)
- [Failure interpretation](#failure-interpretation)

---

## Evidence model

| Evidence layer | Answers | Cannot prove alone |
|---|---|---|
| Hermetic fixture | 觸發條件下 old/new 是否分歧、修正是否收斂 | 真實 GUI lifecycle 或 provider 網路狀態 |
| Unit or core test | 純函式、parser、fold、schema contract 是否穩定 | Swift/AppKit integration |
| FFI smoke | Rust -> C ABI -> Swift decoder 是否能端到端運作 | 所有特殊資料條件的正確數字 |
| Live app check | 真實 session、視窗 lifecycle、外觀與更新流程是否不崩 | 沒有觸發資料時的 correctness fix |
| CI | 可重複的 build/selftest/smoke gate | 本機 private data 與人工 UX 判斷 |

## Hermetic fixtures

當修正效果取決於本機可能沒有的 session、duplicate key、cursor、WAL、sibling metadata 或 provider cost 時，優先建立合成 fixture。測試應同時保留 old-fail/new-pass 證據，並另加無觸發條件的保值 case。

> **Hermetic 原則：** Live app 在沒有觸發條件時顯示「沒有變化」，只證明常見資料不崩，不能證明修正有效。權威證據是可重跑、與本機資料無關的 fixture。

PT0 的 hermetic authorities are Rust last-good and binding decisions, refresh status-before-body ordering, Grok monthly additive behavior, Copilot loader precedence, Antigravity precedence, and the Kiro multi-source token loader (kiro-cli SQLite and Kiro IDE token file) with its last-good caching; the FFI A/B publication-generation ordering and Swift diagnostic-candidate plus isolated UserDefaults scalar and local publication-state tests are required at the cross-language seam. The Rust fixture must pause A after its gate helper returns, let B obtain generation 2 and record its return first, then release A; it checks both return order and payload generations/content. A separate exhaustion fixture starts at `u64::MAX - 1` and proves the next call fails closed without invoking the publication body or repeating a generation. Swift fixtures distinguish bridge failure from malformed/missing successful data, prove Settings identities change across generations, legacy resolved values, selections, and exclusions, drive the tray apply seam with generation 2 terminal followed by generation 1 success to prove the late result resolves to generation 2 and cannot revive its scalar, and prove a generation 3 Dashboard publication replaces both an older tray payload and scalar before the tray's own poll returns while changing the gauge signature that gates immediate rendering. Live smoke requires authorization for that run and cannot replace these fixtures.

| Fixture property | Required assertion |
|---|---|
| Duplicate or replay | 舊路徑的 total 與對照路徑分歧；新路徑與對照收斂 |
| Sibling-only write | 預設 fingerprint 不失效；完整 fingerprint、mtime probe、prune 都失效 |
| Provider cost | 缺失成本可估算；明確 provider-reported 成本不可被 stale pricing 覆蓋 |
| Hidden client | non-empty partial selection 在 Rust fold 前排除未選 client；`nil`／empty clients 依 C ABI contract 代表 all clients；all-hidden 由 Swift lens strict membership 阻擋；對外發布面另以 hermetic payload-builder fixture 證明隱藏 client 的 token／cost 與 top-client 標籤都不出現在送出的 payload，且未註冊 id 在 producer 端就被正向 allowlist 濾掉——既不進數字也不進標籤，因此中性常數自 `payload()` 已不可達，改以「整張圖只有未註冊 id 時發布 nothing」證明其為死路 |
| Quota account scope | 以 temporary application-data root 驗證 exact 32-byte key、每次 reload、single winner、random／length rejection、key-loss orphan recovery、one-poll deferral、atomic pre／post-commit outcome、authenticated metadata MAC、valid payload＋valid MAC 的 wrong schema、valid-MAC semantic conflict、quarantine collision／identity-bound rollback與 raw-value privacy；macOS／Unix另驗證 directory `0700`／file `0600`、final symlink／non-regular／mode／inode swap fail-closed，以及 final directory 拒絕但 trusted root 下 symlinked ancestor 允許。Windows 的 `agent_account_scope` fixture 只擁有 secure-root fallback／stickiness、consumer concurrent winner、typed failure／commit outcome與 persisted／error privacy composition；CNG、exact DACL、secure-open、reparse／device、file identity、no-delete-share lock、replace與quarantine低階 mechanics 由 `agent_storage_windows` 擁有。不得呼叫真實 Keychain 或 provider credential |
| Quota history | Reset jitter、floating zero、duration lifecycle、partial／future-reset cycles、early／irregular reset 的 observed-duration close、supersede 門檻（28 小時以下的窗須逐 gap 證明與量子時代**完全相同**，不得只釘邊界；週窗須證明 20 分鐘漂移不關窗而 3 小時關窗；`successor_duration_from_series` 的測試兩個候選 group 必須帶**不同** duration，且低鍵那組帶**長** duration，否則放寬判準的變異無法被觀察）、切短 cycle 不進擬合（須同時斷言 `complete_cycles` 差 1 與 pace 相同，斷言在回傳值上；`advertised_nominal_duration` 的 `None` 分支須以 duration 異質的全 Observed series 覆蓋）、upgrade repair（他系列交易仍 restamp 殘留 group；舊點已 prune 則不發明 cycle）、active-series capacity、account isolation、corrupt recovery與current-actual shift都以temporary v3-family store（schema 4）驗證；Codex schema-2只驗current-account-only、byte-exact read-only migration，live provider refresh只作smoke |
| Quota history identity | 三次連續的 credential marker 變更必須產生**同一個** `SeriesKey`，且同一組 marker 仍必須產生**三個相異**的 `ProviderCacheBinding` 與三個相異的 plan-cache key——兩者要一起斷言，否則證明不了「拆身分」而只證明了「換了個鍵」。另需：`scope-history-v1` 的 known vector（期望值必須在 crate 外獨立算出，不得取自實作）與對 `scope-id-v1`／`scope-lineage-v1` 的 domain separation；常數路徑不得建立 metadata 檔；`accountScope` 為 `Err` 但 `historyScope` 為 `Ok` 的快照必須寫入**零**筆 history；每一條 authoritative 路線各有 byte-equality fixture。禁止在 real store 上跑 before/after——那會改寫使用者的生產歷史庫 |
| Overflow input | old arithmetic fails or wraps in the targeted site；new saturating path remains bounded |
| Individual client tray | UI-free SelfTest鎖定兩個defaults的parse前byte cap、entry／ID cap、deterministic serialization與超限no-writeback；client-scoped Auto／explicit／missing、error-only quota provider仍可配置、`antigravity-cli`只在quota lookup映射到`antigravity`且identity保持獨立、main完整route與per-client lens記憶互不污染、Settings row／picker狀態、official icon 1x＋2x reps、newer accepted publication與visible／AX／tooltip privacy都由synthetic graph／quota payload驗證，不建立真實system status items |
| Usage attribution | 政策以結構性斷言驗證而非逐條列舉：每個 bound provider 必須指名 `providerOwnClient` 保護對象、每個 first-party 廠商必須能從其 opencode 標籤解析回自己的 client、表內每個 client 必須在註冊表中。另驗證：來源 client 可為註冊表外的動態 id 而目標不可、自家訂閱優先且不需要 quota snapshot、未調查的來源回傳 nil 而非斷言 API 支出、已宣告的 router 計入它簽入的訂閱 |
| Quota curve snapshot | Binding admission 以真實 snapshots 驗證（trusted scope 不足以綁定：帶 `error` 的 last-good 與帶 `transport_diagnostic` 的 degraded 都必須排除），window key 由 production mapper 產生而非寫進 fixture，因此 mapper 端改身分會失敗而不是靜默 unbind；lifecycle 驗證 serialization 失敗保留前一個 tuple、generation 過期為錯誤、process restart 後不供應；binding lock 必須在 history I/O 前釋放，且 read 之後重新解析 binding——tuple 在 I/O 期間被替換（含同 generation 換帳號）必須 fail closed，settled binding 則仍正常供應 |
| Cache schema | 舊版本 cache 不被當成新 layout 靜默接受；新 layout 可重建並 reload |
| Provider transport fallback | last-good binding、refresh status-before-body、terminal/absent/4xx/schema/required-meter clearing、Grok additive monthly、Copilot loader、以及 diagnostic allowlist 都以 hermetic responses 驗證 |
| FFI publication | Provider run、JSON serialize、envelope、raw C-pointer publication 的 single-flight、gate-assigned checked `publicationGeneration`、exhaustion fail-closed、可反轉的 C return order，以及單次 run 內 provider 並行分別驗證 |
| Source-aware filter parity | `tb_filter_parity_probe` uses one context, fresh graph, `token0…token5`, exact integer comparison, diagnostic-only cost deltas because pricing refreshes independently from source generations, and short-circuits invalid later scans. Its synchronous callback seam tests stable match/mismatch, price-only refresh, tokenUnavailable versus graph failure, every source-change boundary, Agents-only late changes, call ordering, and a size-changing append token. The dedicated vendor fixture covers canonical, cc-mirror exact gating, synthetic gateway, duplicate canonical paths, inherited scanner-root isolation, unattributed `Main`, and cold/warm cache parity. |
| Extra scan roots | `crates/tb_core_ffi/src/extra_scan_paths.rs` builds a real `LocalSourceContext` pointed at a temp `home_dir` and writes real fixture `.jsonl` files under a second temp root, then calls `set_from_json` and re-derives `report_options`/`parse_options` — no mock scanner. Because Claude's dedup key (`{message.id}:{requestId}`) does not include the source root, every fixture states which content relationship it exercises: id-disjoint (extra root sums with the primary), duplicate dedup key across two roots (total unchanged), and the same path registered twice (canonical dedup, unchanged). Coverage: adding an id-disjoint extra root increases the total and removing/never-calling the setter reproduces pre-feature behavior exactly (`scanner_settings.extra_scan_paths` equals `ScannerSettings::default()`'s empty map); mutating the extra fixture's token count is demonstrated red-then-green by reverting the `report_options`/`parse_options` wiring and rerunning the suite, which turns 7 of the 12 cases red while exactly the five that do not depend on the wiring stay green (duplicate dedup key, malformed JSON, file-as-root, never-call, and unsupported client id) — that boundary is the expected one; a path is registered whenever it can still become a readable directory, so an absent root stays in the registry and a later scan picks it up with no second setter call (the regression creates the directory and its fixture after registering and asserts the total moves 0 → 100), while a path that can never be a scan root — empty, relative, or an existing non-directory — is rejected and kept out, with the file-as-root case using a real parseable transcript so that a regression would show up as its contents entering the totals rather than as a shape mismatch; an unsupported client id is rejected before any path is counted; none of these panic or block the rest of the registry; malformed JSON returns a structured error and leaves the registry untouched; a warm `tb_graph` cache cannot hide a newly registered root, by two separate mechanisms that are tested separately — `local_source_change_token` moves once the root's files enter the scan set, which covers a cache entry that has aged past its window, and `lib.rs`'s `setting_extra_scan_paths_drops_the_caches_that_could_answer_from_the_old_roots` covers the window itself by seeding `GRAPH_CACHE` and the tail stamp, driving the real `extern "C"` setter, and asserting both are gone; that test drives the FFI entry point rather than `set_from_json` because the invalidation hangs off the wrapper, and deleting the `invalidate_scan_caches()` call turns it red; `a_scan_that_started_before_a_root_change_does_not_publish_its_result` covers the third window, an in-flight scan publishing after the clear, by taking the generation as a scan would, moving it through the real setter rather than by bumping the counter directly, and asserting both `publish_graph` and `stamp_tick_if_current` refuse — with a same-generation control so a guard that refused everything could not pass; its three mutation targets (each guard's generation check, and the bump itself) were each removed and each turned it red; and a config dir's `projects` and `transcripts` sub-roots both contribute (id-disjoint), proving neither sub-path is silently dropped. `Sources/TokenBar/SelfTest.swift`'s Claude-extra-scan-roots section is Swift-only and does not call the FFI (the live process re-reads `HOME` from the environment, so Swift cannot point it at a temp root); it covers `ClaudeExtraRoots.expand`'s two-sub-root output, `payloadJSON`'s exact wire shape (one dir, multiple dirs, an explicit empty array on `[]` rather than an absent key, and dedup of a repeated dir), and the `isRejectedRoot`/`isMissing` path-sanity predicates. |

> **Quota account-scope evidence boundary：** Legacy development Keychain path 仍被架構禁止。本次 test refactor 的 production-prefix byte freeze 只證明這次沒有新增或修改 production bytes；compiler／build 只能證明 module 被編譯並符合型別與連結契約，不能自動證明未來不會重新引入 Keychain query。Source／Cargo spelling scan 不是 behavioral guard，因此不列入此 fixture contract。

> Quota-history schema 4 migration：v3 → v4 是就地、惰性的升級，驗收全部釘在「能失敗」上。`a_v3_store_upgrades_in_memory_keeps_every_sample_and_converts_on_disk_only_when_written` 把三條宣稱綁在同一個函式裡，因為順序是隱形的前提：v3 store 若被 quarantine 而非升級，store 會是空的，「每筆樣本的 plan 都是 None」在空集合上恆真。它先斷言樣本數（5 筆、2 條 series，且刻意跨 phase bucket——同桶樣本會互相取代，否則 fixture 會比讀起來小得多），再斷言載入後未 quarantine、schema 為 4、且與升級前的 store 完全相等；接著重讀磁碟，斷言檔案仍是 `schemaVersion: 3` 且樣本仍無 `plan` 鍵（惰性語意本身，若只斷言記憶體中的版本，惰性與積極兩種實作都會綠）；最後跑一次真的會寫檔的交易，才斷言磁碟轉為 4、樣本數 N+1、且全部 `plan` 為 `None`。fixture 由真實寫入路徑產生後再降級成 v3 形狀，並斷言 `plan` 鍵確實存在才移除——否則某天停止序列化該欄位會讓這個測試悄悄退化成 v4 讀 v4。V5（`#[ignore]`、由 `TOKENBAR_QUOTA_STORE_COPY_SOURCE` 指向操作者自行複製的真實 store 副本）連同另外三個同型的 operator-copy 測試已於 2026-09-07 移除（#274）：它們從不在 CI 執行，hermetic 的 `a_v3_store_upgrades_in_memory_keeps_every_sample_and_converts_on_disk_only_when_written` 才是 gate。結尾的位元相等只能證明「本測試沒有改動來源」，對複製與斷言之間的 panic 無效、對行程被砍完全無效——不開啟實體檔案才是唯一能挺過那些的保證。本機以副本實測 31 series／2835 樣本全數保留。`a_v3_reader_cannot_parse_a_v4_store` 用一份 v3 形狀的鏡射結構把降級的不可逆性變成可證偽的斷言，而非散文。變異驗證逐一紅轉綠：拿掉升級分支（hermetic 與真實資料各紅一次，後者的失敗訊息正是使用者會遇到的 quarantine）、把升級改成載入即寫檔、讓寫入路徑塞入非 `None` 的 plan、拿掉鏡射結構的 `deny_unknown_fields`、給新欄位加上 `skip_serializing_if`。
>
> Historical runtime retirement checkpoint（2026-07-31）：`agent_history.rs` 的 v2 writer／evaluator 與專用 evaluator tests 已刪除；現行 gate 是 `agent_quota_history.rs` 的 **schema-4** evaluator 加上 current-account-only schema-2 importer regressions（檔名中的 `v3` 是 store 家族代號,與 schema 版本無關——見上一段的遷移）。舊 Historical pace v2 cross-port checkpoint 仍保留於下方，僅作歷史 parity 證據，不是 current gate。

## Runtime and FFI gates

The current CI runtime source is [`.github/workflows/ci.yml`](../../.github/workflows/ci.yml). CI builds the Rust static library, builds Swift, runs the core selftest, and runs the FFI smoke binary. Those are CI build and smoke checks, not the complete local code-change gate. The local build order comes from [`Makefile`](../../Makefile) and the linker contract comes from [`Package.swift`](../../Package.swift).

```bash
cargo build --release
swift build
make selftest          # = swift run TokenBar --selftest -AppleLanguages "(en)"
swift run TokenBar --smoke
```

每一項都跑 debug configuration 的 bare executable，`Bundle.main.bundleIdentifier` 因此是 nil。凡是以那個差異為條件的值，在 suite 看得到的地方是一種樣子、在出貨的地方是另一種樣子，而任何 source scan 都關不掉這個缺口（#146 寫過三道、三道都被繞過，缺口不在原始碼文字裡）。CI 因此在 push 到 main 時多跑一次 `make selftest-bundled`：release build、裝進 `.app`、從 bundled binary 執行同一套 suite。

bundle identity 是這個 target 唯一的旋鈕，而它在兩個危害之間取捨。bundled run 會把 `UserDefaults.standard` 解析到 identifier 指名的 domain，而 suite 確實會寫進去（`PopoverChrome.heightKey` 與 dashboard year key 都是先寫再還原，因為生產型別直接讀 `.standard`）；用出貨 identifier 就會寫進安裝版自己的偏好設定。

所以本機預設是拋棄式的 `com.nyanako.tokenbar.selftest`，而**那是比較弱的 gate**：它抓得到以「identifier 為 nil」為條件的值，抓不到以出貨字串本身為條件的值——後者在本機走安全分支，只有裝起來之後才走另一條。CI 用 `make selftest-bundled SELFTEST_BUNDLE_ID=` 補上，空值代表「`scripts/bundle.sh` 的預設」也就是出貨 identifier；runner 是拋棄式的、沒有安裝版可污染，開發者的 Mac 有。空值而非再寫一次字面值，是為了讓未來改名只有一處要動、不會把這道 gate 無聲地弱化成對不上的字串。

app 名稱**不是**第二個旋鈕。它一度是，而那等於把同一個逃脫換一個屬性重演一次：以 `CFBundleName == "TokenBar"` 或 bundle URL 結尾為條件的值，在叫別的名字的 gate 裡會走安全分支。所以它組出來的是貨真價實的 `TokenBar.app`，改用 `OUT_DIR=dist/selftest` 讓路，順便仍然不會覆蓋手動建的 `dist/TokenBar.app`。

與正式發版 bundle 仍然不同、且**不打算**逐輪 review 才發現的部分：安裝路徑（`dist/selftest/` 而非 `/Applications/`）、version 與 build number（用 `bundle.sh` 預設，正式值由 `release.yml` 傳入）、簽章（ad-hoc 而非 Developer ID）。以這三者為條件的值超出這道 gate 能觀察的範圍，任何本機組裝的 bundle 都關不掉，只有安裝 notarized build 才行。這裡**觀察得到**的是 identifier、名稱，以及 release configuration 本身。

**它不是 `make selftest` 的超集**：`#if DEBUG` 後面的斷言在 release configuration 不存在，所以 bundled run 的斷言數比較少。兩者都是 gate，互不取代。

### Local full code-change gates

For Rust or cross-language code changes, the local full gate adds formatting, the Rust test suite, the all-targets Clippy pass, and the repository build:

```bash
cargo fmt --all -- --check
cargo test
cargo clippy --workspace --all-targets
make build
make selftest          # = swift run TokenBar --selftest -AppleLanguages "(en)"
swift run TokenBar --smoke
```

`cargo test` and `cargo clippy --workspace --all-targets` are local full code-change gates; this document does not claim that the current CI workflow runs them. The `--all-targets` flag is required because `vendor/tokscale-core/src/lib.rs` declares `#![deny(clippy::all)]`, so a test-only lint can fail the gate even when the library target itself is clean.

Live account-scope smoke必須在hermetic security suite通過後才執行，且每次重新執行都需要當次明確授權。若出現任何Keychain或credential授權視窗，立即停止process並把smoke判為失敗；不得要求輸入登入密碼、讀取secret或用真實credential診斷。

| Gate | Expected evidence |
|---|---|
| Rust | Release static library builds from the current source |
| Swift | SwiftPM links against the freshly built library from repository root |
| Selftest | UI-free TokenBarCore assertions pass。部分斷言逐字比對英文 UI 文案，因此語系必須鎖定 `en`（用 `make selftest`，或自行帶 `-AppleLanguages "(en)"`）；在中文系統上直接跑 `swift run TokenBar --selftest` 會因 `Format` 輸出中文而假性失敗，入口會先印出提示 |
| Bundled selftest | 同一套 suite 從 `dist/selftest/TokenBar.app` 的 release binary 通過（`make selftest-bundled`），證明斷言看到的是出貨 configuration。CI 只在 push 到 main 時跑，並以 `SELFTEST_BUNDLE_ID=` 帶出貨 identifier；本機預設拋棄式 identifier＝較弱版本。斷言數少於 debug run（`#if DEBUG` 的部分不存在），不是超集 |
| Smoke | Every C ABI entry point decodes or reports an intentional error envelope；account-scope path不得存取Keychain或顯示credential authorization UI |
| Account-scope storage | Hermetic security tests先證明permission、path、locking、atomicity與recovery；live smoke只驗證shipping data flow不彈授權UI，不取代fixture correctness |
| Windows secure storage | M19-B0證明Native candidate與核准Windows security/storage semantic source等價；M19-B1又在hosted Windows x64 runtime執行CNG、owner／exact protected DACL、final-component reparse、file identity、exclusive no-delete-share lock、replace、quarantine、legacy upgrade與error-privacy tests。合併後的exact Windows source另在real ARM64 Windows通過351項Rust tests、12-case provider-v3 CrossCheck、ARM64 PE checks與synthetic WinUI startup；macOS tests與GitHub ARM64 cross-package都不取代這些runtime assertions |
| Relink safety | If Rust changed without Swift source changes, the stale executable is removed before linking |
| Rust format | For Rust changes, run `cargo fmt --all -- --check` on the touched scope; vendor formatting policy may be intentionally separate |
| Local Rust tests | `cargo test` passes across workspace crates and test targets |
| Local Clippy | `cargo clippy --workspace --all-targets` passes, including test-only targets |

## Local build and UX acceptance

不需要 `.app` bundle 語意的人工 UI 檢查，優先從 repository root 執行 `swift run TokenBar --open-popover`。只有 icon、`Info.plist`、`LSUIElement`、Sparkle、autostart 或安裝路徑等 bundle-only 行為，才以 `make bundle` 產生的 `dist/TokenBar.app` 驗收。

Provider quota pace 以 `swift run TokenBar --demo --open-popover` 提供 deterministic 人工驗收面；snapshot badge 明示 `FIXTURE`，且 `DemoUsageDataSource` 不呼叫 live FFI、不讀寫 quota cache。Historical／Linear／Off 都要實際呈現；驗收時必須區分低 remaining 觸發的 quota 長條黃／紅健康色，與 deficit stage 觸發的 pace marker／footer 橘色。橘色只看 actual 有沒有越過 expected 線，不看是哪個 estimator 畫出那條線——Historical 與 Linear 的 deficit 同色，狀態文案仍必須分辨兩者。舊規則（只有 `available` 可上色）已廢止：`available` 由每次 refresh 重跑的 out-of-sample fit gate 決定，同一張卡會在 Historical 與 `learningHistory` 之間來回，把顏色綁在 basis 上會讓使用者看到預測「一下子就不見了」，而底層 deficit 其實一直存在。

Menu bar 的「Font color」驗收涵蓋 Automatic／Custom 切換、正常／偏低／不足三個獨立色塊下方的 16 色面板與 HEX 輸入、深淺預覽、主項目與獨立用戶端數值未改變時立即換色，以及切回 Automatic 後恢復額度／系統字色。以獨立 UserDefaults suite 驗證舊單色設定保留為正常色、另外兩色的預設、三色保存後重讀、25%／10% 邊界與邊界上方的色階選擇、非額度文字／無額度使用正常色、無效儲存值只回退該檔位，以及恢復自動時保留自訂值；同時鎖定自動 gauge 的原始色值。這些 selftest 不取代實際互動。GUI 需確認面板位於自訂顏色列下方、沒有系統調色盤，連續切換三個色塊會更新同一面板的編輯檔位，分別換色不改動其他兩色，並驗證輸入 `#000000`、小寫與省略 `#` 的正規化，以及未完成／無效輸入不改動上一個有效顏色，並在輸入框失去焦點時清空。Argument Domain 注入可驗初始配色，不代表互動寫入或跨 process 持久化已驗證。

Individual client items的deterministic Settings檢查以Argument Domain注入初始偏好；這只驗visual state與initial routing，不在同一process宣稱toggle persistence：

```bash
swift run TokenBar --demo --settings \
  -tokenbar.tray.clients.enabled claude,codex \
  -tokenbar.tray.clients.quotaSelections '{"claude":"auto","codex":"weekly.v1"}'

swift run TokenBar --demo --settings \
  -tokenbar.tray.clients.enabled claude,codex \
  -tokenbar.tray.clients.quotaSelections '{"claude":"auto","codex":"missing.v1"}'

swift run TokenBar --demo --settings \
  -tokenbar.tray.clients.enabled claude,codex \
  -tokenbar.tray.clients.quotaSelections '{"claude":"auto","codex":"weekly.v1"}' \
  -tokenbar.tabs.hidden codex
```

> **本機 bundle 邊界：** `dist/TokenBar.app` 是暫時的驗收產物，不是第二份安裝。日常使用與正式更新的 source of truth 仍是 `/Applications/TokenBar.app`。
>
> `make selftest-bundled` 另外會在 `dist/selftest/TokenBar.app` 產生同名 bundle。它刻意與出貨同名同 identifier（見上方 gate 段落），所以**兩者不可混淆**：UX 驗收與下方清理程序談的一律是 `dist/TokenBar.app`。selftest 產物只被直接執行、在 app lifecycle 之前就結束，不會被 LaunchServices 註冊；`bundle.sh` 也會在 `dist/selftest/` 放一份 `.metadata_never_index`。不需要時整個目錄刪掉即可。

[`scripts/bundle.sh`](../../scripts/bundle.sh) 會在組裝 app 前建立 `dist/.metadata_never_index`，避免 Spotlight 主動索引本機 bundle。但這個 marker 不會回溯刪除既有 Spotlight metadata；實際啟動 `dist/TokenBar.app` 也可能讓 LaunchServices 註冊它。因此本機 UX 驗收完成、且不再需要該 bundle 作為 release artifact 時，應撤銷這個特定 app 的註冊並刪除生成物，不要以重設整個 Launchpad database 作為第一步。

| UX surface | Preferred path | Completion evidence |
|---|---|---|
| Popover、lens、keyboard、scroll、appearance | `swift run TokenBar --open-popover` | 實際操作與必要截圖；結束測試 process |
| Individual client status items | `--demo --settings`配合兩個M2 Argument Domain keys驗initial visual state；本機資料、placement／right-click／跨螢幕則用同一`dist/TokenBar.app` | 預設只有主item；switch點擊後立即以`.mini`原生狀態更新，client shell可稍後於同一defaults reconciliation建立但不得阻塞control setter；Settings body重建不得同步呼叫`SMAppService.status`（本機量測單次約0.5～0.9秒），關閉／重開與連續toggle都須維持可互動；enable／disable／hide／restore保留selection與`tokenbar-client-<id>` placement；`antigravity-cli`在本機error-only provider狀態仍可配置；dashboard選定單一年份時，Settings仍以all-time graph保留所有live client item rows並可停用；client A→B沿用同一popover並各自恢復本次app session停留的lens；主item恢復自己的client-plus-lens route，不被individual item覆寫；主item right-click仍只改global source；1x／2x雙向移動圖示清晰；VoiceOver label不含raw card／error，explicit error fallback固定讀作last-known而非current quota；0與8 items的idle profile沒有per-client loop |
| Icon、bundle identity、Sparkle、autostart | `make bundle` 後啟動 `dist/TokenBar.app` | 記錄 bundle-only 行為；完成後 unregister 並移除本機 bundle |
| Homebrew、Sparkle stable update、正式安裝路徑 | `/Applications/TokenBar.app` | 不以 `dist/TokenBar.app` 代替 installed-app 驗收 |

從 repository root 清理已完成驗收的本機 bundle：

```bash
ROOT="$(git rev-parse --show-toplevel)"
LOCAL_APP="$ROOT/dist/TokenBar.app"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

test -e "$ROOT/dist/.metadata_never_index"
"$LSREGISTER" -u "$LOCAL_APP" 2>/dev/null || true
rm -rf -- "$LOCAL_APP"
```

清理後，Spotlight 與 LaunchServices 查詢都不應再列出 repository 的 `dist/TokenBar.app`；正常情況只保留 `/Applications/TokenBar.app`：

```bash
mdfind "kMDItemContentType == 'com.apple.application-bundle' && kMDItemFSName == 'TokenBar.app'"
"$LSREGISTER" -dump | grep -F 'TokenBar.app'
```

若仍有 stale 結果，先等待 metadata service 收斂並重查；不要直接清空整台機器的 Spotlight index 或重設 Launchpad，因為那會波及其他 app 與使用者排列。

## Cache and sibling checks

A source reader that consumes secondary files must be verified as one unit. The regression matrix is deliberately broader than the parser function itself.

| Seam | Check |
|---|---|
| Fingerprint | Primary-only change and sibling-only change produce different fingerprints |
| Active lane | The source is reachable by the streaming and materialized consumers that claim support |
| Latest mtime | Live-tail change token observes every relevant sibling and WAL |
| Pruning | `modified_after` keeps a session when a relevant sibling is fresher than the primary |
| Cache rebuild | Same-fingerprint stale serialized data is rejected when parser output or attribution changes |
| Report parity | Materialized and streaming reports agree on the fixture's selected fields |

## Cross-language invariants

| Contract | Verification |
|---|---|
| Heap JSON ownership | Every successful FFI pointer is decoded and released through `tb_free`; errors do not leak a second ownership path |
| Envelope shape | `ok` and `data`/`err` fields match `ctb.h` and Swift decoders; agent usage classifies `ok:false` as fixed bridge failure and malformed or `ok:true` missing data as fixed decode failure without public associated text |
| Publication order | Rust `publicationGeneration` is additive, gate-owned, and checked against exhaustion; one shared Swift `@MainActor` coordinator rejects lower generated payloads across DashboardModel, Settings, tray polling, and snapshot restore before payload or scalar apply, while missing generations pass through without changing state |
| Windows compatibility | M19-B1's production C# decoder ignored additive `publicationGeneration` while preserving existing fields; no DTO, C signature, or ownership change was required |
| Windows storage ownership | Native `agent_storage_windows` is the cfg-gated source of truth. Production account scope and v3 history must use only its CNG／DACL／secure-open／identity／lock／replace／quarantine primitives, preserve the trusted per-user anchor and same-SID threat boundary, and never be patched independently in the Windows consumer |
| Client filter | Non-empty selected IDs reach Rust before mixed buckets are folded; `nil`／empty client lists mean all clients per `ctb.h`; the Swift lens strict-membership check blocks all-hidden views |
| Arithmetic | Rust report totals, FFI mappers, Swift models, and live-rate consumers use bounded arithmetic where required |
| Stale-data policy | A failed refresh retains the last good value instead of blanking a working card；fallback preserves display-ready fields only for a structural same-binding request transient, marks account scope untrusted, and skips enrichment／history／re-cache. Claude and Grok validate the response, preflight the exact durable target before lineage transfer, then typed-save through a second exact re-read／compare；`TargetMissing`／`TargetChanged`／`TargetMalformed`／`TargetUnverified` are terminal with zero required usage continuation, while only a persistence-stage failure after the second compare succeeds may return the fresh credential and transferred scope with no cache binding. `CredentialsPersisted` is the after-attempt checkpoint even when typed save returns an error. Codex and Antigravity retain their existing ordering and failure policy；Codex save failure leaves auth and metadata bytes unchanged, credentials persist before lineage transfer, transfer failure conditionally rolls back only while the exact just-written root still matches, and its post-binding reuses the verified scopes. External writers can still race compare-to-write／rollback, Keychain `security -U` is not CAS, and credentials plus metadata are not a cross-resource atomic transaction |
| Diagnostic wire | Rust emits only `{category,status?,osCode?}` from the fixed category allowlist；`rateLimited`只允許status 429且不帶osCode，`serverError`只允許500...599且不帶osCode，非HTTP categories不得帶status，unknown category不得帶associated numerics；Swift lossy decoding逐欄丟棄malformed optional integers，非object或缺失／非字串category不建立candidate、unknown values正規化，且public logging維持bounded |
| Swift scalar authority | Successful finite outer payloads replace memory and persistent scalar; Dashboard polling reconciles accepted publications immediately and TrayAnimator reads the coordinator's latest generated payload before its own poll completes; selection／exclusion changes re-reconcile before render; Settings task identity uses `publicationGeneration` or a legacy timestamp-plus-resolved-scalar fingerprint; terminal／Absent／unresolved／hidden-all clear the scalar; only outer FFI failure or missing payload retains it. Isolated UserDefaults tests cover restart non-revival, healthy replacement, explicit fallback windows, Auto exclusion, reconciliation identity collisions, a newer terminal result followed by a late older tray success, and a newer Dashboard success replacing an older tray payload plus scalar while invalidating the gauge-render signature |
| Quota curve identity | Series identity 不跨 ABI：Rust 擁有 publication-owned binding table，Swift 只傳 `clientId`／`windowKey`／`publicationGeneration`。Binding 只在 serialization 成功後替換，generation 不符為錯誤而非 fallback，binding 在 history I/O 後重新解析以拒絕已移動的 identity；absent history 的 `ok:true` + `null` 由專屬 optional-envelope decoder 處理，不得與 decode failure 混同 |
| Historical pace | Rust 的 typed `paceStatus` 擁有 lifecycle／duration，optional nested result 同時擁有 expected、ETA、will-last 與 risk；Swift 只能導出 mode policy、stage 與文字。`available + completeCycles == 0` 是合法的 validated current-window projection：Historical mode 必須使用 backend expected／ETA／will-last，partial risk 缺失時維持 nil、不顯示 risk copy，也不得退回 Linear。只有 `learningHistory` 可明示使用 exact-duration Linear estimate，`learningDuration`／`unavailable`／legacy 不得 silent fallback |
| Lifecycle | Closing a popover or settings window cancels its tasks and stops background rendering |
| Restart snapshot | Disk bytes carry only the aggregated graph payload plus schema/build identity, proven by a recursive exact-key assertion with a canary in every excluded field, not a keyword scan; any shape change bumps `snapshotSchemaVersion`. Restore is rejected for schema、bundle、version or exact-build mismatch, a requested year the snapshot does not match, malformed `knownYears`, a `savedAt` beyond the clock-skew or retention bounds, corrupt bytes, the byte cap and cap+1, a symlinked file or directory, a FIFO, a directory in the file's place, and wrong owner or mode. `--selftest`、`--smoke`、`--demo` and `--icon-gallery` must yield no shipping identity, asserted against an injected production bundle triple with a control proving that triple alone does yield one；a spy fails if the production directory is even resolved. Ordering is covered in both task orders, a superseded fetch must not clear a newer request, and mutation targets include the build comparison、the requested-year gate、the regular-file check、`O_NOFOLLOW`、the content digest、the capture sequence and the indicator's ownership check |

### Credential refresh target matrix

Claude File、Claude pure Keychain decision and Grok exact-entry owners exercise the shipping continuation seams rather than returning a prebuilt failure or credential tuple. Each row first uses `TestRefreshScope` to establish A's lineage and only then captures the metadata baseline. Claude routes a real hermetic `refresh_claude_credentials_with` result through `fetch_claude_login_usage_with`; the synthetic Keychain row supplies account／item reads to the pure decision helper and never invokes `/usr/bin/security`. Grok routes an adapter that actually calls `refresh_credentials_with` through `retry_grok_weekly_after_auth_with`; its counter covers only the required weekly retry, never the additive monthly request.

| Phase／class | Required observation |
|---|---|
| Network-wait `TargetChanged`／`TargetMissing`／`TargetMalformed`／`TargetUnverified` | Terminal；request and preflight exactly once；no transfer、typed save、writer or usage／weekly retry；metadata byte-identical to the established-A baseline；external durable state preserved. Claude also owns explicit logout and mcpOAuth-only as `TargetMissing` without fallback |
| Post-preflight four target classes | Terminal；request、preflight、transfer and typed save exactly once；writer and usage／weekly retry zero；checkpoint sequence includes `MetadataHandled` and the after-attempt `CredentialsPersisted`；external durable state preserved；the transferred new marker may remain as inert A-lineage metadata |
| Genuine persistence failure | Second exact compare succeeds before the injected writer failure；new access credential and transferred A scope reach exactly one required continuation；cache binding is `None`；old durable bytes remain；old／new markers share lineage |
| Success with concurrent sibling write | Exactly one required continuation；reusable binding resolves to A；Claude top-level sibling or Grok foreign／root／entry siblings survive the merge；Keychain output remains pinned to captured account A |

Common assertions use only fixed secret-free labels: `REFRESH-TARGET-PREFLIGHT-TERMINAL`、`REFRESH-TARGET-POST-PREFLIGHT-TERMINAL`、`REFRESH-TARGET-USAGE-BLOCKED`、`REFRESH-TARGET-PERSISTENCE-FAILSOFT`、`REFRESH-TARGET-KEYCHAIN-PIN`、`REFRESH-TARGET-SIBLING-PRESERVATION` and `REFRESH-TARGET-CHECKPOINT-SEQUENCE`. Failure output must not include a token、account、path、JSON body or raw metadata. A preflight owner must not probe `resolve_current(new_marker)` to prove absence because that helper can create the mapping；metadata bytes plus transfer count own that assertion.

Mutation qualification is thirteen compile-preserving changes: four independent typed-save target-class-to-`Persistence` mutations, plus preflight ordering、second re-read／compare、Grok exact-entry selection、Keychain account pinning、persistence cacheability、persistence terminality、Claude usage continuation、Grok weekly continuation and `CredentialsPersisted` placement. Each mutation must fail the intended fixed-label owner with non-zero test exit, preserve unrelated owners, restore exact source bytes／hash／diff fingerprint, and leave the same owner green after restore. Compile failure、zero selected tests、an unrelated panic or a failure scan that ignores process exit is not a kill.

> **Windows secure-storage ownership：** `agent_storage_windows.rs` 是 low-level CNG、exact protected DACL、secure-open、identity、lock、replace與quarantine semantics 的唯一 test owner；`agent_account_scope.rs` 只擁有 account-scope consumer workflow composition，quota-history 也保留自己的 consumer state-machine owner，不重複低階 primitive matrix。Caller 必須把路徑錨定在 trusted per-user data root；final component 不得是 reparse point，trusted anchor 下的 ancestor reparse 允許。這個 low-level claim 不防禦任意 same-SID malicious process。`SystemBackend` → CNG adapter wiring 沒有 account-scope test-only seam；本次只以 production byte freeze、compile 與 review 證明它未變，deterministic CNG API behavior 仍由低階 owner 驗證。

## Cross-port fixture cross-check

Windows port（[Nanako0129/TokenBar-Windows](https://github.com/Nanako0129/TokenBar-Windows)）的 C# `TokenBar.Core` 是 `Sources/TokenBarCore` 的逐檔移植。Native reviewed pin 為 `02c883d2c0792cc746d7469939eb4dd8775f698c`；Windows current pin 與 consumer state 由 Windows repo 自己擁有，Native 不重述。這次 consumer 是 pin-only：`crates/tb_core_ffi` 零改動（新欄位的填值在前次推進就做完了），也沒有 app-owned C ABI 變更隨行，`ctb.h` 簽名不變，故 Windows 不是本次簽名規則下的必須通知消費者。Windows 推進自己的 pin 時仍需要那一行填值，因為它的 `TokenBreakdown` literal 同樣是窮盡的。（本次 `65511b8` → `02c883d` delta 為 4 個 engine commit；前次 `044153f` → `65511b8` 的 4 commit、再前次 `ffe5a2d` → `044153f` 的 7 commit、更前次 `47c7241` → `ffe5a2d` 的 10 commit、再更前次 `434b95ff` → `47c7241` 的 52 commit。`crates/tb_core_ffi` 只在前次動過一行。）LocalOnly、CostCoverage、embedded-cost 與 partial-estimation 語意尚未宣稱已經 C ABI 抵達 Swift。global cache format 與 serialized layout 本次**不變**（`CACHE_FORMAT_VERSION` 維持 4）；變的是 `parser_version(Claude)` 3→4，只讓 Claude shard 重新 parse。前次推進才是 format bump 那一次。本次 pin 帶進 **#287 的 1h cache write 計價修正**（engine PR #25）。Anthropic 對 prompt cache 寫入收兩種費率——5 分鐘 TTL 是 base input 的 1.25 倍、1 小時是 2 倍——而 parser 只讀兩者之和 `cache_creation_input_tokens`，全部按較便宜的 5m 費率計。現在 parser 讀巢狀的 `cache_creation.ephemeral_1h_input_tokens`，計價時把 1h 從 cache-write 桶**扣除**後以 `2 × input_cost_per_token` 重計。`parser_version(Claude)` 3→4，這一步不可省：`get` 只要版本相符就當快取命中，指紋未變的 transcript 永遠不會被重新 parse，修正對所有既有使用者將完全無效。此 bump 落在可遷移區間，retained-only turn 由前次 pin 帶進的 migration 保住。

⚠️ **使用者會看到歷史成本上升。** 實測凍結 1,144 份 transcript 語料：1h 佔 cache-write token 的 79.6%（539,639,286／678,193,247），成本由 $14,658.23 升至 $15,710.35，**+7.18%**；四個 token lane 位元相同——這改的是 token 的價格，不是 token 的數量。量測刻意用**暖快取**（先跑舊 build 建立 parser_version 3 的快取，再用新 build 跑同一個 config dir），因為那才是使用者升級的實際情境；冷快取結果分毫不差，證明 bump 真的讓存量項重新 parse。把 bump 拿掉重跑暖快取會回到 $14,658.23，delta 恰為零——只跑冷快取的驗收會通過，卻出貨一個什麼都沒做的修正。發版說明必須解釋這次上升，否則會被當成計價變貴。

前次 pin 帶進 format-crossing migration（engine PR #24，結案 tokscale-core issue #22）：`CACHE_FORMAT_VERSION` 3→4，且這是第一次 format bump 走遷移而非丟棄——`mod format3` 保留舊 bincode layout，有 retention 的 namespace（Claude）shard 被解碼帶過去，其餘 namespace 一如既往轉冷、各自重掃一次。**回報數字不變。** bump 的來由是同一 PR 為 `TokenBreakdown` 加了 `cache_write_1h`，改變了 positional layout；該欄位只承載 layout、尚未填值也尚未計價，因此 #287 的 TTL 計價可以接著落地而不必再來一次有損的 bump。實測（凍結 1,144 份 transcript、模擬 compact 抹去 300 個帶 usage 的 assistant turn）：format 4 讀 format 3 快取的四個 lane 與 format 3 基準完全相同（input 868,733,624／output 44,261,347／cache_read 16,769,237,791／cache_write 289,163,123），而同一份語料的冷快取對照組少了 input 376／output 121,248／cache_read 49,249,515／cache_write 573,038——該對照組是這個檢驗能夠失敗的證明。前次 pin 帶進 Claude shard migration（engine PR #21）：`parser_version` 2→3 不再丟棄 retained-only turn，#288 的修正因此對存量快取生效。驗收不只靠單元測試——253 個 shard 走過遷移、1,144 份 transcript、模擬 compact 抹去 329 個 assistant turn 後四個 lane 與基準位元相同，且冷快取對照組明顯較低（該對照組是這個檢驗能夠失敗的證明）。PR #21 的 migration 不跨 `CACHE_FORMAT_VERSION` bump（tokscale-core #22），這道缺口正是本次 PR #24 填上的。再前次 pin 帶進 Claude `tool_result` 重複計數修正（engine PR #19、issue #288，移植上游 `275bc798`）：parser 不再對下一輪 assistant usage 已涵蓋的 tool_result 做字元估算，**回報的 Claude input token 會下降，幅度依語料而異**（兩次獨立實測：貢獻者 6,219 份 transcript 由 118,834,152 降至 9,633,890，為 −91.9%；維護者 1,144 份 transcript 由 922,963,773 降至 868,733,624，為 −5.9%。絕對減少量同量級，比例差異來自 tool-heavy 程度不同；兩次量測中 output／cache_read／cache_write 皆位元相同）。（該修正出貨當時，既有快取項維持舊值直到各自 transcript 下次變動；PR #21 的 migration 已解除該限制。）更前一次推進（`47c7241`）則帶進 Codex reasoning double-pricing 修正（歷史 Codex 數字依 reasoning effort 等比下降）與 engine 端 `parser_version(Codex)` 前進，Codex shard 冷掃一次。Windows 的 crosscheck oracle 釘在固定 macOS SHA `63084b2a`（非 `main`），故本次 pin 推進不影響該 job；但 oracle 自身的落後因此加大，未來推進 Windows pin 時會一次掀出期間累積的漂移。same-pin 只證明 shared source 相同，不取代下述 cross-check 這道跨語言 gate；app-owned FFI、Swift 與 C# surfaces 仍可獨立漂移。單元測試的期望值由移植者撰寫，因此對「一致地誤讀 Swift 語意」的移植錯誤沒有偵測力；對拍（cross-check）以同一份 fixture JSON 餵 Swift 與 C# 兩邊、逐欄位 diff 輸出，才是移植忠實度的判準。

| 項目 | 內容 |
|---|---|
| Swift harness | [`Sources/CrossCheckHarness/main.swift`](../../Sources/CrossCheckHarness/main.swift)，`TZ=Asia/Taipei swift run crosscheck-harness <fixtures> <out> [usage-pace|format|provider-quota-pace-v3] -AppleLanguages "(en)"`；selector 省略時維持 legacy complete run，所有路徑使用 shipping 程式碼 |
| 語系鎖定 | `Format` 的日期／相對時間與 `UsagePace.durationText` 自 i18n 後具語系相依（查表工具在 `Sources/TokenBarCore/Localization.swift`，harness 透過連結 TokenBarCore 取得）。`make build` 會把 `Sources/TokenBar/Resources/Localizations/*.lproj` 複製到 `.build/debug/`；裸 `swift run TokenBar` 會在入口從 SwiftPM resource bundle 暫存同樣的目錄，harness 本身沒有該 target resource，沒有 `.lproj` 時解析為 `en`。對拍因此**必須**帶 `-AppleLanguages "(en)"`。harness 對此 **fail closed**：解析時只認 `-AppleLanguages <value>`（其餘 dash 開頭的 token 一律拒絕，避免吃掉 fixture 路徑後對錯誤目錄執行），並在 TZ guard 之後檢查 `preferredLocalizations` 必須為 `en`，否則 exit——寧可拒跑，也不要靜默產生對拍永遠對不上的在地化輸出。 |
| 契約與 fixture | Windows repo 的 legacy `crosscheck/` 保留既有 116-case reference；provider v3 handoff 由 Mac-owned [`provider-quota-pace-v3.json`](../../Fixtures/CrossCheck/provider-quota-pace-v3.json) 提供，Rust production serializer 鎖定 payload，Swift／Windows 都必須用 production decoder，無自製 wire mapping |
| 比對 | Windows repo 的 `crosscheck/diff.py`：字串逐 byte、數字 epsilon 1e-9、缺鍵視同 null |
| 執行時機 | `Sources/TokenBarCore` 邏輯或 `Format` 語意變更後；Windows app-owned delta 或 reviewed engine pin advance 後 |

> 首輪實績（2026-07-16）：首跑 115 案例抓到 4 條 printf 捨入 seam 的真實漂移——C# 側以 `Math.Round` 預捨入模擬 `%.nf` 會把非 midpoint 的近半值重新量化；printf 對二進位真值做正確捨入。教訓：**模擬 printf 的中介捨入層一律可疑**。修正與後續 comparator 強化（整數精確比對、bool 嚴格比對、Int64 邊界案例——fixture 現為 116 案）都記錄在 Windows repo。

> Historical pace v2 checkpoint（2026-07-16）：116-case legacy baseline 已重跑，非 historical cases 全數一致。27 個 field differences 只分布在 9 個使用舊 top-level historical scalars 的 cases：`historical-expected-clamped`、`historical-runout-exact-half`、`historical-runout-high-keeps-eta`、`historical-runout-low-forces-lasts`、`historical-with-expected`、`runout-risk-certain`、`runout-risk-clamped-above-one`、`runout-risk-half-percent-rounds-up`、`runout-risk-thirty`。這些是 nested contract 取代 scalar contract 的 intended mismatch；Windows 新增 nested fixture／DTO 並完成 semantic port 前，不得宣稱 historical parity。
>
> Provider-wide v3 checkpoint（2026-07-27）：no-selector Mac harness 以 production decoder 完整產生 42 pace＋74 format cases，不再因單一 malformed legacy row 中止。原本 28／42 pace cases 的 intended mismatch 來自 strict v3 decoder、typed lifecycle 與 no-silent-fallback contract。M19-B1 的 Windows port在 [Windows PR #7](https://github.com/Nanako0129/TokenBar-Windows/pull/7) 完成 production DTO／state machine／selection／presentation；完整 Swift／C# cross-check 119 cases零material difference。Mac-owned fixture 的7張 lifecycle windows與12個 projection／selection／legacy／malformed cases仍由Rust production serializer鎖定，real ARM64 CrossCheck也產生exact 12 cases。Provider-v3 Windows status因此為 **port/parity complete**。

> Shared-engine extraction checkpoint（2026-07-28）：Native [PR #114](https://github.com/Nanako0129/TokenBar/pull/114) 與 Windows [PR #12](https://github.com/Nanako0129/TokenBar-Windows/pull/12) 都 pin `b31e39425859393504a2d56cb5af7c93e6461c7d`。Windows current-head gates produced 119 cross-check cases with zero material difference；hosted x64／ARM64 jobs and a separate native ARM64 packaged-FFI run passed. Future same-pin assertions prove shared source equality but do not replace this cross-language gate.

## Documentation checks

The knowledge tree is validated by `scripts/check_knowledge.py`, the `make check-docs` target, and the CI knowledge-validation step. The final documentation gate is:

```bash
python3 scripts/check_knowledge.py --self-test
python3 -m py_compile scripts/check_knowledge.py
python3 scripts/check_knowledge.py
make check-docs
git diff --check origin/main...HEAD
```

These checks cover frontmatter, relative links, canonical reachability, migration-ledger counts and enums, privacy scans, and repository whitespace. Do not claim runtime PASS for a docs-only change.

## Failure interpretation

A failed smoke run caused by missing local credentials, an empty private session tree, or a provider network response is not evidence that the parser or docs are wrong. Record the environmental limitation separately, then rely on hermetic tests and the relevant source-level gate. Conversely, a green live smoke run without a fixture does not close a data-dependent correctness issue.
