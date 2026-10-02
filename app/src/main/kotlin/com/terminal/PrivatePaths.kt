package com.terminal

/** Keep runtime paths identical to the NDK prefix, without resolving Android's aliases. */
object PrivatePaths {
    const val PACKAGE_NAME = "com.terminal"
    const val FILES = "/data/data/com.terminal/files"
    const val HOME = "$FILES/home"
    const val PREFIX = "$FILES/usr"

    // Match this app's old primary-user path only, including file: URIs and quoted values.
    // Do not rewrite other apps, other Android users or a directory named files-backup.
    private val legacyFiles = Regex(
        """/data/user/0/com\.terminal/files(?=/|$|[\s"':;=])""",
    )

    fun migrateLegacyPaths(contents: String): String = legacyFiles.replace(contents, FILES)
}
