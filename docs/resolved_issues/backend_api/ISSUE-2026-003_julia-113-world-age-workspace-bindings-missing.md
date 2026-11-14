# ISSUE-2026-003: Brak nowo załadowanych zmiennych i pakietów w Workspace na Julii 1.12/1.13 (semantyka world-age dla wiązań globalnych oraz cięcie UTF-8)

- **Issue ID:** ISSUE-2026-003
- **Data:** 2026-11-14
- **Kategoria:** `backend_api`
- **Status:** Resolved
- **Dotknięte pliki:**
  - `src/ipc.jl`
  - `src/backends.jl`
  - `src/workspace.jl`
  - `src/repl_mode.jl`
  - `src/procedures.jl`
  - `test/Project.toml`
  - `test/runtests.jl`

## 1. Opis problemu (Symptomy)

W sesji Julii 1.13.3 z aktywnym watcherem `jEMach` (np. po uruchomieniu w projekcie zewnętrznym takim jak `/mnt/nowy/github/Atractors-in-QGP`):
- Pakiety załadowane przed `jEMach` (np. `BenchmarkTools` z `~/.julia/config/startup.jl`) były widoczne w tabeli `columns` w TUI i pliku JSON stanu.
- Nowo zdefiniowane w `Main` zmienne (`x = 1`), funkcje, struktury, lokalne podmoduły (`module Foo ... end`) oraz pakiety załadowane po inicjalizacji `jEMach` (np. `using AttractorsQGP`) **nie pojawiały się** w kolumnach Workspace (chociaż `history` i `packages` rejestrowały aktywność).
- Dodatkowo przy podglądzie długich napisów z wielobajtowymi znakami UTF-8 (np. polskie znaki diakrytyczne lub symbole matematyczne) funkcje obcinające tekst po indeksach bajtowych (`s[1:60]`, `val[1:min(end, 57)]`, `name_disp[1:20]`, `tp[1:20]`) mogły rzucać `StringIndexError`, powodując pojawianie się symbolu zastępczego `"<?>"` w `_value_preview`.
- Użytkownik ładujący `jEMach` z projektu korzystającego z gita (`[sources]` w `Project.toml`, np. w `/mnt/nowy/github/Atractors-in-QGP`) korzystał ponadto z cache Pkg w `~/.julia/packages/jEMach/jzWOB/` zamiast z lokalnego repozytorium deweloperskiego `/home/kitajusus/jEMach`.

## 2. Analiza przyczyny źródłowej (Root Cause)

1. **Partycjonowanie wiązań globalnych według world-age w Julii 1.12/1.13:**
   - W Julii 1.12+ wiązania globalne (`Main.x`, `Main.MyPkg`) są wersjonowane przez *world-age*.
   - Długo żyjące zadania asynchroniczne uruchomione w `__init__()` (zadanie pętli watchera `_task_ref[]` w `src/backends.jl`, serwer socketów w `src/ipc.jl`, callbacki w `ast_transforms` w `src/repl_mode.jl`) pozostają przypisane do world-age z chwili utworzenia zadania.
   - Ponieważ `publish_state()` wywoływało `_collect_state_dod!` bez `Base.invokelatest`, wywołania `names(Main; ...)`, `isdefined(Main, sym)`, `getfield(Main, sym)`, `methods(...)`, `hasmethod(...)` oraz `Base.Docs.doc(...)` nie widziały symboli, typów ani metod zdefiniowanych lub załadowanych po starcie zadań w tle (lub emitowały ostrzeżenie `Detected access to binding ... in a world prior to its definition world`).
2. **Pomijanie lokalnych podmodułów w `Main` i współbieżny dostęp do `Base.loaded_modules`:**
   - `_collect_state_dod!` przeglądało wyłącznie `Base.loaded_modules` (zewnętrzne pakiety) bez skanowania podmodułów zdefiniowanych bezpośrednio w `Main` (`module Foo ... end`) oraz bez snapshotu pod `Base.require_lock`.
   - `_get_packages()` buforowało listę zależności wyłącznie po `mtime` pliku `Project.toml`, bez śledzenia ścieżki aktywnego `Project.toml` przy zmianach projektu.
