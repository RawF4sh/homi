import type { AuthenticatedUser } from './match-case.ts';
import { AccountClosedError } from '../lifecycle/types.ts';
import { evidenceIdentifier } from '../evidence/validation.ts';
import { parseHomeSafetyRequest, parseHomeSafetyState, safetyRequestHash, type HomeSafetyRepository, type HomeSafetySave } from '../assessment/home-safety.ts';

export interface HomeSafetyDependencies { authenticate(token: string): Promise<AuthenticatedUser | null>; cases: HomeSafetyRepository; now(): Date }
export type HomeSafetyRoute = 'read-home-safety' | 'save-home-safety';
const errors = {
  not_found: [404, 'CASE_NOT_FOUND'], conflict: [409, 'CASE_REVISION_MISMATCH'], safety_conflict: [409, 'HOME_SAFETY_CONFLICT'],
  mutation_conflict: [409, 'HOME_SAFETY_MUTATION_CONFLICT'], history_limit: [507, 'HOME_SAFETY_HISTORY_LIMIT'], invalid_operation: [400, 'INVALID_REQUEST'],
} as const;
export async function handleHomeSafety(input: { body: unknown; bearerToken: string | null }, deps: HomeSafetyDependencies, route: HomeSafetyRoute) {
  const fail = (status: number, code: string) => ({ status, body: { schemaVersion: '3', error: { code,
    message: 'Open the current rooms and checklist, then review your changes before saving.' } }, headers: { 'Cache-Control': 'no-store' } });
  try {
    const token = input.bearerToken;
    if (!token || token.length > 4096 || !/^[A-Za-z0-9._~+\/-]+=*$/.test(token)) return fail(401, 'UNAUTHENTICATED');
    let request;
    try { request = parseHomeSafetyRequest(input.body, route === 'save-home-safety'); } catch { request = null; }
    const user = await deps.authenticate(token);
    if (user === null) return fail(401, 'UNAUTHENTICATED');
    if (!user || !evidenceIdentifier(user.userId)) return fail(500, 'INTERNAL_ERROR');
    if (request === null) return fail(400, 'INVALID_REQUEST');
    const result = route === 'read-home-safety' ? await deps.cases.readHomeSafetyForUser(user.userId, request.caseId)
      : await deps.cases.saveHomeSafetyForUser(user.userId, request as HomeSafetySave, deps.now().toISOString());
    if (result.status === 'found') {
      try {
        const state = parseHomeSafetyState(result.state);
        if (state.case.caseId !== request.caseId) return fail(500, 'INTERNAL_ERROR');
        if (route === 'save-home-safety') {
          const saved = request as HomeSafetySave;
          if (state.acknowledgedMutationId !== saved.mutationId || !state.safety.history.some(e => e.mutationId === saved.mutationId
            && e.requestHash === safetyRequestHash(saved))) return fail(500, 'INTERNAL_ERROR');
        } else if (state.acknowledgedMutationId !== null) return fail(500, 'INTERNAL_ERROR');
        return { status: 200, body: state, headers: { 'Cache-Control': 'no-store' } };
      } catch { return fail(500, 'INTERNAL_ERROR'); }
    }
    const [status, code] = errors[result.status]; return fail(status, code);
  } catch (error) { return fail(error instanceof AccountClosedError ? 409 : 503, error instanceof AccountClosedError ? 'ACCOUNT_CLOSED' : 'SERVICE_UNAVAILABLE'); }
}
