# PaloAlly · 文件树 PRD

2026-10-16。把 Bento Term 的文件树（`~/code/bento-term/Modules/BentoFilePreviewKit`：FileTreeBrowserView、LazyDirectoryTreeStore、FileTreeSearch、PathDetection、DirectoryPickerView、FileFetch）移植过来，原则是不破坏 PaloAlly 的简单：文件树只在用得到的地方出现，没有新的一级入口。

## 入口（只有这三处）
1. **Pal 页的 ⋯ 菜单 →「文件」**
   - 打开这个 Pal 项目目录的文件树：iPhone 上是弹出页，Mac 和 iPad 上放在右侧面板，和「成果」同一个位置。
   - 点文件：用已经移植的 Bento 预览打开（Markdown 排版、代码高亮、图片，其他类型交给系统预览），可以分享。
   - 长按文件或文件夹：「插入到输入框」，把相对路径填进输入框。
   - 顶部可以搜文件名（FileTreeSearch）。
2. **对话里的文件路径可以点**
   - Palo 或 Pal 回复里出现的路径（PathDetection 识别，比如 `src/app.ts`、`~/code/x/README.md`）变成链接，点开就是预览。
   - 在 Pal 里，相对路径按它的项目目录解析；在 Palo 里，按它的工作目录和产出物目录解析。
   - 解析不到的路径保持普通文字。
3. **输入框「+」→「电脑上的文件」**
   - 用目录选择器（DirectoryPickerView）选电脑上的一个文件，把路径发给 Pal 或 Palo，不上传内容。
   - 在 Pal 里从它的项目目录开始浏览，在 Palo 里从它的工作目录开始。

4. **预览区「打开文件夹…」**（2026-10-16 加）
   - 在右侧预览区（Mac 和 iPad 是右侧面板，iPhone 是成果页）点「打开文件夹…」，在电脑上选一个文件夹或一个代码仓库，就在原地显示它的文件树，可以点开预览。
   - 选过的文件夹会记住，下次直接列在这里。
   - 只读；只开放主人选过的这些文件夹，`scope` 写作 `{kind: "folder", id}`；可以随时移除。

## 不做
- 全局「文件」标签页。
- Palo 对话里的文件树（Palo 的产出物在「成果」里）。
- 在 App 里编辑、移动、删除、新建文件。

## 安全
- 主机只开放「浏览」和「读」：
  - 每个 Pal 只能看它的项目目录；
  - Palo 只能看它的工作目录和产出物目录。
  - 路径先解析软链接再检查是否在允许的范围内，不允许 `..` 越界。
- 只有主人自己的设备能调用这些接口，Ally 和其他连接一律拒绝，每次读取都记审计。
- 默认隐藏 `.git`、`node_modules`、`.build`、`DerivedData` 等目录，可以手动展开。
- 单个文件最大 5 MB，超过的只给路径和大小，不读取内容。
- 读取不需要 macOS 授权（已经由 Pal 的启动方式和小助手解决）。被拒时如实提示。

## 接口（主机）
| 方法 | 参数 | 返回 |
|---|---|---|
| `files.list` | `{scope, path, showHidden?}` | `{entries: [{name, kind, size, mtime}]}` |
| `files.read` | `{scope, path, offset?, length?}` | 分块读取，沿用 `media.get` 的分块方式 |
| `files.search` | `{scope, query, limit?}` | `{matches: [{path, kind}]}` |
| `files.resolve` | `{scope, text}` | 把对话里的路径解析成可预览的文件 |

`scope` 取 `{kind: "pal", id}` 或 `{kind: "palo"}`。
