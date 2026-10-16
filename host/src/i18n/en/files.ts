import type { zhFiles } from "../zh/files.ts";

export const enFiles: Record<keyof typeof zhFiles, string> = {
  "files.err.owner": "Only the owner's own devices can look at files on the computer",
  "files.err.noScope": "No such folder",
  "files.err.rootGone": "This folder isn't on the computer any more",
  "files.err.notFound": "This file isn't there, or it's outside what can be opened",
  "files.err.notDir": "This isn't a folder",
  "files.err.isDir": "This is a folder, not a file",
  "files.err.cantRead": "The computer doesn't allow reading here",
  "files.err.folderNotAllowed": "Pick a specific folder, not the whole disk, your whole home folder or PaloAlly's own folder",
  "files.err.tooManyFolders": "At most {max} folders are remembered; remove some first",
};
