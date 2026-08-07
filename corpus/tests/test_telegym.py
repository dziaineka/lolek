"""Tests for typed Telegym message decoding."""

from support import CorpusTestCase

from lolek_corpus import model, telegym


class TelegymTest(CorpusTestCase):
    """Cover Telegram media response narrowing."""

    def test_message_media(self):
        self.assertEqual(
            telegym.message_media({"video": {"file_id": "video-id"}}),
            model.MediaReference(model.TelegramMediaKind.VIDEO, "video-id"),
        )
        self.assertEqual(
            telegym.message_media(
                {"photo": [{"file_id": "small"}, {"file_id": "large"}]}
            ),
            model.MediaReference(model.TelegramMediaKind.PHOTO, "large"),
        )
        with self.assertRaises(model.HarnessError):
            telegym.message_media({"video": {"file_id": 123}})
