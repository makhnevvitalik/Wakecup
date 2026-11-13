import importlib.util
from pathlib import Path
import plistlib
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("release_metadata", Path(__file__).resolve().parents[1] / "Tools/release_metadata.py")
metadata = importlib.util.module_from_spec(spec)
spec.loader.exec_module(metadata)


class ReleaseMetadataTests(unittest.TestCase):
    def check_metadata(self, version="1.0.0", build="10", tag=None):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "Info.plist"
            path.write_bytes(plistlib.dumps({"CFBundleShortVersionString": version, "CFBundleVersion": build}))
            return metadata.read_metadata(path, tag)

    def test_matching_tag(self):
        self.assertEqual(self.check_metadata(tag="v1.0.0"), {"version": "1.0.0", "build": "10"})

    def test_local_build_needs_no_tag(self):
        self.assertEqual(self.check_metadata()["version"], "1.0.0")

    def test_rejects_mismatched_or_malformed_tags(self):
        for tag in ["v1.0.1", "1.0.0", "v1.0.0-beta", "v1.0.0\n", "v1.0.0;echo unsafe"]:
            with self.subTest(tag=tag), self.assertRaises(ValueError):
                self.check_metadata(tag=tag)

    def test_rejects_invalid_versions(self):
        for version in ["1", "1.0", "1.0.0-beta", "1.0.0\n", 100]:
            with self.subTest(version=version), self.assertRaises(ValueError):
                self.check_metadata(version=version)

    def test_rejects_invalid_builds(self):
        for build in ["0", "-1", "1.2", "10\n", 10]:
            with self.subTest(build=build), self.assertRaises(ValueError):
                self.check_metadata(build=build)


if __name__ == "__main__":
    unittest.main()
