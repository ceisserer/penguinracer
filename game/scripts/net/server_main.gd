## The dedicated server. One process, two listeners, no window.
##
## [codeblock]
## godot --headless --path game res://scenes/server.tscn -- \
##     --port=27015 --web-root=../build/web --web-port=8060
## [/codeblock]
##
## [b]It serves both kinds of player from one place.[/b] The game port carries
## the race sessions, over WebSocket, which a native build and a browser can
## both open — so a desktop player and a player in a tab are in the same room,
## racing the same hill, with no second protocol anywhere in the stack. The web
## port hands out the WebAssembly build itself ([WebFileServer]), so the machine
## running the server is also where the game comes from: open
## `http://<server>:8060/` and the lobby's address field is already filled in
## with the host that served the page (see [method RaceNetwork.default_address]).
## Leave `--web-root` off and it is a game server alone, which is what it is
## when a real static host or a CDN is serving the build.
##
## [b]It is the game's own project, run headless.[/b] Not a second Godot project
## and not a Node program: [LobbyServer] is the file the game already links, so
## the protocol cannot drift between the two ends — there is only one copy of
## it. The cost is that the server binary carries the whole game, which for a
## 65 MB export is a fair trade against maintaining a second implementation of
## every message.
##
## Nothing here renders, loads a course or steps a simulation. The server does
## not know what a penguin is: it keeps the room list and forwards snapshots
## between the people in a room ([RaceNetwork]), and every position on every
## hill is computed on the machine that owns it.
class_name ServerMain
extends Node

var _web: WebFileServer

func _ready() -> void:
	var args: LaunchArgs = LaunchArgs.current()
	var port: int = args.server_port if args.server_port > 0 else RaceNetwork.DEFAULT_PORT
	if Net.serve(port) != OK:
		push_error("could not open the game port — nothing to serve")
		get_tree().quit(1)
		return
	print("PenguinRacer server")
	print("  races      ws://0.0.0.0:%d" % port)
	if not args.web_root.is_empty():
		_serve_web(args.web_root, args.web_port)
	else:
		print("  web build  not served (pass --web-root=<dir> to serve one)")
	print("  rooms      up to %d, %d racers each" % [
		LobbyServer.MAX_ROOMS, LobbyServer.MAX_PLAYERS_PER_ROOM])
	print("  ready")

func _serve_web(web_root: String, web_port: int) -> void:
	_web = WebFileServer.new()
	_web.name = "WebFileServer"
	add_child(_web)
	if _web.listen(web_root, web_port) != OK:
		print("  web build  NOT served — %s is not a directory" % web_root)
		print("             (a relative --web-root is relative to the project "
			+ "directory; pass an absolute one, or use tools/serve.sh)")
		return
	print("  web build  http://0.0.0.0:%d/  (from %s)" % [web_port, _web.root])

func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST or what == NOTIFICATION_CRASH:
		if _web != null:
			_web.stop()
		Net.leave("")
