// API client for PR bridge
import type { PRRequest, PRResponse } from '../types/api';

const BASE_URL = '/api/v1/prs';

export async function createPR(req: PRRequest): Promise<PRResponse> {
  const res = await fetch(BASE_URL, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(req),
  });
  if (!res.ok) throw new Error(`Failed to create PR: ${res.statusText}`);
  return res.json();
}

export async function fetchPRStatus(repo: string, prNumber: number): Promise<string> {
  const res = await fetch(`${BASE_URL}/${encodeURIComponent(repo)}/${prNumber}`);
  if (!res.ok) throw new Error(`Failed to fetch PR status: ${res.statusText}`);
  const data = await res.json();
  return data.status;
}

export async function listPRs(repo: string): Promise<PRResponse[]> {
  const res = await fetch(`${BASE_URL}?repo=${encodeURIComponent(repo)}`);
  if (!res.ok) throw new Error(`Failed to list PRs: ${res.statusText}`);
  return res.json();
}