3. **Indeksowanie bajtowe napisów UTF-8:**
   - W `Base.show(::WorkspaceTable)` i `_value_preview()` stosowano wycinki bajtowe (`[1:20]`, `[1:60]`, `[1:min(end, 57)]`) zamiast znakowego `first(..., N)`.

## 3. Wdrożone rozwiązanie

- **`src/ipc.jl`:**
  - W `publish_state()` wywołania `_collect_state_dod!` oraz `_get_packages` zostały owinięte w `Base.invokelatest`.
  - W `_repl_eval()` przejścia do `publish_state()` wykorzystują `Base.invokelatest(publish_state)`.
- **`src/backends.jl`:**
  - W `start()` wywołania `publish_state` w pętli `@async` watchera oraz w gałęzi `split` używają `Base.invokelatest(publish_state)`.
- **`src/workspace.jl`:**
  - Zastąpiono indeksowanie bajtowe bezpiecznym znakowym `first(..., N)` w `Base.show` i `_value_preview`.
  - W `workspace()` oraz `Base.show` zastosowano `Base.invokelatest` przy zbieraniu stanu, dostępie do pól w `Main` i wyświetlaniu.
  - Wydzielono `_snapshot_loaded_modules()` korzystający nieblokująco z `trylock(Base.require_lock)` i bufora `_last_loaded_modules` przy aktywnym ładowaniu pakietów.
  - Rozszerzono `_collect_state_dod!()` o zbieranie nieignorowanych podmodułów zdefiniowanych bezpośrednio w `Main` (`parentmodule(val) === Main`).
  - W `_get_packages()` dodano porównanie ścieżki `_last_pkg_file[]` obok `_last_pkg_mtime[]`.
  - W `inspect_var()` wydzielono `_inspect_var_details(val)` uruchamiane przez `Base.invokelatest` oraz owinięto `Base.Docs.doc` i `show` w `Base.invokelatest`.
- **`src/repl_mode.jl` i `src/procedures.jl`:**
  - Użyto `Base.invokelatest` przy refleksji na `Main` (`isdefined`, `getfield`, `names`, `repr`, `publish_state`) w `_next_proc_name()`, `_main_symbol_names()`, `_setup_repl_hooks()`, `_load_procedures!()`, `_is_global_or_type()` oraz `_default_param_str()`.

## 4. Weryfikacja

- **`Pkg.test()` w Julii 1.13.3 (`test/runtests.jl`):** `48 / 48` asercji przeszło pomyślnie bez ostrzeżeń world-age (`WARNING: Detected access to binding ...`), weryfikując m.in. automatyczne publikowanie stanu przez zadanie `@async` z `__init__()`, transmisję przez gniazdo UNIX (`SUB`), widoczność późnych zmiennych, struktur, funkcji, lokalnego podmodułu `LateLocalMod`, pakietów `Random` i `LateDynPkg`, oraz bezpieczeństwo UTF-8 w `_value_preview` i `WorkspaceTable`.
- **Test interaktywnego REPL + parsera LuaJIT (`scripts/jl_tui.lua`):** Potwierdzono obecność w `workspace()` oraz JSON stanu późnych zmiennych (`x_repl`, `pl_repl`), lokalnego podmodułu `SubReplTest` i pakietu `Dates`, brak ostrzeżeń world-age oraz poprawne parsowanie przez `json_parse` w LuaJIT (126 wpisów).
- **Testy Zig (`zig build test` w `zig/`):** Zakończone kodem wyjścia `0`.

## 5. Uwaga operacyjna (dla projektów używających wersji z GitHub)

Projekty korzystające ze źródła `[sources] jEMach = {rev = "master", url = ...}` w swoim `Project.toml` wczytują kopię z cache `~/.julia/packages/...`, a nie lokalne źródła w `/home/kitajusus/jEMach`. Aby aktywna sesja korzystała z poprawki, należy przełączyć projekt na lokalny checkout przez `Pkg.develop(path="/home/kitajusus/jEMach")` (lub wypchnąć zmiany i wykonać `Pkg.update("jEMach")`) i zrestartować proces Julii.
