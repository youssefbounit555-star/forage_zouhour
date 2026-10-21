import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}
dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.5")
}

val signingProperties = Properties()
val localProperties = Properties()
val localPropertiesFile = rootProject.file("local.properties")
if (localPropertiesFile.exists()) {
    localPropertiesFile.inputStream().use(localProperties::load)
}
val signingPropertiesPath = System.getenv("FORAGE_SIGNING_PROPERTIES")
    ?: localProperties.getProperty("forageSigningProperties")
val signingPropertiesFile = signingPropertiesPath
    ?.takeIf { it.isNotBlank() }
    ?.let(::file)
signingPropertiesFile
    ?.takeIf { it.exists() }
    ?.inputStream()
    ?.use(signingProperties::load)

// Flutter otherwise falls back to a debug certificate for a release APK when
// no release keystore is configured. Refuse only release tasks so normal local
// debug development remains available.
val releaseTaskRequested = gradle.startParameter.taskNames.any {
    it.contains("release", ignoreCase = true)
}
val requiredSigningProperties = listOf(
    "storeFile",
    "storePassword",
    "keyAlias",
    "keyPassword",
)
if (releaseTaskRequested) {
    if (signingPropertiesFile == null || !signingPropertiesFile.exists()) {
        throw org.gradle.api.GradleException(
            "Release signing is required. Set FORAGE_SIGNING_PROPERTIES or forageSigningProperties in local.properties to a protected file outside this project.",
        )
    }
    val missingProperties = requiredSigningProperties.filter {
        signingProperties.getProperty(it).isNullOrBlank()
    }
    if (missingProperties.isNotEmpty()) {
        throw org.gradle.api.GradleException(
            "Release signing is required. Protected signing configuration is incomplete: ${missingProperties.joinToString()}",
        )
    }
}

android {
    namespace = "com.example.forage"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        isCoreLibraryDesugaringEnabled = true
    }

    defaultConfig {
        applicationId = "com.foragezouhour.app"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        create("secureRelease") {
            if (signingPropertiesFile?.exists() == true) {
                storeFile = file(signingProperties.getProperty("storeFile"))
                storePassword = signingProperties.getProperty("storePassword")
                keyAlias = signingProperties.getProperty("keyAlias")
                keyPassword = signingProperties.getProperty("keyPassword")
            }
        }
    }
    buildTypes {
        release {
            // This deliberately fails unless signing data is supplied from a
            // protected location outside the source tree.
            signingConfig = signingConfigs.getByName("secureRelease")
            // Make casual reverse engineering of the release binary harder.
            isMinifyEnabled = true
            isShrinkResources = true
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
