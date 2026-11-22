import type { zh } from "../zh/index.ts";
import { enAllies } from "./allies.ts";
import { enCli } from "./cli.ts";
import { enConfig } from "./config.ts";
import { enCopy } from "./copy.ts";
import { enFiles } from "./files.ts";
import { enHub } from "./hub.ts";
import { enPals } from "./pals.ts";
import { enPending } from "./pending.ts";
import { enBacklog } from "./backlog.ts";

export const en: Record<keyof typeof zh, string> = { ...enCopy, ...enConfig, ...enHub, ...enAllies, ...enPals, ...enCli, ...enFiles, ...enPending, ...enBacklog };
