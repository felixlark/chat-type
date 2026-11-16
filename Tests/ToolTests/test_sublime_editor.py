import importlib.util
import json
import pathlib
import socket
import sys
import threading
import time
import types
import unittest
import uuid

SOURCE = pathlib.Path(__file__).parents[2] / 'Sources/ChatType/Resources/Sublime/ChatType.py'

class Region:
    def __init__(self, a, b=None): self.a, self.b = a, a if b is None else b
    def begin(self): return min(self.a, self.b)
    def end(self): return max(self.a, self.b)
    def size(self): return self.end() - self.begin()
    def __eq__(self, other): return isinstance(other, Region) and (self.a, self.b) == (other.a, other.b)

class Selection(list):
    def add(self, r): self.append(r)

class View:
    def __init__(self, value):
        self.value = value; self.selected = Selection([Region(2, 4)]); self.regions = {}; self.valid = True; self.read_only = False
    def id(self): return 123
    def is_valid(self): return self.valid
    def is_read_only(self): return self.read_only
    def window(self): return window
    def sel(self): return self.selected
    def substr(self, r): return self.value[r.begin():r.end()]
    def size(self): return len(self.value)
    def add_regions(self, key, regions, *args, **kwargs): self.regions[key] = list(regions)
    def get_regions(self, key): return list(self.regions.get(key, []))
    def erase_regions(self, key): self.regions.pop(key, None)
    def text_to_window(self, point): return (10 + point * 9, 50)
    def viewport_position(self): return (0, 0)
    def layout_to_window(self, xy): return (10, 30)
    def viewport_extent(self): return (600, 400)
    def settings(self): return {'font_face': 'Menlo', 'font_size': 16}
    def style(self): return {'foreground': '#ffffff', 'background': '#333333'}
    def line_height(self): return 20
    def replace(self, edit, region, text):
        a, b = region.begin(), region.end(); delta = len(text) - (b - a)
        self.value = self.value[:a] + text + self.value[b:]
        for key, regions in list(self.regions.items()):
            self.regions[key] = [Region(r.a + (delta if r.a >= b else 0), r.b + (delta if r.b >= b else 0)) for r in regions]
    def run_command(self, command, args):
        command = plugin.ChattypeInsertFinalCommand(); command.view = self; command.run(None, **args)

window = types.SimpleNamespace(active_view=lambda: None)
pending = []
sublime = types.SimpleNamespace(HIDDEN=128, NO_UNDO=8192, Region=Region, active_window=lambda: window,
                                set_timeout=lambda callback, _: pending.append(callback))
prior_sublime, prior_plugin = sys.modules.get('sublime'), sys.modules.get('sublime_plugin')
sys.modules['sublime'] = sublime
sys.modules['sublime_plugin'] = types.SimpleNamespace(TextCommand=object)
spec = importlib.util.spec_from_file_location('chattype_editor_test', SOURCE)
plugin = importlib.util.module_from_spec(spec); spec.loader.exec_module(plugin)
if prior_sublime is None: sys.modules.pop('sublime')
else: sys.modules['sublime'] = prior_sublime
if prior_plugin is None: sys.modules.pop('sublime_plugin')
else: sys.modules['sublime_plugin'] = prior_plugin

class SublimeEditorTests(unittest.TestCase):
    def setUp(self):
        self.view = View('前🙂选中后'); window.active_view = lambda: self.view
        plugin._sessions.clear(); pending.clear()
        self.session = str(uuid.uuid4())
    def call(self, operation, **fields):
        return plugin.dispatch(dict(protocol=1, session=self.session, operation=operation, **fields))
    def test_pin_is_presentation_only_and_commit_is_idempotent(self):
        reply = self.call('begin'); self.assertEqual(reply['fontSize'], 16)
        self.assertEqual(self.view.value, '前🙂选中后')
        other = View('other'); window.active_view = lambda: other
        self.assertFalse(self.call('geometry')['visible'])
        self.assertEqual(self.call('commit', text='终稿')['status'], 'committed')
        self.assertEqual(self.view.value, '前🙂终稿后'); self.assertEqual(other.value, 'other')
        self.call('commit', text='不应再写'); self.assertEqual(self.view.value, '前🙂终稿后')
        self.assertEqual(self.call('status')['status'], 'committed')
        self.call('close'); self.assertEqual(self.call('commit', text='late')['status'], 'missing')
    def test_cancel_does_not_edit_document(self):
        self.call('begin'); self.call('close'); self.assertEqual(self.view.value, '前🙂选中后')
        self.assertFalse(self.view.regions)
    def test_user_edit_in_owned_selection_is_preserved(self):
        self.call('begin'); self.view.value = '前🙂手改后'
        self.assertEqual(self.call('commit', text='终稿')['status'], 'diverged')
        self.assertEqual(self.view.value, '前🙂手改后')
    def test_prefix_edit_tracks_original_region(self):
        self.call('begin'); self.view.replace(None, Region(0), '新')
        self.assertEqual(self.call('commit', text='终稿')['status'], 'committed')
        self.assertEqual(self.view.value, '新前🙂终稿后')
    def test_multiple_unicode_and_multiline_selections(self):
        self.view.value = '🙂甲\n🙂乙'; self.view.selected = Selection([Region(1, 2), Region(4, 5)])
        self.call('begin'); self.assertTrue(self.call('commit', text='整\n理')['matched'])
        self.assertEqual(self.view.value, '🙂整\n理\n🙂整\n理')
    def test_closed_and_readonly_targets_reject_without_writing(self):
        self.call('begin'); self.view.read_only = True
        self.assertEqual(self.call('commit', text='终稿')['status'], 'unavailable')
        self.view.valid = False
        self.assertEqual(self.call('geometry')['status'], 'unavailable')
        self.assertEqual(self.view.value, '前🙂选中后')
    def test_disconnect_cancels_queued_editor_mutation(self):
        self.call('begin'); plugin._listener = object()
        client, server = socket.socketpair()
        worker = threading.Thread(target=plugin._handle, args=(server,)); worker.start()
        client.sendall(json.dumps(dict(protocol=1, session=self.session, operation='commit', text='must not write')).encode() + b'\n')
        deadline = time.monotonic() + 2
        while not pending and time.monotonic() < deadline: time.sleep(0.005)
        self.assertTrue(pending); client.close(); worker.join(2); self.assertFalse(worker.is_alive())
        pending.pop()(); self.assertEqual(self.view.value, '前🙂选中后')

    def test_closed_peer_is_checked_by_callback_before_worker_observes_eof(self):
        self.call('begin'); plugin._listener = object()
        client, server = socket.socketpair()
        worker = threading.Thread(target=plugin._handle, args=(server,)); worker.start()
        client.sendall(json.dumps(dict(protocol=1, session=self.session, operation='commit', text='CANCELLED FINAL')).encode() + b'\n')
        deadline = time.monotonic() + 2
        while not pending and time.monotonic() < deadline: time.sleep(0.005)
        self.assertTrue(pending)
        previous = sys.getswitchinterval()
        try:
            sys.setswitchinterval(0.5)
            client.shutdown(socket.SHUT_RDWR); client.close()
            pending.pop()()  # Do not join/yield to the EOF observer first.
            self.assertEqual(self.view.value, '前🙂选中后')
        finally:
            sys.setswitchinterval(previous)
            worker.join(2)
        self.assertFalse(worker.is_alive())
