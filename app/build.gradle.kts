import org.gradle.api.DefaultTask
import org.gradle.api.file.ConfigurableFileCollection
import org.gradle.api.file.DirectoryProperty
import org.gradle.api.tasks.InputFiles
import org.gradle.api.tasks.Internal
import org.gradle.api.tasks.OutputDirectory
import org.gradle.api.tasks.PathSensitive
import org.gradle.api.tasks.PathSensitivity
import org.gradle.api.tasks.TaskAction
import java.io.File
import java.nio.file.Files
import java.nio.file.LinkOption
import java.nio.file.Path
import java.nio.file.StandardCopyOption
import java.security.MessageDigest
import java.util.Comparator

plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.android)
}

/** Copies the extension prefix into APK assets without Android JNI-library handling. */
abstract class PackagePrefixAssetsTask : DefaultTask() {
    @get:InputFiles
    @get:PathSensitive(PathSensitivity.RELATIVE)
    abstract val sourceFiles: ConfigurableFileCollection

    @get:Internal
    abstract val sourceRoot: DirectoryProperty

    @get:OutputDirectory
    abstract val outputRoot: DirectoryProperty

    @TaskAction
    fun packagePrefix() {
        val output = outputRoot.get().asFile
        output.deleteRecursively()
        output.mkdirs()

        val source = sourceRoot.get().asFile
        var packaged = 0
        ABI_NAMES.forEach { abi ->
            val finalRoot = source.resolve("$abi/final")
            if (!finalRoot.isDirectory) {
                logger.lifecycle("packagePrefixAssets: no staged prefix for $abi")
                return@forEach
            }

            val target = output.resolve("prefix/$abi")
            copyTree(finalRoot.toPath(), target.toPath())
            writeManifest(target.toPath())
            val version = digestTree(target.toPath())
            target.resolve(VERSION_FILE).writeText("$version\n", Charsets.UTF_8)
            packaged++
            logger.lifecycle("packagePrefixAssets: packaged $abi with original file names")
        }

        if (packaged == 0) {
            logger.lifecycle("packagePrefixAssets: no extension output; dash-only APK assets remain active")
        }
    }

    private fun copyTree(source: Path, target: Path) {
        val paths = mutableListOf<Path>()
        Files.walk(source).use { stream -> stream.forEach(paths::add) }
        paths.sortWith(Comparator.comparing { it.toString() })

        paths.forEach { path ->
            val relative = source.relativize(path)
            val destination = target.resolve(relative.toString())
            val actual = if (Files.isSymbolicLink(path)) path.toRealPath() else path
            if (Files.isDirectory(actual, LinkOption.NOFOLLOW_LINKS)) {
                Files.createDirectories(destination)
            } else {
                destination.parent?.let(Files::createDirectories)
                Files.copy(actual, destination, StandardCopyOption.REPLACE_EXISTING)
            }
        }
    }

    private fun writeManifest(root: Path) {
        val files = mutableListOf<Path>()
        Files.walk(root).use { stream ->
            stream.filter { Files.isRegularFile(it, LinkOption.NOFOLLOW_LINKS) }.forEach(files::add)
        }
        root.resolve(MANIFEST_FILE).toFile().bufferedWriter().use { output ->
            files.sortedBy { root.relativize(it).toString() }.forEach { path ->
                val relative = root.relativize(path).toString().replace(File.separatorChar, '/')
                val digest = MessageDigest.getInstance("SHA-256")
                Files.newInputStream(path).use { input ->
                    val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
                    while (true) {
                        val count = input.read(buffer)
                        if (count < 0) break
                        digest.update(buffer, 0, count)
                    }
                }
                val hash = digest.digest().joinToString("") { "%02x".format(it) }
                output.append(hash).append(' ').append(relative).append('\n')
            }
        }
    }

    private fun digestTree(root: Path): String {
        val digest = MessageDigest.getInstance("SHA-256")
        val paths = mutableListOf<Path>()
        Files.walk(root).use { stream -> stream.forEach(paths::add) }
        paths.filter { Files.isRegularFile(it, LinkOption.NOFOLLOW_LINKS) }
            .sortedBy { root.relativize(it).toString() }
            .forEach { path ->
                val relative = root.relativize(path).toString().replace(File.separatorChar, '/')
                digest.update(relative.toByteArray(Charsets.UTF_8))
                digest.update(0.toByte())
                Files.newInputStream(path).use { input ->
                    val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
                    while (true) {
                        val count = input.read(buffer)
                        if (count < 0) break
                        digest.update(buffer, 0, count)
                    }
                }
            }
        return digest.digest().joinToString(separator = "") { byte -> "%02x".format(byte) }
    }

    companion object {
        private const val VERSION_FILE = "VERSION"
        private const val MANIFEST_FILE = "MANAGED_FILES"
        private val ABI_NAMES = listOf("arm64-v8a", "armeabi-v7a")
    }
}

val prefixBuildRoot = rootProject.layout.projectDirectory.dir("build-ext/out")
val prefixAssetsOutput = layout.buildDirectory.dir("generated/prefix-assets")
val packagePrefixAssets = tasks.register<PackagePrefixAssetsTask>("packagePrefixAssets") {
    sourceRoot.set(prefixBuildRoot)
    sourceFiles.from(project.fileTree(prefixBuildRoot) {
        include("*/final/**")
    })
    outputRoot.set(prefixAssetsOutput)
    outputs.upToDateWhen { false }
}

android {
    namespace = "com.terminal"
    compileSdk = 35
    ndkVersion = "29.0.14206865"

    defaultConfig {
        applicationId = "com.terminal"
        minSdk = 24
        // targetSdk 28 is required for execve() from files/usr on Android 10+.
        targetSdk = 28
        versionCode = 1
        versionName = "1.0"
        ndk {
            abiFilters += listOf("arm64-v8a", "armeabi-v7a")
        }
    }

    sourceSets {
        getByName("main") {
            // Extension binaries are ordinary assets. Only libpty.so remains in jniLibs.
            assets.srcDir(prefixAssetsOutput)
        }
    }

    buildFeatures {
        viewBinding = true
    }

    lint {
        // This app deliberately targets 28: newer targets block execution from the private prefix.
        disable += "ExpiredTargetSdkVersion"
    }

    // libpty.so is cross-compiled by tools/build-native.sh and checked in under jniLibs.
    // The installed NDK prebuilt directory is aarch64, while ndk-build selects its host
    // toolchain by an x86_64 probe and cannot run its bundled Python here.

    packaging {
        jniLibs {
            useLegacyPackaging = true
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlin {
        compilerOptions {
            jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.fromTarget("17"))
        }
    }
}

tasks.configureEach {
    if (name == "preBuild" || (name.startsWith("merge") && name.endsWith("Assets"))) {
        dependsOn(packagePrefixAssets)
    }
}

dependencies {
    implementation(libs.androidx.core.ktx)
    implementation(libs.androidx.appcompat)
    implementation(libs.material)
    implementation(libs.androidx.constraintlayout)
}
