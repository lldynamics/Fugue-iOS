"""Play English learner speech from the Mac speaker during opt-in physical iPad tests."""

import argparse
from contextlib import contextmanager
from datetime import datetime
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile


@contextmanager
def speaker_volume(level):
    def read():
        return int(subprocess.check_output(["osascript", "-e", "output volume of (get volume settings)"], text=True))

    def set_level(value):
        subprocess.run(["osascript", "-e", f"set volume output volume {value}"], check=True)

    if level is None:
        yield
        return
    previous = read()
    applied = previous
    try:
        set_level(level)
        applied = read()
        yield
    finally:
        if read() == applied:
            set_level(previous)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--xctestrun", required=True, type=Path)
    parser.add_argument("--device", required=True, help="Physical iOS device UDID")
    parser.add_argument("--result", required=True, type=Path, help="New .xcresult path")
    parser.add_argument("--ui", action="store_true", help="Exercise the foreground practice controls")
    parser.add_argument("--speaker-volume", type=int, choices=range(1, 101), metavar="1..100",
                        help="Temporary Mac volume during each fixture; restores the previous level afterwards")
    args = parser.parse_args()
    tests = plistlib.loads(args.xctestrun.read_bytes())
    for configuration in tests["TestConfigurations"]:
        for target in configuration["TestTargets"]:
            target["EnvironmentVariables"].update(
                FUGUE_DEVICE_ACCEPTANCE="1", FUGUE_PRACTICE_SPEAKER_FIXTURE="1"
            )

    sentences = {"manual": "Yesterday I go to the bookstore and buy a green notebook."}
    if args.ui:
        test = "iOSBoxUITests/ModelWorkshopFlowTests/testOpenAIPracticeControlsOnDevice"
    else:
        test = "iOSBoxTests/PhysicalModelAcceptanceTests/testCoachingOnSpeakerThenTapAndReview"
        sentences["count"] = "Please count slowly from one to forty. Say every number out loud."
        sentences["barge"] = "Stop counting. Say just the word blue."

    # __TESTROOT__ in the generated plist is relative to the .xctestrun's directory.
    with tempfile.NamedTemporaryFile(dir=args.xctestrun.parent, suffix=".xctestrun") as run:
        plistlib.dump(tests, run)
        run.flush()
        with tempfile.TemporaryDirectory() as folder:
            fixtures = {}
            for cue, sentence in sentences.items():
                path = Path(folder) / (cue + ".aiff")
                subprocess.run(["/usr/bin/say", "-v", "Samantha", "-r", "150", "-o", path, sentence], check=True)
                fixtures["FUGUE_PRACTICE " + cue] = path
            command = [
                "xcodebuild", "test-without-building", "-xctestrun", run.name,
                "-destination", "platform=iOS,id=" + args.device, "-parallel-testing-enabled", "NO",
                "-collect-test-diagnostics", "never", "-only-testing:" + test, "-resultBundlePath", args.result,
            ]
            with subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                  text=True, env={**os.environ, "NSUnbufferedIO": "YES"}) as process:
                for line in process.stdout:
                    print(line.rstrip(), flush=True)
                    path = fixtures.pop(line.strip(), None)
                    if path:
                        with speaker_volume(args.speaker_volume):
                            print(f"Host playback {path.stem} {datetime.now().isoformat(timespec='milliseconds')}", flush=True)
                            subprocess.run(["/usr/bin/afplay", path], check=True)
                code = process.wait()
            if code:
                return code
            if fixtures:
                print("The device test ended without requesting all speaker fixtures.", flush=True)
                return 1
            return 0


if __name__ == "__main__":
    raise SystemExit(main())
