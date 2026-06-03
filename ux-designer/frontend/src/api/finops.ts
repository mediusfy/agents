// API client for FinOps waste analysis endpoints
import type { WasteObservation, CostSavingAction } from '../types/api';

const BASE_URL = '/api/v1/waste';

export async function fetchTopWaste(limit: number = 10): Promise<WasteObservation[]> {
  const res = await fetch(`${BASE_URL}/top?limit=${limit}`);
  if (!res.ok) throw new Error(`Failed to fetch top waste: ${res.statusText}`);
  return res.json();
}

export async function fetchWasteObservations(filters?: {
  cluster?: string;
  namespace?: string;
  status?: string;
}): Promise<WasteObservation[]> {
  const params = new URLSearchParams();
  if (filters?.cluster) params.set('cluster', filters.cluster);
  if (filters?.namespace) params.set('namespace', filters.namespace);
  if (filters?.status) params.set('status', filters.status);

  const url = `${BASE_URL}?${params.toString()}`;
  const res = await fetch(url);
  if (!res.ok) throw new Error(`Failed to fetch waste observations: ${res.statusText}`);
  return res.json();
}

export async function generateRecommendation(observationId: string): Promise<CostSavingAction> {
  const res = await fetch(`${BASE_URL}/${observationId}/recommend`, {
    method: 'POST',
  });
  if (!res.ok) throw new Error(`Failed to generate recommendation: ${res.statusText}`);
  return res.json();
}

export async function dismissObservation(observationId: string, reason?: string): Promise<void> {
  const res = await fetch(`${BASE_URL}/${observationId}/dismiss`, {
    method: 'PATCH',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ reason }),
  });
  if (!res.ok) throw new Error(`Failed to dismiss observation: ${res.statusText}`);
}
