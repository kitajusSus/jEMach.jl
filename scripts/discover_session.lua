local dir = assert(arg[0]:match("^(.*)/[^/]+$"))
package.path = dir .. "/?.lua;" .. package.path
local sessions = require("tui.sessions")
local session, err = sessions.select(arg[1])
if not session then
	io.stderr:write(err .. "\n")
	os.exit(1)
end
io.write(session.socket .. "\n" .. session.state .. "\n")
