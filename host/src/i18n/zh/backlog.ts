// 待办 (backlog.ts): the file's own words, the tools' replies, and the one line the agents are told.
export const zhBacklog = {
  "backlog.prompt":
    "主人说「放进待办」「记一下以后做」这类话时，用 mcp__paloally__backlog_add 记进待办（text 一句话说清要做什么，细节放 note），然后告诉主人记在第几件，不要现在就去做。待办归这个文件夹，同一文件夹里的 agent 共用；backlog_list 看这份待办，做完其中一件就用 backlog_done 标完成。",
  "backlog.file.title": "待办 · {name}",
  "backlog.file.hint": "Palo 的待办：一行一件，越靠上越先做；[>] 正在做，[x] 做完了。可以直接改，末尾的注释别删。",
  "backlog.err.none": "待办里没有这件",
  "backlog.err.empty": "要写点内容",
  "backlog.err.pal": "没有这个 agent",
  "backlog.err.blocking": "这件卡着一个 agent，要现在回答",
  "backlog.line.doing": "正在做 {who}",
  "backlog.line.done": "做完了",
  "backlog.tool.added": "已记进待办，排第 {n} 件（id: {id}，{folder} 的待办）。告诉主人记好了，不用现在做。",
  "backlog.tool.none": "{folder} 的待办是空的。",
  "backlog.tool.list": "{folder} 的待办（正在做的在前，然后按先后排队，做完的在最后）：\n{lines}",
  "backlog.tool.done": "已标完成：「{text}」。还有 {n} 件排队。",
  "backlog.tool.undone": "已放回排队：「{text}」。",
  "backlog.quote.note": "（主人引用的是待办里的 {id}「{text}」。做完了用 backlog_done 标完成。）",
  "backlog.later": "放进待办了",
};
