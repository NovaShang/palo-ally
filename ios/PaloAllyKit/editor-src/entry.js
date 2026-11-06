// The file editor's page script: CodeMirror 6 with editing, syntax colours
// and search only (no completion, no diagnostics). The app talks to it
// through the window.paEditor* functions below and hears back on the
// `paEditor` message handler: {type:"ready"}, {type:"dirty", dirty},
// {type:"save"} (⌘S typed in the page), {type:"toggle"} (⌘E).
import { Compartment, EditorState, Prec } from "@codemirror/state";
import {
  EditorView, keymap, lineNumbers, highlightActiveLine, highlightActiveLineGutter, drawSelection,
  highlightSpecialChars, dropCursor, rectangularSelection, crosshairCursor,
} from "@codemirror/view";
import { defaultKeymap, history, historyKeymap, indentWithTab } from "@codemirror/commands";
import {
  syntaxHighlighting, HighlightStyle, indentOnInput, bracketMatching, StreamLanguage, LanguageDescription, LanguageSupport, indentUnit,
} from "@codemirror/language";
import { search, searchKeymap, highlightSelectionMatches, openSearchPanel } from "@codemirror/search";
import { tags as t } from "@lezer/highlight";
import { markdown, markdownLanguage } from "@codemirror/lang-markdown";
import { javascript } from "@codemirror/lang-javascript";
import { json } from "@codemirror/lang-json";
import { css } from "@codemirror/lang-css";
import { html } from "@codemirror/lang-html";
import { swift } from "@codemirror/legacy-modes/mode/swift";
import { shell } from "@codemirror/legacy-modes/mode/shell";
import { toml } from "@codemirror/legacy-modes/mode/toml";
import { go } from "@codemirror/legacy-modes/mode/go";
import { rust } from "@codemirror/legacy-modes/mode/rust";
import { python } from "@codemirror/legacy-modes/mode/python";
import { yaml } from "@codemirror/legacy-modes/mode/yaml";
import { diff } from "@codemirror/legacy-modes/mode/diff";

// A support, not a bare language: a Markdown fence's language must be one.
const legacy = (mode) => () => new LanguageSupport(StreamLanguage.define(mode));

// By extension; a name's language, and a fenced block's in Markdown.
const languages = [
  { names: ["js", "mjs", "cjs", "javascript"], make: () => javascript() },
  { names: ["jsx"], make: () => javascript({ jsx: true }) },
  { names: ["ts", "mts", "cts", "typescript"], make: () => javascript({ typescript: true }) },
  { names: ["tsx"], make: () => javascript({ typescript: true, jsx: true }) },
  { names: ["json", "jsonc", "json5"], make: () => json() },
  { names: ["py", "python"], make: legacy(python) },
  { names: ["css", "scss", "less"], make: () => css() },
  { names: ["html", "htm", "xhtml", "vue", "svelte"], make: () => html() },
  { names: ["yaml", "yml"], make: legacy(yaml) },
  { names: ["swift"], make: legacy(swift) },
  { names: ["sh", "bash", "zsh", "shell", "fish", "command"], make: legacy(shell) },
  { names: ["toml"], make: legacy(toml) },
  { names: ["go"], make: legacy(go) },
  { names: ["rs", "rust"], make: legacy(rust) },
  { names: ["diff", "patch"], make: legacy(diff) },
];

const codeLanguages = languages.map((l) =>
  LanguageDescription.of({ name: l.names[0], alias: l.names.slice(1), load: async () => l.make() }),
);

function languageFor(name) {
  const lower = (name || "").toLowerCase();
  const ext = lower.includes(".") ? lower.split(".").pop() : lower;
  if (["md", "markdown", "mdx", "mdown", "mkd"].includes(ext)) {
    return { support: markdown({ base: markdownLanguage, codeLanguages }), code: false };
  }
  const hit = languages.find((l) => l.names.includes(ext));
  if (hit) return { support: hit.make(), code: true };
  if (["makefile", "dockerfile"].includes(lower)) return { support: legacy(shell)(), code: true };
  return { support: [], code: false };
}

