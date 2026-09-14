import type { ProgramDefinition, ResolvedBy, Source } from '../types.ts';

export const SCFHP_EAA_SOURCES: Source[] = [
  {
    id: 'scfhp-members',
    url: 'https://www.scfhp.com/healthcare-plans/medi-cal/programs/community-supports/',
    title: 'SCFHP member Community Supports page — EAA and access sections',
    reviewedOn: '2026-10-17', effectiveFrom: null, effectiveUntil: null,
  },
  {
    id: 'scfhp-providers',
    url: 'https://www.scfhp.com/for-providers/communitysupports-cs-healthhomes-hhp/',
    title: 'SCFHP provider Community Supports page — EAA and referral FAQs',
    reviewedOn: '2026-10-17', effectiveFrom: null, effectiveUntil: null,
  },
  {
    id: 'scfhp-guide-2026',
    url: 'https://res.cloudinary.com/dpmykpsih/image/upload/santa-clara-site-299/media/c633fdb6655e4c9eb679b8365b01afed/41559-community-support-provider-user-guide-final.pdf',
    title: 'SCFHP January 2026 Provider User Guide — EAA, printed pages 69–71',
    reviewedOn: '2026-10-17', effectiveFrom: null, effectiveUntil: null,
  },
  {
    id: 'scfhp-form-41567',
    url: 'https://res.cloudinary.com/dpmykpsih/image/upload/santa-clara-site-299/media/220648f9db4244ab883beee4ece8e702/41567-community-supports-referral-form-asthma-remediation-and-home-modifications-final.pdf',
    title: 'SCFHP referral form 41567 — EAA questions, consent and supporting records',
    reviewedOn: '2026-10-17', effectiveFrom: null, effectiveUntil: null,
  },
];

function review(id: string, label: string, reason: string, resolvedBy: ResolvedBy, sourceIds: string[]) {
  return { id, label, rule: { kind: 'manual_review' as const, reason, resolvedBy, sourceIds } };
}

export function createScfhpEaaResearchProgram(): ProgramDefinition {
  return {
    programId: 'scfhp-eaa',
    programName: 'SCFHP Environmental Accessibility Adaptations (research preview)',
    ruleVersion: 'research-2026-10-17-v1',
    isDemo: false, availability: 'unverified', rulesVerified: false,
    reviewedOn: '2026-10-17', effectiveFrom: null, effectiveUntil: null, recheckAfter: null,
    sources: structuredClone(SCFHP_EAA_SOURCES),
    criteria: [
      review('enrollment', 'Plan product and active enrollment',
        'Confirm the member’s current SCFHP product and enrollment. A typed plan name or county alone does not establish coverage.',
        'program', ['scfhp-members', 'scfhp-providers']),
      review('clinical-need', 'Clinical need and institutionalization risk',
        'A qualified professional must document the clinical need and relevant care setting. Home observations do not establish these determinations.',
        'professional', ['scfhp-guide-2026', 'scfhp-form-41567']),
      review('service-scope', 'Requested service and alternatives',
        'Have the plan review the requested adaptation, its purpose, other coverage and any applicable exceptions.',
        'program', ['scfhp-guide-2026']),
      review('assessment', 'Assessment and supporting evaluation',
        'Confirm which professional assessment and home evaluation apply to this request, including any permitted exception.',
        'professional', ['scfhp-guide-2026', 'scfhp-form-41567']),
      review('property-permission', 'Property acknowledgements',
        'For work on a home the member does not own, review the required signed property acknowledgements. Reported permission is not signed documentation; missing paperwork does not establish refusal.',
        'program', ['scfhp-form-41567']),
      review('cost-and-prior-use', 'Cost, prior use and exceptions',
        'Reconcile the guide’s lifetime limit with the form’s per-authorization wording, and review prior use and possible exceptions before deciding.',
        'program', ['scfhp-guide-2026', 'scfhp-form-41567']),
      review('consent', 'Consent to services and data sharing',
        'Obtain the member’s actual consent through the appropriate process. No answer is inferred from use of this app or reported owner permission.',
        'resident', ['scfhp-form-41567']),
    ],
    requiredDocuments: [
      'Professional request and supporting rationale; confirm the applicable author and contents.',
      'Relevant discharge, support-agency and equipment records, where applicable.',
      'Applicable evaluation reports and itemized estimates; confirm required scope and exceptions.',
      'Property acknowledgements where applicable, member consent and the referring person’s attestation.',
    ],
    intake: 'SCFHP publishes provider-portal and fax referral routes. Confirm the current instructions on its provider Community Supports page; this app does not submit referrals.',
  };
}
