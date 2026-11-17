local ESC = "\27"
local CLEAR = ESC .. "[2J" .. ESC .. "[H"
local HIDE_CUR = ESC .. "[?25l"
local SHOW_CUR = ESC .. "[?25h"
local ALT_SCREEN_ON = ESC .. "[?1049h"
local ALT_SCREEN_OFF = ESC .. "[?1049l"
local SYNC_START = ESC .. "[?2026h"
local SYNC_END = ESC .. "[?2026l"
local SET_TITLE = ESC .. "]2;jEMach — Julia Workspace\7"
local BOLD = ESC .. "[1m"
local DIM = ESC .. "[2m"
local ITALIC = ESC .. "[3m"
local RESET = ESC .. "[0m"
local REV = ESC .. "[7m" -- reverse video (selection highlight)

-- Modern 256-color palette
local FG_CYAN = ESC .. "[38;5;51m"
local FG_AQUA = ESC .. "[38;5;45m"
local FG_TEAL = ESC .. "[38;5;37m"
local FG_GREEN = ESC .. "[38;5;84m"
local FG_YELLOW = ESC .. "[38;5;221m"
local FG_ORANGE = ESC .. "[38;5;215m"
local FG_PURPLE = ESC .. "[38;5;141m"
local FG_RED = ESC .. "[38;5;203m"
local FG_WHITE = ESC .. "[38;5;255m"
local FG_LIGHT_GRAY = ESC .. "[38;5;250m"
local FG_GRAY = ESC .. "[38;5;244m"
local FG_DARK_GRAY = ESC .. "[38;5;238m"

local BG_TAB_ACT = ESC .. "[48;5;24m"
local BG_ERR_LINE = ESC .. "[48;5;52m"
local BG_PANEL = ESC .. "[48;5;235m"
local MOUSE_ON = ESC .. "[?1000h" .. ESC .. "[?1006h"
local MOUSE_OFF = ESC .. "[?1000l" .. ESC .. "[?1006l"

return {
	ESC = ESC,
	CLEAR = CLEAR,
	HIDE_CUR = HIDE_CUR,
	SHOW_CUR = SHOW_CUR,
	ALT_SCREEN_ON = ALT_SCREEN_ON,
	ALT_SCREEN_OFF = ALT_SCREEN_OFF,
	SYNC_START = SYNC_START,
	SYNC_END = SYNC_END,
	SET_TITLE = SET_TITLE,
	BOLD = BOLD,
	DIM = DIM,
	ITALIC = ITALIC,
	RESET = RESET,
	REV = REV,
	FG_CYAN = FG_CYAN,
	FG_AQUA = FG_AQUA,
	FG_TEAL = FG_TEAL,
	FG_GREEN = FG_GREEN,
	FG_YELLOW = FG_YELLOW,
	FG_ORANGE = FG_ORANGE,
	FG_PURPLE = FG_PURPLE,
	FG_RED = FG_RED,
	FG_WHITE = FG_WHITE,
	FG_LIGHT_GRAY = FG_LIGHT_GRAY,
	FG_GRAY = FG_GRAY,
	FG_DARK_GRAY = FG_DARK_GRAY,
	BG_TAB_ACT = BG_TAB_ACT,
	BG_ERR_LINE = BG_ERR_LINE,
	BG_PANEL = BG_PANEL,
	MOUSE_ON = MOUSE_ON,
	MOUSE_OFF = MOUSE_OFF,
}
