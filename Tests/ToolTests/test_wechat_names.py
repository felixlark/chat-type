import importlib.util
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("chattype_wechat_names", ROOT / "Sources/ChatType/Resources/wechat_names.py")
reader = importlib.util.module_from_spec(spec)
spec.loader.exec_module(reader)

class WeChatNamesTests(unittest.TestCase):
    def test_names_only_excludes_service_accounts_and_groups(self):
        text = """找到 5 个联系人:
wxid_person  备注: 林明  昵称: Alice Smith
room@chatroom  昵称: 不应导入群聊
notifymessage  昵称: 服务通知
gh_official  昵称: 公众号
qqmail  昵称: QQ邮箱提醒
qmessage  昵称: QQ离线消息
floatbottle  昵称: 漂流瓶
wxid_nickname  昵称: 昵称独立可读
"""
        self.assertEqual(reader.personal_names(text), ["林明", "Alice Smith", "昵称独立可读"])
        self.assertFalse(any("wxid" in name for name in reader.personal_names(text)))

if __name__ == "__main__":
    unittest.main()
