import unittest

from mcp_server import CALENDAR_TOOL


class McpToolDescriptionTests(unittest.TestCase):
    def test_description_uses_neutral_equal_participant_language(self):
        description = CALENDAR_TOOL["function"]["description"]
        self.assertIn("equal dignity", description)
        self.assertIn("authorized", description)
        self.assertNotIn("Master", description)
        self.assertNotIn("partner's phone", description)

    def test_schema_exposes_metadata_for_web_annotation_fields(self):
        properties = CALENDAR_TOOL["function"]["parameters"]["properties"]
        self.assertIn("metadata", properties)
        self.assertEqual(properties["metadata"]["type"], "object")


if __name__ == "__main__":
    unittest.main()
