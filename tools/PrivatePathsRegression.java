package com.terminal;

/** Checks migration of existing private configs without changing unrelated paths. */
public final class PrivatePathsRegression {
    private static void expect(String original, String expected) {
        String actual = PrivatePaths.INSTANCE.migrateLegacyPaths(original);
        if (!actual.equals(expected)) {
            throw new AssertionError("unexpected config migration: " + actual);
        }
        if (!PrivatePaths.INSTANCE.migrateLegacyPaths(actual).equals(actual)) {
            throw new AssertionError("migration must be idempotent");
        }
    }

    public static void main(String[] args) {
        String old = "/data/user/0/com.terminal/files";
        String root = "/data/data/com.terminal/files";
        expect("export HOME=" + old + "/home\nexport USR=" + old + "/usr\n# custom setting\n",
               "export HOME=" + root + "/home\nexport USR=" + root + "/usr\n# custom setting\n");
        expect("deb [signed-by=" + old + "/usr/etc/apt/keyrings/local.gpg] http://192.168.31.23:8080 stable main\n",
               "deb [signed-by=" + root + "/usr/etc/apt/keyrings/local.gpg] http://192.168.31.23:8080 stable main\n");
        expect("URIs: file:" + old + "/usr/var/tmp/repository\nSigned-By: " + old + "/usr/etc/apt/keyrings/local.gpg\n",
               "URIs: file:" + root + "/usr/var/tmp/repository\nSigned-By: " + root + "/usr/etc/apt/keyrings/local.gpg\n");
        expect("Dir \"" + old + "/usr\";\nDPkg::Options { \"--root=" + old + "/usr\"; };\n",
               "Dir \"" + root + "/usr\";\nDPkg::Options { \"--root=" + root + "/usr\"; };\n");
        expect(old + ":'" + old + "'\n", root + ":'" + root + "'\n");
        for (String other : new String[]{
                "/data/user/10/com.terminal/files/usr",
                "/data/user/0/com.other/files/usr",
                old + "-backup/usr",
                root + "/usr",
                "Acquire::Retries \"3\";\n"}) {
            expect(other, other);
        }
        System.out.println("private paths: profile, apt/dpkg configs and signed-by migration passed");
    }
}
