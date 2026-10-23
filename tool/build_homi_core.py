#!/usr/bin/env python3
"""Build with the checked public profile and the existing ignored private config.
Does not install, deploy, migrate, stage, or commit. Capability evidence must be
captured from the selected service; credentials and response contents are not printed.
"""
import argparse
import json
import subprocess
from pathlib import Path
from validate_feature_profile import validate

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config',required=True)
    parser.add_argument('--capabilities',required=True)
    parser.add_argument('--platform',choices=['ios','apk','appbundle'],required=True)
    parser.add_argument('--flutter',default='flutter')
    args=parser.parse_args()
    root=Path(__file__).resolve().parent.parent
    profile=root/'config/homi-core.features.json'
    private=Path(args.config).resolve()
    try:
        if not private.is_file(): raise ValueError('Private configuration file is missing.')
        ignored=subprocess.run(['git','check-ignore','--quiet',str(private)],cwd=root,check=False)
        if ignored.returncode != 0: raise ValueError('Private configuration must be in an ignored path.')
        validate(json.loads(profile.read_text()),json.loads(Path(args.capabilities).read_text()))
    except (ValueError,OSError):
        parser.exit(1,'Build rejected: check ignored configuration and selected-service capability evidence with validate_feature_profile.py.\n')
    return subprocess.call([args.flutter,'build',args.platform,'--no-pub',
        f'--dart-define-from-file={private}',f'--dart-define-from-file={profile}'],cwd=root)

if __name__=='__main__': raise SystemExit(main())
