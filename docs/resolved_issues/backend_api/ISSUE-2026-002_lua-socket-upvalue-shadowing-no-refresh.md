# Brak odświeżania stanu TUI po połączeniu przez gniazdo UNIX (przesłonięcie zmiennych lokalnych w LuaJIT)

## Metadane
- **Issue ID:** ISSUE-2026-002
- **Kategoria:** `backend_api`
- **Data:** 2026-11-12
- **Status:** Resolved

---

## Opis Objawów (Symptoms & Logs)
Po uruchomieniu jEMach w trybie Ghostty (jEMach.start(backend=:ghostty) / jEMach.backend(:ghostty)) panel TUI łączył się z gniazdem UNIX (status [ghostty] ● ONLINE), ale nie odświeżał widoku Workspace, History ani zegara po utworzeniu nowych zmiennych w REPL-u Julii (np. x = [1:2:100]).

---

## Dogłębna Przyczyna Źródłowa (Root Cause Analysis)
1. W scripts/jl_tui.lua funkcja json_parse była zadeklarowana wyprzedzająco w linii 83 jako 'local json_parse', ale w linii 585 zdefiniowano ją jako 'local function json_parse(s)', co w Lua tworzy nową zmienną lokalną przesłaniającą wcześniejszą deklarację. Przez to wewnątrz handle_socket_read() (zdefiniowanego w linii 213) upvalue json_parse miał zawsze wartość nil, a pcall(json_parse, line) cicho odrzucało każdą wiadomość z gniazda. 2. Zmienne 'local state' oraz 'local last_state_ts' były zadeklarowane dopiero w liniach 774-776 (poniżej handle_socket_read()), przez co handle_socket_read() zapisywał odebrany stan do zmiennych globalnych (_G.state, _G.last_state_ts) zamiast lokalnych używanych przez build_display_rows() i render(). Jednocześnie load_state() pomijało odczyt pliku przy aktywnym gnieździe (socket_fd >= 0).

---

## Zastosowane Rozwiązanie (Implemented Solution)
1. W scripts/jl_tui.lua przeniesiono deklaracje 'local state = nil', 'local last_mtime = 0' oraz 'local last_state_ts = 0' powyżej handle_socket_read() oraz zamieniono 'local function json_parse(s)' na przypisanie do istniejącej zmiennej lokalnej 'json_parse = function(s)'. 2. Dodano w handle_socket_read() pętlowe doczytywanie ramek z gniazda do znaku nowej linii oraz awaryjny fallback w load_state(), gdy przez 3 sekundy nie nadejdzie ramka z gniazda. 3. Dodano funkcję pomocniczą jEMach.backend(b::Symbol) w src/jEMach.jl oraz zsynchronizowano poprawki z zainstalowaną paczką w ~/.julia/packages/jEMach/.

---

## Zabezpieczenie i Weryfikacja (Regression Prevention & Verification)
Zweryfikowano za pomocą analizy bajtkodu LuaJIT (luajit -bl scripts/jl_tui.lua | grep GSET — zero zapisów do zmiennych globalnych) oraz testu integracyjnego z aktywnym gniazdem /tmp/jemach_*.sock potwierdzającego natychmiastowe odświeżanie zmiennych (w tym x = [1:2:100]) i znacznika czasu last_state_ts.
