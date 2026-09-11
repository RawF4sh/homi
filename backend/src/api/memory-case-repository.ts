import type { CaseSnapshot, MatchResponse } from '../types.ts';
import type { MatchCaseRepository } from './match-case.ts';

export interface OwnedCase {
  userId: string;
  snapshot: CaseSnapshot;
}

export class MemoryCaseRepository implements MatchCaseRepository {
  private readonly cases = new Map<string, OwnedCase>();
  private readonly matches = new Map<string, MatchResponse>();

  constructor(cases: OwnedCase[]) {
    for (const entry of cases) {
      if (!entry.userId.trim() || this.cases.has(entry.snapshot.caseId)) {
        throw new Error('Seed cases require an owner and unique case IDs.');
      }
      this.cases.set(entry.snapshot.caseId, structuredClone(entry));
    }
  }

  async loadForUser(userId: string, caseId: string): Promise<CaseSnapshot | null> {
    const entry = this.cases.get(caseId);
    return entry?.userId === userId ? structuredClone(entry.snapshot) : null;
  }

  async saveMatchIfCurrent(
    userId: string,
    caseId: string,
    revision: number,
    response: MatchResponse,
  ): Promise<'saved' | 'not_found' | 'conflict'> {
    const entry = this.cases.get(caseId);
    if (!entry || entry.userId !== userId) return 'not_found';
    if (entry.snapshot.revision !== revision) return 'conflict';
    if (response.caseId !== caseId || response.caseRevision !== revision) {
      throw new Error('Result identity does not match the saved case.');
    }
    this.matches.set(caseId, structuredClone(response));
    return 'saved';
  }

  async readSavedMatchForUser(userId: string, caseId: string): Promise<MatchResponse | null> {
    const entry = this.cases.get(caseId);
    const result = this.matches.get(caseId);
    if (!entry || entry.userId !== userId || !result || result.caseRevision !== entry.snapshot.revision) return null;
    return structuredClone(result);
  }
}
