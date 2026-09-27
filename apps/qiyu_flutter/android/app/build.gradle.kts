import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// 缺什么一次记全，一条消息抛完，免得用户一轮只补一个字段。
val releaseSigningProblems = mutableListOf<String>()

// release 签名读 android/key.properties（该文件与 keystore 都已 gitignore，凭据不入库）。
//
// 为什么缺 key.properties / keystore 时让 release 构建直接失败，而不是静默退回调试签名：
// 签名身份一旦换过，覆盖安装就会被系统拒绝，唯一出路是卸载重装，
// 而会话与记忆全在 App 私有目录里，卸载即清空 —— 不可逆的数据丢失。
// 宁可构建不了，也不能产出一个「看着像 release、其实签的是调试钥匙」的包。
//
// 显式按 UTF-8 读：Properties 的 InputStream 重载按 ISO-8859-1 系列解字节，
// 会和 scripts/build-android-apk.ps1 的 -Encoding UTF8 预检读出不同的口令。
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystorePropertiesFile.reader(Charsets.UTF_8).use { keystoreProperties.load(it) }
} else {
    releaseSigningProblems += "android/key.properties 不存在（把同目录 key.properties.example 复制为它并填好四项）"
}

// 本次调用是不是真要产出 release。Gradle 允许任务名驼峰缩写（aR == assembleRelease），
// 只按「名字里含 release」判定会被 aR / assembleR 这类姿势绕过，故按缩写语义匹配。
// 没有改用 gradle.taskGraph.whenReady 做执行期判据：flutter 的 gradle 调用默认开配置缓存，
// 脚本里的 whenReady 回调会让缓存存不下来（实测 Configuration cache state could not be cached）。
val releasePackagingTaskNames = listOf(
    "assembleRelease",
    "bundleRelease",
    "packageRelease",
    "validateSigningRelease",
    "lintVitalRelease",
    "installRelease",
    // 生命周期任务会把 release 变体一并拉进任务图。
    // check / connectedCheck / deviceCheck 有意不列：它们只跑检查类任务，
    // 不产出需要签名的包，列进来会让没配 keystore 的机器连 `gradlew check` 都硬失败。
    "assemble",
    "build",
)

fun matchesCamelAbbreviation(name: String, taskName: String): Boolean {
    // 缩写匹配里每个字符都是可选的，单字母请求（`gradlew i` 想跑 init）会被
    // 当成 installRelease 的缩写命中，故至少两个字符才参与匹配。
    if (name.length < 2) {
        return false
    }
    val optionalChars = taskName.map { "$it?" }.joinToString(separator = "")
    return Regex("^$optionalChars$", RegexOption.IGNORE_CASE).matches(name)
}

val releaseSigningRequested = gradle.startParameter.taskNames.any { requested ->
    val name = requested.substringAfterLast(':')
    releasePackagingTaskNames.any { taskName -> matchesCamelAbbreviation(name, taskName) }
}

fun releaseSigningValue(key: String): String? {
    val value = keystoreProperties.getProperty(key)?.trim().orEmpty()
    if (value.isEmpty()) {
        releaseSigningProblems += "android/key.properties 中缺失或为空：$key"
        return null
    }
    return value
}

val releaseStoreFile: java.io.File? = releaseSigningValue("storeFile")?.let { storeFilePath ->
    // 相对路径按 android/ 目录解析，绝对路径原样使用。
    val storeFile = rootProject.file(storeFilePath)
    if (storeFile.exists()) {
        storeFile
    } else {
        releaseSigningProblems += "storeFile 指向的 keystore 不存在：${storeFile.path}"
        null
    }
}

fun releaseSigningMessage(): String {
    return "release 签名不可用：\n" +
        releaseSigningProblems.joinToString(separator = "\n") { problem -> "  - $problem" } +
        "\n签名身份换过就无法覆盖安装，卸载会清空 App 私有目录里的会话与记忆且不可逆，" +
        "因此宁可不构建也不退回调试签名。请按 docs/engineering/android-release-build.md " +
        "准备 keystore 与 apps/qiyu_flutter/android/key.properties（模板见同目录 " +
        "key.properties.example）后重试。"
}

android {
    namespace = "dev.qiyu.app"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "dev.qiyu.app"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        create("release") {
            storeFile = releaseStoreFile
            storePassword = releaseSigningValue("storePassword")
            keyAlias = releaseSigningValue("keyAlias")
            keyPassword = releaseSigningValue("keyPassword")
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("release")
        }
    }
}

// 硬校验只在真正要产出 release 时生效，免得没 keystore 的机器连调试包都跑不动。
if (releaseSigningRequested && releaseSigningProblems.isNotEmpty()) {
    throw GradleException(releaseSigningMessage())
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
