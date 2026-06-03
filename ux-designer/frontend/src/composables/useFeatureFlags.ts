import type { Ref } from 'vue';
import { ref } from 'vue';

export interface FeatureFlags {
  gitopsPrs: Ref<boolean>;
  finopsROI: Ref<boolean>;
  agentAutonomy: Ref<boolean>;
  executableRunbooks: Ref<boolean>;
  lightMode: Ref<boolean>;
}

/**
 * Feature flag composable for gradual rollout of strategy themes.
 * Toggle via data-feature attributes or local config.
 */
export function useFeatureFlags(): FeatureFlags {
  const flags: FeatureFlags = {
    gitopsPrs: ref(true),
    finopsROI: ref(true),
    agentAutonomy: ref(true),
    executableRunbooks: ref(true),
    lightMode: ref(false),
  };

  // Check for query param overrides: ?feature=gitopsPrs,agentAutonomy
  if (typeof window !== 'undefined') {
    const params = new URLSearchParams(window.location.search);
    const featureParam = params.get('feature');
    if (featureParam) {
      const enabled = featureParam.split(',');
      for (const key of Object.keys(flags) as Array<keyof FeatureFlags>) {
        (flags[key] as Ref<boolean>).value = enabled.includes(key);
      }
    }
  }

  return flags;
}
