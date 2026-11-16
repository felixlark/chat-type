# ChatType-owned Sublime Text integration. Uses the public plugin API only.
# API: https://www.sublimetext.com/docs/api_reference.html
import json
import os
import socket
import select
import stat
import threading
import uuid

import sublime
import sublime_plugin

PROTOCOL = 1
BUILD = 136
ROOT = os.path.expanduser('~/Library/Application Support/ChatType/EditorBridge')
SOCKET = os.path.join(ROOT, 'sublime.sock')
_sessions = {}
_listener = None
_connections = set()
_connections_lock = threading.Lock()


def _key(session):
    return 'chattype.target.' + session


def _reply(status, **fields):
    return dict(protocol=PROTOCOL, build=BUILD, revision=2, status=status, **fields)


def _geometry(state):
    view = state['view']
    if not view.is_valid() or not view.window():
        return _reply('unavailable')
    regions = view.get_regions(state['key'])
    if not regions:
        return _reply('unavailable')
    caret = view.text_to_window(regions[0].begin())
    origin = view.layout_to_window(view.viewport_position())
    extent = view.viewport_extent()
    settings = view.settings()
    style = view.style()
    window = view.window()
    visible = sublime.active_window() == window and window.active_view() == view
    return _reply('active', viewID=view.id(), visible=visible,
                  caretX=caret[0], caretY=caret[1], lineHeight=view.line_height(),
                  viewportX=origin[0], viewportY=origin[1], width=extent[0], height=extent[1],
                  fontName=settings.get('font_face') or 'Menlo', fontSize=settings.get('font_size') or 12,
                  foreground=style.get('foreground', '#222222'), background=style.get('background', '#ffffff'))


def dispatch(request):
    if request.get('protocol') != PROTOCOL:
        return _reply('unavailable')
    operation = request.get('operation')
    if operation == 'health':
        return _reply('ready')
    session = request.get('session', '')
    try:
        if str(uuid.UUID(session)) != session.lower():
            return _reply('unavailable')
    except (ValueError, TypeError, AttributeError):
        return _reply('unavailable')
    state = _sessions.get(session)
    if operation == 'begin':
        if state:
            return state.get('receipt') or _geometry(state)
        window = sublime.active_window()
        view = window.active_view() if window else None
        if not view or not view.is_valid() or view.is_read_only() or not list(view.sel()):
            return _reply('unavailable')
        regions = list(view.sel())
        state = dict(view=view, key=_key(session), originals=[view.substr(r) for r in regions])
        view.add_regions(state['key'], regions, '', flags=sublime.HIDDEN | sublime.NO_UNDO)
        _sessions[session] = state
        return _geometry(state)
    if not state:
        return _reply('missing')
    if operation == 'status':
        return state.get('receipt') or _geometry(state)
    if operation == 'geometry':
        return _geometry(state)
    if operation == 'close':
        if state['view'].is_valid():
            state['view'].erase_regions(state['key'])
        _sessions.pop(session, None)
        return _reply('closed')
    if operation == 'commit':
        if state.get('receipt'):
            return state['receipt']
        view = state['view']
        if not view.is_valid() or view.is_read_only():
            return _reply('unavailable')
        regions = view.get_regions(state['key'])
        if len(regions) != len(state['originals']) or [view.substr(r) for r in regions] != state['originals']:
            return _reply('diverged')
        text = request.get('text')
        if not isinstance(text, str):
            return _reply('unavailable')
        # TextCommand runs synchronously on Sublime's main thread, exactly once.
        state['receipt'] = _reply('outputUnknown', finalApplied=True)
        view.run_command('chattype_insert_final', dict(session=session, text=text))
        return state['receipt']
    return _reply('unavailable')


class ChattypeInsertFinalCommand(sublime_plugin.TextCommand):
    def run(self, edit, session, text):
        state = _sessions.get(session)
        if not state or state['view'] != self.view:
            return
        regions = self.view.get_regions(state['key'])
        advance = list(self.view.sel()) == regions
        matched = True
        end_points = []
        for index in range(len(regions) - 1, -1, -1):
            current = self.view.get_regions(state['key'])
            region = current[index]
            before_size = self.view.size()
            self.view.replace(edit, region, text)
            length = region.size() + self.view.size() - before_size
            inserted = sublime.Region(region.begin(), region.begin() + length)
            matched = matched and self.view.substr(inserted) == text
            current = self.view.get_regions(state['key'])
            current[index] = inserted
            self.view.add_regions(state['key'], current, '', flags=sublime.HIDDEN | sublime.NO_UNDO)
        if advance:
            end_points = [r.end() for r in self.view.get_regions(state['key'])]
            self.view.sel().clear()
            for point in end_points:
                self.view.sel().add(sublime.Region(point))
        self.view.erase_regions(state['key'])
        state['receipt'] = _reply('committed' if matched else 'outputUnknown', finalApplied=True, matched=matched, viewID=self.view.id())


def _handle(connection):
    cancelled = threading.Event()
    owner = _listener
    wake_read, wake_write = socket.socketpair()
    with _connections_lock:
        _connections.add(connection)
    try:
        with connection, connection.makefile('rb') as stream:
            request = json.loads(stream.readline().decode('utf-8'))
            def complete():
                try:
                    if cancelled.is_set() or owner is not _listener:
                        return
                    # Check the peer directly at the mutation boundary. The
                    # background select thread may not have processed EOF yet.
                    try:
                        if not connection.recv(1, socket.MSG_PEEK | socket.MSG_DONTWAIT):
                            return
                    except BlockingIOError:
                        pass
                    except OSError:
                        return
                    try:
                        result = dispatch(request)
                    except Exception:
                        result = _reply('outputUnknown' if request.get('operation') == 'commit' else 'unavailable')
                    try:
                        connection.sendall(json.dumps(result).encode('utf-8') + b'\n')
                        connection.shutdown(socket.SHUT_WR)
                    except OSError:
                        pass
                finally:
                    try:
                        wake_write.send(b'1')
                    except OSError:
                        pass
            sublime.set_timeout(complete, 0)
            readable, _, _ = select.select([connection, wake_read], [], [])
            if connection in readable and not connection.recv(1, socket.MSG_PEEK):
                cancelled.set()
    except (OSError, ValueError, UnicodeError):
        cancelled.set()
    finally:
        wake_read.close()
        wake_write.close()
        with _connections_lock:
            _connections.discard(connection)


def plugin_loaded():
    global _listener
    os.makedirs(ROOT, mode=0o700, exist_ok=True)
    os.chmod(ROOT, 0o700)
    if os.path.lexists(SOCKET):
        info = os.lstat(SOCKET)
        if not stat.S_ISSOCK(info.st_mode) or info.st_uid != os.getuid():
            return
        os.unlink(SOCKET)
    listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    listener.bind(SOCKET)
    os.chmod(SOCKET, 0o600)
    # Backlog is the operating system socket.SOMAXCONN constant.
    listener.listen(socket.SOMAXCONN)
    _listener = listener
    def serve():
        while _listener is listener:
            try:
                connection, _ = listener.accept()
            except OSError:
                return
            threading.Thread(target=_handle, args=(connection,), daemon=True).start()
    threading.Thread(target=serve, daemon=True).start()


def plugin_unloaded():
    global _listener
    listener, _listener = _listener, None
    with _connections_lock:
        for connection in list(_connections):
            try:
                connection.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
    if listener:
        listener.close()
        if os.path.exists(SOCKET):
            os.unlink(SOCKET)
    for state in list(_sessions.values()):
        if state['view'].is_valid():
            state['view'].erase_regions(state['key'])
    _sessions.clear()