// GitHub's colours (as the preview's), through variables so a theme change is a class flip.
const highlight = HighlightStyle.define([
  { tag: [t.keyword, t.modifier, t.operatorKeyword, t.controlKeyword, t.definitionKeyword, t.moduleKeyword], color: "var(--hl-keyword)" },
  { tag: [t.function(t.variableName), t.function(t.propertyName), t.className, t.typeName, t.namespace], color: "var(--hl-title)" },
  { tag: [t.number, t.bool, t.null, t.atom, t.attributeName, t.propertyName, t.constant(t.variableName), t.self], color: "var(--hl-constant)" },
  { tag: [t.string, t.special(t.string), t.regexp, t.character, t.attributeValue], color: "var(--hl-string)" },
  { tag: [t.comment, t.lineComment, t.blockComment, t.docComment, t.meta], color: "var(--hl-comment)" },
  { tag: [t.tagName, t.quote], color: "var(--hl-tag)" },
  { tag: [t.heading], color: "var(--hl-heading)", fontWeight: "600" },
  { tag: [t.list], color: "var(--hl-bullet)" },
  { tag: [t.emphasis], fontStyle: "italic" },
  { tag: [t.strong], fontWeight: "600" },
  { tag: [t.strikethrough], textDecoration: "line-through" },
  { tag: [t.link, t.url], color: "var(--hl-link)" },
  { tag: [t.monospace], color: "var(--hl-code)" },
  { tag: [t.processingInstruction, t.contentSeparator], color: "var(--hl-comment)" },
  { tag: [t.inserted], color: "var(--hl-tag)" },
  { tag: [t.deleted], color: "var(--hl-deleted)" },
  { tag: [t.invalid], color: "var(--hl-deleted)" },
]);

const chrome = EditorView.theme({
  "&": { height: "100%", backgroundColor: "var(--bg)", color: "var(--fg)" },
  "&.cm-focused": { outline: "none" },
  ".cm-scroller": { fontFamily: 'ui-monospace, "SF Mono", SFMono-Regular, Menlo, "PingFang SC", monospace', fontSize: "13px", lineHeight: "20px" },
  ".cm-content": { padding: "14px 0 40vh", caretColor: "var(--caret)" },
  ".cm-line": { padding: "0 20px 0 16px" },
  ".cm-gutters": { backgroundColor: "var(--bg)", color: "var(--gutter)", border: "none", paddingLeft: "6px" },
  ".cm-activeLine": { backgroundColor: "var(--active-line)" },
  ".cm-activeLineGutter": { backgroundColor: "transparent", color: "var(--fg)" },
  ".cm-cursor, .cm-dropCursor": { borderLeftColor: "var(--caret)", borderLeftWidth: "2px" },
  "&.cm-focused > .cm-scroller > .cm-selectionLayer .cm-selectionBackground, .cm-selectionBackground, ::selection": { backgroundColor: "var(--selection) !important" },
  ".cm-selectionMatch": { backgroundColor: "var(--match)" },
  ".cm-searchMatch": { backgroundColor: "var(--match)", outline: "1px solid var(--match-edge)" },
  ".cm-searchMatch.cm-searchMatch-selected": { backgroundColor: "var(--match-strong)" },
  ".cm-matchingBracket": { backgroundColor: "var(--match)", outline: "none" },
  ".cm-panels": { backgroundColor: "var(--panel)", color: "var(--fg)" },
  ".cm-panels.cm-panels-top": { borderBottom: "1px solid var(--border)" },
  ".cm-panels.cm-panels-bottom": { borderTop: "1px solid var(--border)" },
  ".cm-search": { padding: "8px 12px", fontFamily: '-apple-system, "PingFang SC", sans-serif', fontSize: "12px" },
  ".cm-search input, .cm-search button": { fontFamily: "inherit", fontSize: "12px" },
  ".cm-textfield": { border: "1px solid var(--border)", borderRadius: "6px", padding: "3px 6px", background: "var(--bg)", color: "var(--fg)" },
  ".cm-button": { backgroundImage: "none", background: "var(--bg)", border: "1px solid var(--border)", borderRadius: "6px", padding: "3px 8px", color: "var(--fg)" },
  ".cm-panel.cm-search [name=close]": { color: "var(--muted)", fontSize: "16px", right: "8px" },
});

// The search panel in the app's language.
const zhPhrases = {
  "Find": "查找", "Replace": "替换", "next": "下一个", "previous": "上一个", "all": "全部", "match case": "区分大小写",
  "regexp": "正则", "by word": "整词", "replace": "替换", "replace all": "全部替换", "close": "关闭",
  "Go to line": "跳到行", "go": "前往", "current match": "当前匹配", "on line": "行", "replaced match on line $": "已替换第 $ 行的匹配",
  "replaced $ matches": "已替换 $ 处", "Selection deleted": "已删除所选", "Folded lines": "折叠的行", "Unfolded lines": "展开的行",
  "to": "到", "Control character": "控制字符",
};

const post = (msg) => {
  try {
    window.webkit.messageHandlers.paEditor.postMessage(msg);
  } catch {
    // outside the app (a browser, for a look): nowhere to say it
  }
};

