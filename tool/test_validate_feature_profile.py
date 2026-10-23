import json
import unittest
from pathlib import Path
from validate_feature_profile import validate

class ProfileTests(unittest.TestCase):
    def setUp(self):
        self.profile = json.loads((Path(__file__).parent.parent/'config/homi-core.features.json').read_text())
        self.evidence = {'schemaVersion':'1', 'features':{
            'structuredRooms':True, 'tracking':True, 'scanSync':False,
            'permissionSharing':False, 'sensitiveSharing':False, 'simpleInvitations':False}}
    def test_known_local_routes(self):
        validate(self.profile, self.evidence)
    def test_disabled_server_rejected(self):
        self.evidence['features']['tracking']=False
        with self.assertRaises(ValueError): validate(self.profile,self.evidence)
    def test_missing_version_and_unknown_public_controls_rejected(self):
        with self.assertRaises(ValueError): validate(self.profile,{})
        self.profile['PRIVATE_KEY']='not-allowed'
        with self.assertRaises(ValueError): validate(self.profile,self.evidence)
    def test_invitation_dependency(self):
        self.profile['SAH_SIMPLE_INVITATIONS_ENABLED']=True
        self.evidence['features']['simpleInvitations']=True
        with self.assertRaises(ValueError): validate(self.profile,self.evidence)
    def test_malformed_capabilities_rejected(self):
        for evidence in [None, [], {'schemaVersion':'1','features':{'structuredRooms':True,'tracking':True}}]:
            with self.assertRaises(ValueError): validate(self.profile,evidence)
        self.evidence['features']['scanSync']='false'
        with self.assertRaises(ValueError): validate(self.profile,self.evidence)
        self.evidence['features']['scanSync']=False
        self.evidence['features']['unknown']=True
        with self.assertRaises(ValueError): validate(self.profile,self.evidence)
if __name__ == '__main__': unittest.main()
