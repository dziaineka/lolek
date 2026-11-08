"""Tests for typed Telegym message decoding."""

from support import CorpusTestCase

from lolek_corpus import model, telegym


def rich(*blocks):
    """Return a Telegym message with the given rich message blocks."""
    return {"rich_message": {"blocks": list(blocks)}}


class TelegymTest(CorpusTestCase):
    """Cover Telegram media response narrowing."""

    def test_message_media(self):
        self.assertEqual(
            telegym.message_media(
                rich(
                    {"type": "paragraph", "text": ["post text"]},
                    {"type": "video", "video": {"file_id": "video-id"}},
                )
            ),
            (model.MediaReference(model.TelegramMediaKind.VIDEO, "video-id"),),
        )

    def test_nested_media_keep_their_order(self):
        message = rich(
            {
                "type": "collage",
                "blocks": [
                    {
                        "type": "photo",
                        "photo": [{"file_id": "small"}, {"file_id": "large"}],
                    },
                    {"type": "animation", "animation": {"file_id": "gif-id"}},
                ],
            },
            {"type": "document", "document": {"file_id": "doc-id"}},
        )
        self.assertEqual(
            telegym.message_media(message),
            (
                model.MediaReference(model.TelegramMediaKind.PHOTO, "large"),
                model.MediaReference(model.TelegramMediaKind.ANIMATION, "gif-id"),
                model.MediaReference(model.TelegramMediaKind.DOCUMENT, "doc-id"),
            ),
        )

    def test_media_sent_by_url_are_not_uploads(self):
        message = rich(
            {"type": "photo", "photo": [{"file_id": "upload-id"}]},
            {"type": "photo", "photo": [{"file_id": "https://cdn.example/q.jpg"}]},
        )
        self.assertEqual(
            telegym.message_media(message),
            (model.MediaReference(model.TelegramMediaKind.PHOTO, "upload-id"),),
        )

    def test_rejects_messages_without_media(self):
        with self.assertRaises(model.CaseMismatch):
            telegym.message_media({"text": "hello"})
        with self.assertRaises(model.CaseMismatch):
            telegym.message_media(rich({"type": "paragraph", "text": ["only text"]}))
        with self.assertRaises(model.HarnessError):
            telegym.message_media(rich({"type": "video", "video": {"file_id": 123}}))