const languageSlot = new Compartment();
const gutterSlot = new Compartment();
const phrasesSlot = new Compartment();
let view = null;
let saved = null; // the doc as it is on the computer
let lastDirty = false;
let snapshots = new Map();
let snapshotSeq = 0;

function reportDirty() {
  const dirty = !!view && !!saved && !view.state.doc.eq(saved);
  if (dirty !== lastDirty) {
    lastDirty = dirty;
    post({ type: "dirty", dirty });
  }
}

function extensions(name, zh, crlf) {
  const lang = languageFor(name);
  return [
    // A Windows file stays one: its lines joined back with CRLF on save.
    crlf ? EditorState.lineSeparator.of("\r\n") : [],
    phrasesSlot.of(zh ? EditorState.phrases.of(zhPhrases) : []),
    gutterSlot.of(lang.code ? [lineNumbers(), highlightActiveLineGutter()] : []),
    highlightSpecialChars(),
    history(),
    drawSelection(),
    dropCursor(),
    EditorState.allowMultipleSelections.of(true),
    indentOnInput(),
    indentUnit.of("  "),
    bracketMatching(),
    rectangularSelection(),
    crosshairCursor(),
    highlightActiveLine(),
    highlightSelectionMatches(),
    search({ top: true }),
    syntaxHighlighting(highlight),
    EditorView.lineWrapping,
    languageSlot.of(lang.support),
    chrome,
    Prec.highest(keymap.of([
      { key: "Mod-s", run: () => (post({ type: "save" }), true), preventDefault: true },
      { key: "Mod-e", run: () => (post({ type: "toggle" }), true), preventDefault: true },
    ])),
    keymap.of([...defaultKeymap, ...historyKeymap, ...searchKeymap, indentWithTab]),
    EditorView.updateListener.of((u) => {
      if (u.docChanged) reportDirty();
    }),
  ];
}

/** A file, fresh: its text as saved, its language from its name, at the top. */
window.paEditorLoad = (p) => {
  document.documentElement.dataset.theme = p.dark ? "dark" : "light";
  const state = EditorState.create({ doc: p.text, extensions: extensions(p.name, p.zh, p.text.includes("\r\n")) });
  saved = state.doc;
  snapshots = new Map();
  lastDirty = false;
  if (view) {
    view.setState(state);
  } else {
    view = new EditorView({ state, parent: document.getElementById("root") });
  }
  view.scrollDOM.scrollTop = 0;
  if (p.focus) view.focus();
  return true;
};

/**
 * The file as it is on the computer now, in place of what's shown, changed
 * only where it differs (the cursor and the scroll stay where they were,
 * mapped through the change). It is the saved copy from then on.
 */
window.paEditorReplace = (text) => {
  if (!view) return false;
  // Compared line break for line break (a CRLF file's doc counts each as one).
  const br = view.state.lineBreak;
  const old = view.state.doc.toString();
  const now = br === "\n" ? text : text.split(br).join("\n");
  if (old !== now) {
    let from = 0;
    const max = Math.min(old.length, now.length);
    while (from < max && old.charCodeAt(from) === now.charCodeAt(from)) from++;
    let endOld = old.length;
    let endNew = now.length;
    while (endOld > from && endNew > from && old.charCodeAt(endOld - 1) === now.charCodeAt(endNew - 1)) {
      endOld--;
      endNew--;
    }
    const top = view.scrollDOM.scrollTop;
    view.dispatch({ changes: { from, to: endOld, insert: now.slice(from, endNew).split("\n").join(br) } });
    view.scrollDOM.scrollTop = top;
  }
  saved = view.state.doc;
  reportDirty();
  return true;
};

/** What to save: the text now, and a mark to say it was saved by (`paEditorSaved`). */
window.paEditorSnapshot = () => {
  if (!view) return null;
  const id = ++snapshotSeq;
  snapshots.set(id, view.state.doc);
  return { id, text: view.state.sliceDoc() };
};

/** Saved: the text of that snapshot is what the computer has now (typed since stays unsaved). */
window.paEditorSaved = (id) => {
  const doc = snapshots.get(id);
  if (!doc) return false;
  snapshots.clear();
  saved = doc;
  reportDirty();
  return true;
};

window.paEditorTheme = (dark) => {
  document.documentElement.dataset.theme = dark ? "dark" : "light";
  return true;
};

window.paEditorFind = () => {
  if (view) openSearchPanel(view);
  return true;
};

/** Text typed at the cursor (the app's demo steps). */
window.paEditorInsert = (text) => {
  if (!view) return false;
  view.dispatch(view.state.replaceSelection(text), { userEvent: "input.type", scrollIntoView: true });
  return true;
};

window.paEditorFocus = () => {
  view?.focus();
  return true;
};

post({ type: "ready" });
