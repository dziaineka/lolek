"""Tests for typed Telegym message decoding."""

from support import CorpusTestCase

from lolek_corpus import model, telegym


class TelegymTest(CorpusTestCase):
    """Cover Telegram media response narrowing."""

    def test_message_media(self):
        self.assertEqual(
            telegym.message_media({"video": {"file_id": "video-id"}}),
            (model.MediaReference(model.TelegramMediaKind.VIDEO, "video-id"),),
        )
        self.assertEqual(
            telegym.message_media(
                {"photo": [{"file_id": "small"}, {"file_id": "large"}]}
            ),
            (model.MediaReference(model.TelegramMediaKind.PHOTO, "large"),),
        )
        with self.assertRaises(model.HarnessError):
            telegym.message_media({"video": {"file_id": 123}})
        with self.assertRaises(model.CaseMismatch):
            telegym.message_media({"text": "no media"})

    def test_rich_message_media(self):
        message = {
            "rich_message": {
                "blocks": [
                    {
                        "type": "collage",
                        "blocks": [
                            {
                                "type": "photo",
                                "photo": [{"file_id": "s"}, {"file_id": "p"}],
                            },
                            {"type": "video", "video": {"file_id": "v"}},
                        ],
                    },
                    {"type": "animation", "animation": {"file_id": "g"}},
                    {"type": "footer", "text": ["requested by ", "Someone"]},
                ]
            }
        }
        self.assertEqual(
            telegym.message_media(message),
            (
                model.MediaReference(model.TelegramMediaKind.PHOTO, "p"),
                model.MediaReference(model.TelegramMediaKind.VIDEO, "v"),
                model.MediaReference(model.TelegramMediaKind.ANIMATION, "g"),
            ),
        )
        with self.assertRaises(model.CaseMismatch):
            telegym.message_media({"rich_message": {"blocks": [{"type": "paragraph"}]}})
