import json
import unittest


def parse_business_code(response: str):
    try:
        value = json.loads(response)
    except (json.JSONDecodeError, TypeError):
        return "invalid", None
    if not isinstance(value, dict):
        return "invalid", None
    if "code" not in value:
        return "missing", None
    code = value["code"]
    if isinstance(code, bool):
        return "invalid", None
    if isinstance(code, int):
        return "ok", code
    if isinstance(code, str) and code and (
        code.isdigit() or (code.startswith("-") and code[1:].isdigit())
    ):
        return "ok", int(code)
    return "invalid", None


class PushPlusResponseModelTests(unittest.TestCase):
    def test_valid_numeric_and_string_codes(self):
        self.assertEqual(parse_business_code('{"code":200,"msg":"ok"}'), ("ok", 200))
        self.assertEqual(parse_business_code('{"code":"200","data":{}}'), ("ok", 200))

    def test_missing_and_nested_code_are_not_success(self):
        self.assertEqual(parse_business_code('{"msg":"ok"}'), ("missing", None))
        self.assertEqual(
            parse_business_code('{"data":{"code":200}}'), ("missing", None)
        )

    def test_malformed_responses_are_invalid(self):
        cases = (
            '{"code":200,',
            '{"code":200}garbage',
            '{"code":+200}',
            '{"code":200garbage}',
            '{"code":true}',
            '{"code":200,}',
        )
        for response in cases:
            with self.subTest(response=response):
                self.assertEqual(parse_business_code(response), ("invalid", None))


if __name__ == "__main__":
    unittest.main()
