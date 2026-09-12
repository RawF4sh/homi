import { createServer, type IncomingMessage, type ServerResponse } from 'node:http';
import type { Socket } from 'node:net';
import { handleMatchCase, type MatchCaseDependencies, type ApiErrorCode } from './match-case.ts';
import { handlePreparePacket, type PreparePacketDependencies } from './prepare-packet.ts';

export const MAX_REQUEST_BYTES = 16 * 1024;

function sendJson(response: ServerResponse, status: number, body: unknown, headers: Record<string, string> = {}) {
  if (response.destroyed || response.writableEnded) return;
  response.writeHead(status, {
    'Content-Type': 'application/json; charset=utf-8',
    'Cache-Control': 'no-store',
    'X-Content-Type-Options': 'nosniff',
    ...headers,
  });
  response.end(JSON.stringify(body));
}

function fail(response: ServerResponse, status: number, code: ApiErrorCode | 'NOT_FOUND' | 'METHOD_NOT_ALLOWED' | 'PAYLOAD_TOO_LARGE' | 'UNSUPPORTED_MEDIA_TYPE', message: string, headers: Record<string, string> = {}) {
  sendJson(response, status, { schemaVersion: '1', error: { code, message } }, headers);
}

class BodyTooLarge extends Error {}

async function readJson(request: IncomingMessage): Promise<unknown> {
  const chunks: Buffer[] = [];
  let size = 0;
  for await (const part of request.iterator({ destroyOnReturn: false })) {
    const bytes = Buffer.isBuffer(part) ? part : Buffer.from(part);
    size += bytes.length;
    if (size > MAX_REQUEST_BYTES) throw new BodyTooLarge();
    chunks.push(bytes);
  }
  return JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(Buffer.concat(chunks)));
}

export function createMatchingServer(dependencies: MatchCaseDependencies, packetDependencies?: PreparePacketDependencies) {
  const server = createServer({ maxHeaderSize: 8192 }, (request, response) => {
    void route(request, response, dependencies, packetDependencies).catch(() => {
      fail(response, 500, 'INTERNAL_ERROR', 'The request could not be completed.');
    });
  });
  server.requestTimeout = 15_000;
  server.headersTimeout = 10_000;
  server.keepAliveTimeout = 5_000;
  server.setTimeout(20_000);
  server.on('timeout', (socket: Socket) => socket.destroy());
  return server;
}

async function route(request: IncomingMessage, response: ServerResponse, dependencies: MatchCaseDependencies, packetDependencies?: PreparePacketDependencies) {
  const isPacketRequest = request.url === '/v1/prepare-packet' && packetDependencies !== undefined;
  if (request.url !== '/v1/match-case' && !isPacketRequest) {
    fail(response, 404, 'NOT_FOUND', 'This endpoint does not exist.');
    request.resume();
    return;
  }
  if (request.method !== 'POST') {
    fail(response, 405, 'METHOD_NOT_ALLOWED', 'Use POST for this endpoint.', { Allow: 'POST' });
    request.resume();
    return;
  }
  const authorizationCount = request.rawHeaders.filter((_, index) => index % 2 === 0 && request.rawHeaders[index].toLowerCase() === 'authorization').length;
  const authorization = request.headers.authorization;
  const bearer = typeof authorization === 'string' && /^Bearer ([A-Za-z0-9._~+\/-]+=*)$/i.exec(authorization);
  if (authorizationCount !== 1 || !bearer || bearer[1].length > 4096) {
    fail(response, 401, 'UNAUTHENTICATED', 'Sign in to make this request.', { 'WWW-Authenticate': 'Bearer' });
    request.resume();
    return;
  }
  if (request.headers['content-encoding'] && request.headers['content-encoding'] !== 'identity') {
    fail(response, 415, 'UNSUPPORTED_MEDIA_TYPE', 'Send uncompressed JSON.');
    request.resume();
    return;
  }
  if (!/^application\/json(?:\s*;\s*charset=utf-8)?$/i.test(request.headers['content-type'] ?? '')) {
    fail(response, 415, 'UNSUPPORTED_MEDIA_TYPE', 'Send application/json with UTF-8 encoding.');
    request.resume();
    return;
  }
  let body: unknown;
  try {
    body = await readJson(request);
  } catch (error) {
    if (error instanceof BodyTooLarge) {
      fail(response, 413, 'PAYLOAD_TOO_LARGE', 'The request is too large.', { Connection: 'close' });
      request.resume();
    } else {
      fail(response, 400, 'INVALID_REQUEST', 'Send a valid JSON request.');
    }
    return;
  }
  const input = { body, bearerToken: bearer[1] };
  const result = isPacketRequest
    ? await handlePreparePacket(input, packetDependencies!)
    : await handleMatchCase(input, dependencies);
  sendJson(response, result.status, result.body, result.headers);
}
