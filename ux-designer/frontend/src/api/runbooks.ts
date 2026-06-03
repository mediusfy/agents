// API client for runbook MCP
import type { Runbook, RunbookBlock, ExecutionResult } from '../types/api';

const BASE_URL = '/api/v1/runbooks';

export async function fetchRunbooks(): Promise<Runbook[]> {
  const res = await fetch(BASE_URL);
  if (!res.ok) throw new Error(`Failed to fetch runbooks: ${res.statusText}`);
  return res.json();
}

export async function fetchRunbook(path: string): Promise<Runbook> {
  const res = await fetch(`${BASE_URL}/${encodeURIComponent(path)}`);
  if (!res.ok) throw new Error(`Failed to fetch runbook: ${res.statusText}`);
  return res.json();
}

export async function fetchRunbookBlock(runbookPath: string, blockId: string): Promise<RunbookBlock> {
  const res = await fetch(`${BASE_URL}/${encodeURIComponent(runbookPath)}/blocks/${blockId}`);
  if (!res.ok) throw new Error(`Failed to fetch block: ${res.statusText}`);
  return res.json();
}

export async function executeBlock(runbookPath: string, blockId: string): Promise<ExecutionResult> {
  const res = await fetch(`${BASE_URL}/${encodeURIComponent(runbookPath)}/blocks/${blockId}/execute`, {
    method: 'POST',
  });
  if (!res.ok) throw new Error(`Failed to execute block: ${res.statusText}`);
  return res.json();
}
