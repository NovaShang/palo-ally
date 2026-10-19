import type { zhConfig } from "../zh/config.ts";

export const enConfig: Record<keyof typeof zhConfig, string> = {
  "config.noSetting": "No such setting: {key}",
  "config.badTimezone": "Unknown time zone: {tz} (for example Asia/Shanghai, America/Los_Angeles)",
  "config.badQuiet": "Quiet hours need a start and an end time, for example 23:00-08:00",
  "config.badRange": "{name} must be between {min} and {max}",
  "config.probeInterval": "Check interval (minutes)",
  "config.approvalTimeout": "Approval wait (minutes)",
  "config.foldDays": "Days before folding",
  "config.maxAwake": "Sessions awake at once",
  "config.badWechat": "WeChat proactive messages can only be off / hint / full",
  "config.nameText": "The name must be text",
  "config.nameLong": "The name can be at most 20 characters",
  "config.badColor": "No such color: {color}",
  "config.badLanguage": "Language must be zh or en",
};
