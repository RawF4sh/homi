import { instantMicros, isPacketCurrent } from '../packets.ts';
import type { CaseSnapshot, DraftPacket, MatchResponse } from '../types.ts';
import type { MatchCaseRepository } from './match-case.ts';
import type { CreatePacketInput, CreatePacketResult, PacketCaseRepository } from './prepare-packet.ts';

export interface OwnedCase {
  userId: string;
  snapshot: CaseSnapshot;
}

export class MemoryCaseRepository implements MatchCaseRepository, PacketCaseRepository {
  private readonly cases = new Map<string, OwnedCase>();
  private readonly matches = new Map<string, MatchResponse>();
  private readonly packets = new Map<string, { contextFingerprint: string; packet: DraftPacket }>();
  private readonly packetIds = new Set<string>();

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

  async createPacketIfCurrent(input: CreatePacketInput): Promise<CreatePacketResult> {
    const entry = this.cases.get(input.caseId);
    if (!entry || entry.userId !== input.userId) return { status: 'not_found' };
    if (entry.snapshot.revision !== input.revision) return { status: 'conflict' };
    if (input.packet.caseId !== input.caseId || input.packet.caseRevision !== input.revision) {
      throw new Error('Packet identity does not match the current case.');
    }
    const key = JSON.stringify([input.userId, input.caseId, input.generationKey]);
    const existing = this.packets.get(key);
    if (existing) {
      if (existing.contextFingerprint !== input.contextFingerprint || !isPacketCurrent(existing.packet, input.checkedAt)) {
        return { status: 'generation_conflict' };
      }
      return { status: 'reused', packet: structuredClone(existing.packet) };
    }
    if (instantMicros(input.packet.generatedAt) > instantMicros(input.checkedAt)) throw new Error('Packet time is in the future.');
    if (input.packet.recheckAfter !== null && !isPacketCurrent(input.packet, input.checkedAt)) {
      return { status: 'generation_conflict' };
    }
    if (this.packetIds.has(input.packet.packetId)) throw new Error('Packet IDs must be unique.');
    this.packets.set(key, { contextFingerprint: input.contextFingerprint, packet: structuredClone(input.packet) });
    this.packetIds.add(input.packet.packetId);
    return { status: 'saved', packet: structuredClone(input.packet) };
  }
}
