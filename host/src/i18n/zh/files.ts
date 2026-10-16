// Files on the computer (docs/files-prd.md): what the app shows when it can't open one.
export const zhFiles = {
  "files.err.owner": "只有主人自己的设备能看电脑上的文件",
  "files.err.noScope": "没有这个文件夹",
  "files.err.rootGone": "这个文件夹在电脑上找不到了",
  "files.err.notFound": "找不到这个文件，或者它不在能看的范围里",
  "files.err.notDir": "这不是文件夹",
  "files.err.isDir": "这是文件夹，不是文件",
  "files.err.cantRead": "电脑上没有权限读这里",
  "files.err.folderNotAllowed": "选一个具体的文件夹，不能是整个磁盘、整个个人文件夹或 PaloAlly 自己的文件夹",
  "files.err.tooManyFolders": "最多记住 {max} 个文件夹，先移除一些",
} as const;
