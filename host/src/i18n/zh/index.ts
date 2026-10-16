import { zhAllies } from "./allies.ts";
import { zhCli } from "./cli.ts";
import { zhConfig } from "./config.ts";
import { zhCopy } from "./copy.ts";
import { zhHub } from "./hub.ts";
import { zhPals } from "./pals.ts";

// One dictionary per area, merged here. Keys are prefixed by area, so areas
// never collide. en/index.ts must provide every key (typed).
export const zh = { ...zhCopy, ...zhConfig, ...zhHub, ...zhAllies, ...zhPals, ...zhCli };
