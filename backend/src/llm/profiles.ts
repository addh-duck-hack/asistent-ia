import type { AnalysisDepth } from "@asistent-ia/schema";
import { config } from "../config.js";

export type Effort = "low" | "medium" | "high" | "xhigh" | "max";

export interface AnalysisProfile {
  depth: AnalysisDepth;
  label: string;
  description: string;
  model: string;
  effort: Effort;
}

// Modelo y effort salen del .env para poder cambiarlos sin recompilar.
export function getProfile(depth: AnalysisDepth): AnalysisProfile {
  switch (depth) {
    case "quick":
      return {
        depth,
        label: "Rápido",
        description: "Dailies y chats: lo esencial",
        model: config.ANALYSIS_QUICK_MODEL,
        effort: config.ANALYSIS_QUICK_EFFORT,
      };
    case "standard":
      return {
        depth,
        label: "Normal",
        description: "1:1 y seguimientos",
        model: config.ANALYSIS_STANDARD_MODEL,
        effort: config.ANALYSIS_STANDARD_EFFORT,
      };
    case "deep":
      return {
        depth,
        label: "Profundo",
        description: "Sesiones con cliente y plannings",
        model: config.ANALYSIS_DEEP_MODEL,
        effort: config.ANALYSIS_DEEP_EFFORT,
      };
  }
}

export const ALL_DEPTHS: AnalysisDepth[] = ["quick", "standard", "deep"];
