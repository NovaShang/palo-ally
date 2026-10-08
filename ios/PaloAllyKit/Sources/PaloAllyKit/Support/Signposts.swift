import os

/// Signposts for Instruments (Points of Interest / os_signpost): the chat's
/// streaming and scrolling, so a hitch can be lined up with what the app was
/// doing. States and sizes only, never message text.
public enum ChatSignposts {
    public static let chat = OSSignposter(subsystem: "com.novashang.paloally", category: "chat")
}
