#!/usr/bin/env python3
"""Reject an advertised client feature without authenticated backend evidence.

Supply a JSON response captured from POST /v1/capabilities for the chosen service.
Only booleans are printed. Origins, keys and access tokens never enter this file.
"""
import argparse
import json
from pathlib import Path

FEATURES = {
    'SAFEATHOME_HOME_SAFETY_ENABLED': 'structuredRooms',
    'SAH_TRACKING_ENABLED': 'tracking',
    'SAH_SCAN_SYNC_ENABLED': 'scanSync',
    'SAH_PERMISSION_SHARING_ENABLED': 'permissionSharing',
    'SAH_SENSITIVE_SHARING_ENABLED': 'sensitiveSharing',
    'SAH_SIMPLE_INVITATIONS_ENABLED': 'simpleInvitations',
}
PUBLIC = set(FEATURES) | {'SAH_LIVE_BACKEND', 'SAH_LOCAL_HELP_ENABLED',
    'SAH_EMAIL_DELIVERY_ENABLED', 'SAH_PUBLIC_SIGNUP_ENABLED'}

def validate(profile, capabilities):
    if not isinstance(profile, dict) or set(profile) != PUBLIC or any(type(v) is not bool for v in profile.values()):
        raise ValueError('Profile must contain exactly the documented public boolean controls.')
    if not isinstance(capabilities, dict) or set(capabilities) != {'schemaVersion', 'features'} or capabilities.get('schemaVersion') != '1' or not isinstance(capabilities.get('features'), dict):
        raise ValueError('Authenticated capability evidence is missing or unsupported.')
    if set(capabilities['features']) != set(FEATURES.values()) or any(type(v) is not bool for v in capabilities['features'].values()):
        raise ValueError('Capability evidence must contain exactly the documented boolean features.')
    for flag, feature in FEATURES.items():
        if profile[flag] and capabilities['features'].get(feature) is not True:
            raise ValueError(f'{flag} is enabled but the selected backend does not advertise {feature}.')
    if any(profile[f] for f in ['SAH_SENSITIVE_SHARING_ENABLED', 'SAH_SIMPLE_INVITATIONS_ENABLED']) and not profile['SAH_PERMISSION_SHARING_ENABLED']:
        raise ValueError('Detailed sharing/invitations require permission sharing.')
    if profile['SAH_PUBLIC_SIGNUP_ENABLED'] and not profile['SAH_EMAIL_DELIVERY_ENABLED']:
        raise ValueError('Public signup requires separately verified email delivery.')

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--profile', default='config/homi-core.features.json')
    parser.add_argument('--capabilities', required=True)
    args = parser.parse_args()
    try:
        validate(json.loads(Path(args.profile).read_text()), json.loads(Path(args.capabilities).read_text()))
    except (ValueError, OSError) as error:
        parser.exit(1, f'Profile rejected: {error}\n')
    print('Profile matches supplied backend capability evidence. Physical-device acceptance is separate.')
