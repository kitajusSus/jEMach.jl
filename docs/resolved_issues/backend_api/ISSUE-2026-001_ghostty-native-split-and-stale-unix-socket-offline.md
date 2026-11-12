# Ghostty TUI otwiera osobne okno zamiast splitu (połowy okna) oraz pokazuje status OFFLINE przez osierocony plik gniazda UNIX

## Metadane
- **Issue ID:** ISSUE-2026-001
- **Kategoria:** `backend_api`
- **Data:** 2026-11-12
- **Status:** Resolved

---

## Opis Objawów (Symptoms & Logs)
1. W terminalu Ghostty (Hyprland/Wayland) wywołanie jEMach (Alt+j / @jemach / jEMach.start()) otwierało osobne okno systemowe zamiast podzielić bieżące okno Ghostty na pół (split-right). 2. W prawym górnym rogu TUI widniał status '[ghostty] ○ OFFLINE' mimo działającej sesji Julii, a ewaluacja i inspekcja z poziomu TUI nie komunikowały się z REPL-em.

---

## Dogłębna Przyczyna Źródłowa (Root Cause Analysis)
1. W src/jEMach.jl funkcje _start_socket_server() oraz _stop_socket_server() sprawdzały 'if isfile(path) || isfifo(path)' przed usunięciem pliku gniazda UNIX (.sock). W Julii isfile() zwraca false dla gniazd domenowych UNIX (S_IFSOCK, sprawdzane przez issocket/ispath). Przez to po zamknięciu lub restarcie Julii stary plik /tmp/jemach_*.sock nigdy nie był usuwany, a kolejna sesja Julii rzucała błąd EADDRINUSE podczas Sockets.listen(path) i nie uruchamiała serwera RPC. Dodatkowo w scripts/jl_tui.lua funkcja try_connect_socket() wywoływała io.open(socket_path, 'r'), co na gnieździe UNIX zawsze zwraca nil (ENXIO). 2. Obsługa backendu :ghostty w src/jEMach.jl oraz scripts/jl-assist uruchamiała nowy proces 'ghostty --title=jEMach ...' (osobne okno OS) zamiast wywołać natywną akcję GTK 'split-right' przez D-Bus (org.gtk.Actions.Activate na /com/mitchellh/ghostty/window/1) dla macierzystego procesu Ghostty.

---

## Zastosowane Rozwiązanie (Implemented Solution)
1. Zastąpiono warunkowe 'if isfile(path)' bezwarunkowym 'try rm(path; force = true) catch; end' w _start_socket_server() oraz _stop_socket_server(), dodano auto-wznawianie serwera gniazda w publish_state() i start() oraz usunięto błędne io.open(socket_path, 'r') w scripts/jl_tui.lua. 2. Dodano w src/jEMach.jl (_trigger_ghostty_dbus_split) oraz scripts/jl-assist detekcję macierzystego PID procesu Ghostty, identyfikację jego połączenia D-Bus i wywołanie natywnej akcji GTK 'split-right' wraz z jednorazowym bootstrapem w ~/.zshenv (/tmp/jemach_ghostty_split_<PID>.sh), co otwiera TUI bezpośrednio w prawej połowie okna Ghostty.

---

## Zabezpieczenie i Weryfikacja (Regression Prevention & Verification)
Zweryfikowano testem integracyjnym tworzenie osieroconego gniazda AF_UNIX na dysku, ponowne uruchomienie jEMach.start(), poprawne nadpisanie gniazda i połączenie klienta (isopen=true) oraz czyszczenie gniazda po jEMach.stop(). Zsynchronizowano również poprawkę z zainstalowaną paczką w ~/.julia/packages/jEMach/xcKnJ.
